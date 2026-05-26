#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.I.1 smoke gate -- Prometheus HA pair + Alertmanager gossip mesh (ADR-0038).

.DESCRIPTION
  Verifies the 0.I.1 exit gate: 2-node Prom HA (both scrape every fleet target,
  Grafana datasource dedups on the read side) + Alertmanager mesh co-resident on
  the Prom pair (gossip on backplane :9094), with TLS leaf certs from Vault PKI.

  Sections: reachability -> firstboot -> identity -> Vault Agent -> TLS material
  -> nftables -> config + service -> Prom HTTP + AM HTTP -> AM mesh -> scrape
  targets up -> Vault KV creds -> round-robin DNS.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md. Exits 1
  on any FAIL.

.PARAMETER Strict
  Fail on warnings.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
$promIps = @('192.168.70.170', '192.168.70.171')
$nodeNames = @{ '192.168.70.170' = 'prom-1'; '192.168.70.171' = 'prom-2' }

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

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

# ─── Section 1: reachability ──────────────────────────────────────────────
Write-Section 'Per-node SSH reachability'
foreach ($ip in $promIps) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker') -match 'nexus-smoke-marker'
    } | Out-Null
}
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping later sections." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot ─────────────────────────────────────────────────
Write-Section 'observability-node firstboot completion'
foreach ($ip in $promIps) {
    Test-Check -Description "$ip : firstboot-done marker present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/observability-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
}

# ─── Section 3: identity ──────────────────────────────────────────────────
Write-Section 'Node-identity mapping (hostname + role + cluster)'
foreach ($ip in $promIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : hostname == $h" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$h\s*$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity role == prom" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "^NEXUS_ROLE=" /etc/nexus-prometheus/node-identity.env') -match 'NEXUS_ROLE=prom'
    } | Out-Null
    Test-Check -Description "$ip : node-identity cluster == observability" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "^NEXUS_CLUSTER=" /etc/nexus-prometheus/node-identity.env') -match 'NEXUS_CLUSTER=observability'
    } | Out-Null
}

# ─── Section 4: Vault Agent ───────────────────────────────────────────────
Write-Section 'Vault Agent active + token sink'
foreach ($ip in $promIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : token sink populated" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOK') -match 'TOK'
    } | Out-Null
}

# ─── Section 5: TLS material ──────────────────────────────────────────────
Write-Section 'mTLS cert material (server.crt + server.key + ca.crt for both Prom + AM)'
foreach ($ip in $promIps) {
    $h = $nodeNames[$ip]
    foreach ($svc in @('prometheus', 'alertmanager')) {
        Test-Check -Description "$ip : /etc/nexus-$svc/tls/{server.crt,server.key,ca.crt} present" -Probe {
            (Invoke-RemoteCommand -Ip $ip -Command "sudo test -s /etc/nexus-$svc/tls/server.crt && sudo test -s /etc/nexus-$svc/tls/server.key && sudo test -s /etc/nexus-$svc/tls/ca.crt && echo OK") -match 'OK'
        } | Out-Null
        Test-Check -Description "$ip : /etc/nexus-$svc/tls/server.key is PKCS#8" -Probe {
            (Invoke-RemoteCommand -Ip $ip -Command "sudo head -1 /etc/nexus-$svc/tls/server.key") -match 'BEGIN PRIVATE KEY'
        } | Out-Null
    }
    Test-Check -Description "$ip : cert CN matches $h.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nexus-prometheus/tls/server.crt -noout -subject") -match "CN\s*=\s*$h\.nexus\.lab"
    } | Out-Null
    Test-Check -Description "$ip : cert SAN includes prometheus.nexus.lab + alertmanager.nexus.lab" -Probe {
        $san = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-prometheus/tls/server.crt -noout -ext subjectAltName'
        ($san -match 'prometheus\.nexus\.lab') -and ($san -match 'alertmanager\.nexus\.lab')
    } | Out-Null
}

# ─── Section 6: nftables ──────────────────────────────────────────────────
Write-Section 'nftables (VMnet10 backplane trust + Prom/AM mgmt-plane open)'
foreach ($ip in $promIps) {
    Test-Check -Description "$ip : VMnet10 backplane trust rule present (AM mesh :9094)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
    Test-Check -Description "$ip : Prom :9090 + AM :9093 open on VMnet11" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'dport \{ 9090, 9093 \}'
    } | Out-Null
}

