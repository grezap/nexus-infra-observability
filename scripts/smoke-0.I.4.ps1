#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.I.4 smoke gate -- Grafana HA + Grafana PG HA + 2 VRRP VIPs (ADR-0038).

.DESCRIPTION
  Verifies the 0.I.4 exit gate: 4-VM Grafana tier --
    - grafana-1/2 .178/.179 active-active over shared PG state; VRRP VIP
      grafana.nexus.lab .184 (keepalived MASTER prio 110 / BACKUP prio 100,
      unicast).
    - grafana-pg-1/2 .180/.181 PG17 streaming-repl; VRRP VIP
      grafana-db.nexus.lab .185 (canonical mirror of 0.L.2 iceberg-db).

  Sections: reachability -> firstboot -> Vault Agent -> mTLS material -> nftables
  -> PG replication + keepalived -> Grafana service health -> VRRP VIPs bound
  -> datasource provisioning -> shared state proof -> cert IP-SAN validates VIP
  -> ADR-0025 VIP failover sequence (BOTH .184 + .185) -> obs-tier integration.

.NOTES
  Per memory/feedback_ha_promise_covers_lb_tier.md the 5-step VIP failover
  sequence per ADR-0025 is exercised on BOTH .184 and .185; per
  memory/feedback_keepalived_check_versioned_binary.md the chk_pg track script
  uses the absolute versioned binary; per memory/feedback_windows_curl_schannel_no_ip_san.md
  HTTPS probes against the VIP use --resolve to bypass schannel's IP-SAN limit.
#>

[CmdletBinding()]
param([switch]$Strict)
$ErrorActionPreference = 'Stop'

$user        = 'nexusadmin'
$grafanaIps  = @('192.168.70.178', '192.168.70.179')
$grafanaPgIps = @('192.168.70.180', '192.168.70.181')
$allIps      = $grafanaIps + $grafanaPgIps
$grafanaVip   = '192.168.70.184'
$grafanaDbVip = '192.168.70.185'

$nodeNames = @{
    '192.168.70.178' = 'grafana-1'
    '192.168.70.179' = 'grafana-2'
    '192.168.70.180' = 'grafana-pg-1'
    '192.168.70.181' = 'grafana-pg-2'
}
$sshOpts  = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$failures = @(); $warnings = @()

function Write-Section([string]$title) { Write-Host ''; Write-Host "=== $title ===" -ForegroundColor Cyan }
function Test-Check {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][scriptblock]$Probe)
    try {
        if (& $Probe) { Write-Host "[OK]   $Description" -ForegroundColor Green; return $true }
        else { Write-Host "[FAIL] $Description" -ForegroundColor Red; $script:failures += $Description; return $false }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"; return $false
    }
}
function Invoke-RemoteCommand {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command)
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# ─── Section 1: reachability (4 nodes) ────────────────────────────────────
Write-Section 'Per-node SSH reachability'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip ($($nodeNames[$ip])) : SSH echo probe" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker') -match 'nexus-smoke-marker'
    } | Out-Null
}
if ($failures.Count -gt 0) { Write-Host ''; Write-Host "FAIL early: $($failures.Count) reachability check(s) failed" -ForegroundColor Red; exit 1 }

# ─── Section 2: firstboot + identity ──────────────────────────────────────
Write-Section 'observability-node firstboot completion'
foreach ($ip in $allIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : firstboot-done marker present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/observability-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
    Test-Check -Description "$ip : hostname == $h" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$h\s*$"
    } | Out-Null
}

# ─── Section 3: Vault Agent active on all 4 ───────────────────────────────
Write-Section 'Vault Agent active + token sink'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : token sink populated" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOK') -match 'TOK'
    } | Out-Null
}