# ─── Section 7: config + service ──────────────────────────────────────────
Write-Section 'prometheus.yml + alertmanager.yml + cluster.env rendered + services active'
foreach ($ip in $promIps) {
    Test-Check -Description "$ip : /etc/nexus-prometheus/prometheus.yml present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-prometheus/prometheus.yml && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-alertmanager/alertmanager.yml present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-alertmanager/alertmanager.yml && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-alertmanager/cluster.env has NEXUS_AM_PEER" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -c "^NEXUS_AM_PEER=" /etc/nexus-alertmanager/cluster.env') -match '(?m)^1\s*$'
    } | Out-Null
    Test-Check -Description "$ip : nexus-prometheus.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-prometheus.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : nexus-alertmanager.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-alertmanager.service') -match '(?m)^active\s*$'
    } | Out-Null
}

# ─── Section 8: HTTPS API ─────────────────────────────────────────────────
Write-Section 'Prom + AM HTTPS API reachable (TLS via Vault PKI)'
foreach ($ip in $promIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : Prom :9090/-/ready returns 200" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "curl -fsk --resolve $h.nexus.lab:9090:127.0.0.1 -o /dev/null -w '%{http_code}' https://$h.nexus.lab:9090/-/ready") -match '200'
    } | Out-Null
    Test-Check -Description "$ip : AM :9093/-/ready returns 200" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "curl -fsk --resolve $h.nexus.lab:9093:127.0.0.1 -o /dev/null -w '%{http_code}' https://$h.nexus.lab:9093/-/ready") -match '200'
    } | Out-Null
}

# ─── Section 9: AM mesh ────────────────────────────────────────────────────
Write-Section 'Alertmanager gossip mesh formed (cluster size = 2)'
foreach ($ip in $promIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : AM cluster.peers count == 2 (mesh formed)" -Probe {
        $cmd = "curl -fsk --resolve $h.nexus.lab:9093:127.0.0.1 https://$h.nexus.lab:9093/api/v2/status 2>/dev/null | python3 -c 'import sys, json; print(len(json.load(sys.stdin)[`"cluster`"][`"peers`"]))'"
        $n = Invoke-RemoteCommand -Ip $ip -Command $cmd
        $n -match '(?m)^2\s*$'
    } | Out-Null
}

# ─── Section 10: scrape targets up ─────────────────────────────────────────
Write-Section 'Prom scrape targets (both Prom selves up + foundation node_exporter)'
foreach ($ip in $promIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : /api/v1/targets shows >= 2 prometheus job targets in state up" -Probe {
        $cmd = "curl -fsk --resolve $h.nexus.lab:9090:127.0.0.1 https://$h.nexus.lab:9090/api/v1/targets 2>/dev/null | python3 -c 'import sys, json; d=json.load(sys.stdin); print(sum(1 for t in d[`"data`"][`"activeTargets`"] if t[`"labels`"][`"job`"]==`"prometheus`" and t[`"health`"]==`"up`"))'"
        $n = Invoke-RemoteCommand -Ip $ip -Command $cmd
        [int]($n -replace '[^0-9]', '') -ge 2
    } | Out-Null
}

# ─── Section 11: Vault KV creds present ────────────────────────────────────
Write-Section 'Vault KV web-auth creds present (Prom + AM bcrypt)'
# Probe via vault-1 (the Vault leader); requires the build host has $env:VAULT_ADDR + token in $HOME/.nexus/vault-root-token.json
Test-Check -Description "Vault KV nexus/observability/prometheus/web-auth-password.password_bcrypt present" -Probe {
    $r = Invoke-RemoteCommand -Ip '192.168.70.121' -Command 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -field=password_bcrypt nexus/observability/prometheus/web-auth-password 2>/dev/null | head -c 4'
    $r -match '^\$2[ayb]\$'
} | Out-Null
Test-Check -Description "Vault KV nexus/observability/alertmanager/web-auth-password.password_bcrypt present" -Probe {
    $r = Invoke-RemoteCommand -Ip '192.168.70.121' -Command 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -field=password_bcrypt nexus/observability/alertmanager/web-auth-password 2>/dev/null | head -c 4'
    $r -match '^\$2[ayb]\$'
} | Out-Null

# ─── Section 12: round-robin DNS ───────────────────────────────────────────
Write-Section 'Round-robin DNS (prometheus.nexus.lab + alertmanager.nexus.lab -> both Prom IPs)'
Test-Check -Description "prometheus.nexus.lab resolves to both prom IPs" -Probe {
    $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short prometheus.nexus.lab @127.0.0.1') -split "\s+"
    $resolved = @($a | Where-Object { $_ })
    ($promIps | Where-Object { $resolved -contains $_ }).Count -ge 2
} | Out-Null
Test-Check -Description "alertmanager.nexus.lab resolves to both prom IPs" -Probe {
    $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short alertmanager.nexus.lab @127.0.0.1') -split "\s+"
    $resolved = @($a | Where-Object { $_ })
    ($promIps | Where-Object { $resolved -contains $_ }).Count -ge 2
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.I.1 SMOKE CHECKS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "0.I.1 SMOKE FAILED: $($failures.Count) failure(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