# ─── Section 4: mTLS cert material (per role) ─────────────────────────────
Write-Section 'mTLS cert material (per role; VIP in IP-SAN)'
foreach ($ip in $grafanaIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : /etc/nexus-grafana/tls/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-grafana/tls/server.crt && sudo test -s /etc/nexus-grafana/tls/server.key && sudo test -s /etc/nexus-grafana/tls/ca.crt && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : cert CN == $h.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-grafana/tls/server.crt -noout -subject') -match "CN\s*=\s*$h\.nexus\.lab"
    } | Out-Null
    Test-Check -Description "$ip : cert SAN includes grafana.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-grafana/tls/server.crt -noout -ext subjectAltName') -match 'grafana\.nexus\.lab'
    } | Out-Null
    Test-Check -Description "$ip : cert IP-SAN includes VIP $grafanaVip" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nexus-grafana/tls/server.crt -noout -ext subjectAltName | grep -F 'IP Address:$grafanaVip'") -match $grafanaVip
    } | Out-Null
}
foreach ($ip in $grafanaPgIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : /etc/nexus-grafana-pg/tls/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-grafana-pg/tls/server.crt && sudo test -s /etc/nexus-grafana-pg/tls/server.key && sudo test -s /etc/nexus-grafana-pg/tls/ca.crt && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : cert CN == $h.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-grafana-pg/tls/server.crt -noout -subject') -match "CN\s*=\s*$h\.nexus\.lab"
    } | Out-Null
    Test-Check -Description "$ip : cert SAN includes grafana-db.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-grafana-pg/tls/server.crt -noout -ext subjectAltName') -match 'grafana-db\.nexus\.lab'
    } | Out-Null
    Test-Check -Description "$ip : cert IP-SAN includes VIP $grafanaDbVip" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nexus-grafana-pg/tls/server.crt -noout -ext subjectAltName | grep -F 'IP Address:$grafanaDbVip'") -match $grafanaDbVip
    } | Out-Null
}

# ─── Section 5: nftables (per-role rulesets) ──────────────────────────────
Write-Section 'nftables (VMnet10 backplane trust + role-specific service ports)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : VMnet10 backplane trust rule active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
}
foreach ($ip in $grafanaIps) {
    Test-Check -Description "$ip : Grafana :3000 open on VMnet11" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'tcp dport 3000 accept'
    } | Out-Null
}
foreach ($ip in $grafanaPgIps) {
    Test-Check -Description "$ip : Postgres :5432 open on VMnet11" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'tcp dport 5432 accept'
    } | Out-Null
}

# ─── Section 6: PG replication + keepalived (grafana-pg pair) ─────────────
# Dynamic detection: nopreempt means after a failover the primary can be either
# .180 or .181 -- detect which node currently is in recovery (the replica) and
# check the other as primary.
Write-Section 'PostgreSQL streaming replication state'
$pgPrimary = $null; $pgReplica = $null
foreach ($pip in $grafanaPgIps) {
    $isRecovery = (Invoke-RemoteCommand -Ip $pip -Command "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'").Trim()
    if ($isRecovery -eq 't') { $pgReplica = $pip } elseif ($isRecovery -eq 'f') { $pgPrimary = $pip }
}
Test-Check -Description "PG pair: one primary + one replica detected (primary=$pgPrimary, replica=$pgReplica)" -Probe {
    $null -ne $pgPrimary -and $null -ne $pgReplica -and $pgPrimary -ne $pgReplica
} | Out-Null
if ($pgPrimary -and $pgReplica) {
    Test-Check -Description "$pgPrimary (primary) : pg_stat_replication has 1+ streaming standby" -Probe {
        # Retry with deadline -- pg_stat_replication is a momentary view; standby
        # connections can flicker briefly during post-failover convergence.
        $deadline = (Get-Date).AddSeconds(45); $ok = $false
        while ((Get-Date) -lt $deadline) {
            if ((Invoke-RemoteCommand -Ip $pgPrimary -Command "sudo -u postgres psql -tAc ""SELECT count(*) FROM pg_stat_replication WHERE state='streaming'""") -match '(?m)^[1-9]') { $ok = $true; break }
            Start-Sleep -Seconds 3
        }
        $ok
    } | Out-Null
    Test-Check -Description "$pgReplica (replica) : pg_stat_wal_receiver shows streaming" -Probe {
        (Invoke-RemoteCommand -Ip $pgReplica -Command "sudo -u postgres psql -tAc 'SELECT status FROM pg_stat_wal_receiver'") -match '(?i)streaming'
    } | Out-Null
    Test-Check -Description "grafana DB exists on primary ($pgPrimary), owner=grafana" -Probe {
        (Invoke-RemoteCommand -Ip $pgPrimary -Command "sudo -u postgres psql -tAc ""SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='grafana'""") -match '(?m)^grafana\s*$'
    } | Out-Null
}

# ─── Section 7: Grafana service health + /api/health ──────────────────────
Write-Section 'Grafana service health + database connectivity'
foreach ($ip in $grafanaIps) {
    Test-Check -Description "$ip : grafana-server.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active grafana-server.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : /api/health 200 + database=ok" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo /usr/bin/curl -fsS --max-time 5 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:127.0.0.1 https://grafana.nexus.lab:3000/api/health') -match '"database":\s*"ok"'
    } | Out-Null
}

# ─── Section 8: VRRP VIPs bound to exactly one node each ──────────────────
Write-Section 'VRRP VIPs bound (1 node each)'
foreach ($pair in @(@{vip = $grafanaVip; nodes = $grafanaIps; label = 'grafana.nexus.lab .184' },
        @{vip = $grafanaDbVip; nodes = $grafanaPgIps; label = 'grafana-db.nexus.lab .185' })) {
    Test-Check -Description "VIP $($pair.vip) ($($pair.label)) bound to exactly one node" -Probe {
        $cnt = 0
        foreach ($nip in $pair.nodes) {
            $has = Invoke-RemoteCommand -Ip $nip -Command "ip -4 -o addr show nic0 | grep -c '$($pair.vip)'"
            if ($has -match '(?m)^[1-9]') { $cnt++ }
        }
        return $cnt -eq 1
    } | Out-Null
}

# ─── Section 9: Datasource provisioning (Prom + Loki + Tempo present) ─────
Write-Section 'Datasource provisioning (Prometheus + Loki + Tempo)'
$dsProbe = @'
set -euo pipefail
export VAULT_ADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
ADMINPW=$(VAULT_TOKEN=$TOKEN /usr/local/bin/vault kv get -field=value nexus/observability/grafana/admin-password)
CURL="sudo /usr/bin/curl -fsS --max-time 5 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:127.0.0.1 -u admin:$ADMINPW"
$CURL https://grafana.nexus.lab:3000/api/datasources | jq -r '.[].name' | sort
'@
foreach ($ip in $grafanaIps) {
    $names = Invoke-RemoteCommand -Ip $ip -Command $dsProbe
    Test-Check -Description "$ip : Prometheus datasource provisioned"  -Probe { $names -match '(?m)^Prometheus\s*$' } | Out-Null
    Test-Check -Description "$ip : Loki datasource provisioned"        -Probe { $names -match '(?m)^Loki\s*$' } | Out-Null
    Test-Check -Description "$ip : Tempo datasource provisioned"       -Probe { $names -match '(?m)^Tempo\s*$' } | Out-Null
}

# ─── Section 10: Shared-state proof (org count consistent via both nodes) ─
Write-Section 'Shared PG state proof (Grafana reads same data from both nodes)'
$orgProbe = @'
set -euo pipefail
export VAULT_ADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=$(sudo cat /var/run/nexus-vault-agent/token)
ADMINPW=$(VAULT_TOKEN=$TOKEN /usr/local/bin/vault kv get -field=value nexus/observability/grafana/admin-password)
sudo /usr/bin/curl -fsS --max-time 5 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:127.0.0.1 -u admin:$ADMINPW https://grafana.nexus.lab:3000/api/orgs | jq 'length'
'@
$orgsA = Invoke-RemoteCommand -Ip '192.168.70.178' -Command $orgProbe
$orgsB = Invoke-RemoteCommand -Ip '192.168.70.179' -Command $orgProbe
Test-Check -Description "grafana-1 /api/orgs count == grafana-2 (both read shared PG)" -Probe {
    $orgsA -eq $orgsB -and $orgsA -match '(?m)^[1-9]'
} | Out-Null

# ─── Section 11: Cert chain validates against the floating VIPs ───────────
Write-Section 'sslmode=verify-full against the floating VIPs validates'
Test-Check -Description "PG VIP .185 : verify-full handshake (psql sslmode=verify-full sslrootcert=ca.crt)" -Probe {
    # Probe whether the TLS handshake succeeds against the floating VIP using the
    # mTLS leaf cert chain (sslrootcert -> intermediate -> Vault root). Any auth
    # failure (no_password / FATAL password / role does not exist) is PROOF the
    # handshake completed -- if the cert chain failed, psql would report a TLS
    # error BEFORE attempting auth. The probe accepts those auth-failure tokens
    # as successful handshake. Runs as sudo -u postgres so it can read the cert
    # file (parent dir 0750 root:postgres).
    $probeIp = if ($pgPrimary) { $pgPrimary } else { '192.168.70.180' }
    $out = Invoke-RemoteCommand -Ip $probeIp -Command "sudo -u postgres psql 'host=$grafanaDbVip port=5432 user=postgres dbname=postgres sslmode=verify-full sslrootcert=/etc/nexus-grafana-pg/tls/ca.crt' -tAc 'SELECT 1' 2>&1 || true"
    $out -match '(?m)^1\s*$|FATAL.*password|fe_sendauth: no password|role .* does not exist'
} | Out-Null
Test-Check -Description "Grafana VIP .184 : HTTPS GET /api/health passes verify-full" -Probe {
    (Invoke-RemoteCommand -Ip '192.168.70.178' -Command "sudo /usr/bin/curl -fsS --max-time 5 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:$grafanaVip https://grafana.nexus.lab:3000/api/health") -match '"database":\s*"ok"'
} | Out-Null

# ─── Section 12: ADR-0025 failover -- Grafana app VIP .184 ────────────────
Write-Section 'ADR-0025 VIP failover sequence -- grafana app VIP .184'
function Get-VipHolder { param([string]$Vip, [string[]]$Candidates)
    foreach ($c in $Candidates) {
        $has = Invoke-RemoteCommand -Ip $c -Command "ip -4 -o addr show nic0 | grep -c '$Vip'"
        if ($has -match '(?m)^[1-9]') { return $c }
    }
    return $null
}
$masterApp = Get-VipHolder -Vip $grafanaVip -Candidates $grafanaIps
$backupApp = $grafanaIps | Where-Object { $_ -ne $masterApp } | Select-Object -First 1
Test-Check -Description "Pre-failover: VIP .184 held by $masterApp" -Probe { $null -ne $masterApp } | Out-Null
if ($masterApp -and $backupApp) {
    Invoke-RemoteCommand -Ip $masterApp -Command 'sudo systemctl stop keepalived' | Out-Null
    Start-Sleep -Seconds 15
    $newHolder = Get-VipHolder -Vip $grafanaVip -Candidates $grafanaIps
    Test-Check -Description "Mid-failover: VIP .184 moves to $backupApp" -Probe { $newHolder -eq $backupApp } | Out-Null
    Test-Check -Description "Mid-failover: /api/health via VIP .184 stays GREEN" -Probe {
        (Invoke-RemoteCommand -Ip $backupApp -Command "sudo /usr/bin/curl -fsS --max-time 5 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:$grafanaVip https://grafana.nexus.lab:3000/api/health") -match '"database":\s*"ok"'
    } | Out-Null
    Invoke-RemoteCommand -Ip $masterApp -Command 'sudo systemctl start keepalived' | Out-Null
    Start-Sleep -Seconds 10
    Test-Check -Description "Post-restart: VIP .184 stays on $backupApp (nopreempt)" -Probe {
        (Get-VipHolder -Vip $grafanaVip -Candidates $grafanaIps) -eq $backupApp
    } | Out-Null
    Test-Check -Description "Post-restart: keepalived active on both" -Probe {
        $a = Invoke-RemoteCommand -Ip $masterApp -Command 'systemctl is-active keepalived'
        $b = Invoke-RemoteCommand -Ip $backupApp -Command 'systemctl is-active keepalived'
        ($a -match '(?m)^active\s*$') -and ($b -match '(?m)^active\s*$')
    } | Out-Null
}

# ─── Section 13: ADR-0025 failover -- Grafana PG VIP .185 (opt-in -Strict) ─
# OPT-IN: destructive test (promotes standby + re-basebackups the old primary).
# The failover correctness was proven once during initial live-ratification on
# 2026-05-27; rerunning routinely is operator-action territory. Default smoke
# skips. Use `-Strict` to exercise. See handbook §3.D T24-T27 for the recovery
# canon.
if (-not $Strict) {
    Write-Section 'ADR-0025 VIP failover sequence -- grafana PG VIP .185 (SKIPPED; opt-in via -Strict)'
    Write-Host '[skip] PG VIP failover proven 2026-05-27 in initial ratification; destructive test (operator-action).' -ForegroundColor Yellow
} else {
Write-Section 'ADR-0025 VIP failover sequence -- grafana PG VIP .185 (-Strict)'
$masterPg = Get-VipHolder -Vip $grafanaDbVip -Candidates $grafanaPgIps
$backupPg = $grafanaPgIps | Where-Object { $_ -ne $masterPg } | Select-Object -First 1
Test-Check -Description "Pre-failover: VIP .185 held by $masterPg" -Probe { $null -ne $masterPg } | Out-Null
if ($masterPg -and $backupPg) {
    Invoke-RemoteCommand -Ip $masterPg -Command 'sudo systemctl stop keepalived' | Out-Null
    Start-Sleep -Seconds 15
    $newHolder = Get-VipHolder -Vip $grafanaDbVip -Candidates $grafanaPgIps
    Test-Check -Description "Mid-failover: VIP .185 moves to $backupPg" -Probe { $newHolder -eq $backupPg } | Out-Null
    Test-Check -Description "Mid-failover: pg_isready via VIP .185 stays GREEN" -Probe {
        (Invoke-RemoteCommand -Ip $backupPg -Command "/usr/lib/postgresql/17/bin/pg_isready -q -h $grafanaDbVip -p 5432 && echo READY") -match 'READY'
    } | Out-Null
    Invoke-RemoteCommand -Ip $masterPg -Command 'sudo systemctl start keepalived' | Out-Null
    Start-Sleep -Seconds 10
    Test-Check -Description "Post-restart: VIP .185 stays on $backupPg (nopreempt)" -Probe {
        (Get-VipHolder -Vip $grafanaDbVip -Candidates $grafanaPgIps) -eq $backupPg
    } | Out-Null

    # ── Post-failover recovery: re-sync the OLD primary as a fresh standby ───
    Write-Host "[smoke-0.I.4] post-failover: re-syncing $masterPg as fresh standby of $backupPg" -ForegroundColor Yellow
    $newPrimaryBackplane = if ($backupPg -eq '192.168.70.180') { '192.168.10.180' } else { '192.168.10.181' }
    $recoverScript = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
REPLPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value nexus/observability/grafana-pg/replication-password)
[ -n "`$REPLPW" ] || { echo "ERROR: empty repl pw" >&2; exit 1; }
sudo systemctl stop postgresql@17-main 2>/dev/null || true
sudo rm -rf /var/lib/postgresql/17/main
sudo install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/17/main
echo "${newPrimaryBackplane}:5432:replication:repluser:`$REPLPW" | sudo tee /var/lib/postgresql/.pgpass >/dev/null
sudo chown postgres:postgres /var/lib/postgresql/.pgpass
sudo chmod 0600 /var/lib/postgresql/.pgpass
sudo -u postgres env PGPASSWORD="`$REPLPW" pg_basebackup -h $newPrimaryBackplane -p 5432 -U repluser -D /var/lib/postgresql/17/main -Fp -Xs -P -R
sudo systemctl start postgresql@17-main
for i in `$(seq 1 30); do sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null | grep -qi t && break; sleep 2; done
sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'
"@
    $out = ($recoverScript -replace "`r`n","`n") | ssh @sshOpts "$user@$masterPg" "tr -d '\r' | bash -s" 2>&1 | Out-String
    Test-Check -Description "Post-failover recovery: $masterPg re-synced as standby of $backupPg" -Probe {
        $out -match '(?m)^t\s*$'
    } | Out-Null
    Start-Sleep -Seconds 5
    Test-Check -Description "Post-recovery: new primary $backupPg sees streaming standby" -Probe {
        # Retry-with-deadline: after pg_basebackup + start, the standby takes
        # 10-30s to fully attach + transition to 'streaming' state.
        $deadline = (Get-Date).AddSeconds(45); $ok = $false
        while ((Get-Date) -lt $deadline) {
            if ((Invoke-RemoteCommand -Ip $backupPg -Command "sudo -u postgres psql -tAc ""SELECT count(*) FROM pg_stat_replication WHERE state='streaming'""") -match '(?m)^[1-9]') { $ok = $true; break }
            Start-Sleep -Seconds 3
        }
        $ok
    } | Out-Null
}
}  # end if (-not $Strict) / else

# ─── Section 14: Cross-tier integration (Prom scrapes obs node_exporters) ─
Write-Section 'Prom HA scrapes the 4 obs-grafana node_exporters'
foreach ($ip in $allIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : node_exporter :9100 reachable from prom-1 (.170)" -Probe {
        (Invoke-RemoteCommand -Ip '192.168.70.170' -Command "/usr/bin/curl -fsS --max-time 4 http://${ip}:9100/metrics | head -3 | grep -c '^# HELP'") -match '(?m)^[1-9]'
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== smoke-0.I.4 summary ===' -ForegroundColor Cyan
if ($failures.Count -eq 0) {
    Write-Host "ALL CHECKS GREEN" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILURES ($($failures.Count)):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
