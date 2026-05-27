#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.I.5 smoke gate -- OTel Collector pair (ADR-0038).

.DESCRIPTION
  Verifies the 0.I.5 exit gate: 2-node OTel Collector active-active pair
  fronted by round-robin DNS otel.nexus.lab (no VIP per ADR-0031).
  Receives OTLP gRPC :4317 + OTLP HTTP :4318; routes traces -> Tempo,
  metrics -> Prom remote-write, logs -> Loki.

  Sections: reachability -> firstboot -> Vault Agent -> mTLS material ->
  nftables -> service health -> OTLP listening -> config validates ->
  RR DNS resolves both -> cross-tier Prom scrape.
#>

[CmdletBinding()]
param([switch]$Strict)
$ErrorActionPreference = 'Stop'

$user      = 'nexusadmin'
$otelIps   = @('192.168.70.182', '192.168.70.183')
$nodeNames = @{ '192.168.70.182' = 'otel-collector-1'; '192.168.70.183' = 'otel-collector-2' }
$sshOpts   = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$failures  = @(); $warnings = @()

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

# ─── Section 1: reachability ──────────────────────────────────────────────
Write-Section 'Per-node SSH reachability'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip ($($nodeNames[$ip])) : SSH echo probe" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker') -match 'nexus-smoke-marker'
    } | Out-Null
}
if ($failures.Count -gt 0) { Write-Host ''; Write-Host "FAIL early: $($failures.Count) reachability check(s) failed" -ForegroundColor Red; exit 1 }

# ─── Section 2: firstboot ─────────────────────────────────────────────────
Write-Section 'observability-node firstboot completion'
foreach ($ip in $otelIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : firstboot-done marker present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/observability-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
    Test-Check -Description "$ip : hostname == $h" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$h\s*$"
    } | Out-Null
}

# ─── Section 3: Vault Agent ───────────────────────────────────────────────
Write-Section 'Vault Agent active + token sink'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : token sink populated" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOK') -match 'TOK'
    } | Out-Null
}

# ─── Section 4: mTLS cert material ────────────────────────────────────────
Write-Section 'mTLS cert material (/etc/nexus-otel-collector/tls/)'
foreach ($ip in $otelIps) {
    $h = $nodeNames[$ip]
    Test-Check -Description "$ip : tls/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-otel-collector/tls/server.crt && sudo test -s /etc/nexus-otel-collector/tls/server.key && sudo test -s /etc/nexus-otel-collector/tls/ca.crt && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : cert CN == $h.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-otel-collector/tls/server.crt -noout -subject') -match "CN\s*=\s*$h\.nexus\.lab"
    } | Out-Null
    Test-Check -Description "$ip : cert SAN includes otel.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-otel-collector/tls/server.crt -noout -ext subjectAltName') -match 'otel\.nexus\.lab'
    } | Out-Null
}

# ─── Section 5: nftables ──────────────────────────────────────────────────
Write-Section 'nftables (OTLP receivers open + VMnet10 backplane trust)'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip : OTLP :4317 + :4318 open on VMnet11" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'dport \{ 4317, 4318'
    } | Out-Null
    Test-Check -Description "$ip : VMnet10 backplane trust rule" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
}

# ─── Section 6: service health + config ───────────────────────────────────
Write-Section 'nexus-otel-collector.service active + /health 200 + config valid'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip : nexus-otel-collector.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-otel-collector.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : /health 200 on 127.0.0.1:13133" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command '/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:13133/ && echo HC_OK') -match 'HC_OK'
    } | Out-Null
    Test-Check -Description "$ip : config.yaml is valid YAML (otelcol-contrib validate)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo /opt/otel-collector/otelcol-contrib validate --config /etc/nexus-otel-collector/config.yaml 2>&1 || echo FAILED'
        # otelcol's validate exits 0 + prints nothing on success
        $out -notmatch 'FAILED' -and $out -notmatch '(?i)error|invalid'
    } | Out-Null
}

# ─── Section 7: OTLP listening ────────────────────────────────────────────
Write-Section 'OTLP receivers (gRPC :4317 + HTTP :4318) bound + TLS handshake works'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip : ss -ltn shows :4317 + :4318 listening" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo ss -ltn | grep -E ":4317|:4318" | wc -l'
        $out -match '(?m)^[2-9]'
    } | Out-Null
    # TLS handshake probe via openssl s_client (no app data; just verify the cert)
    Test-Check -Description "$ip : OTLP HTTP :4318 TLS handshake validates with obs CA" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "echo Q | sudo openssl s_client -connect 127.0.0.1:4318 -CAfile /etc/nexus-otel-collector/tls/ca.crt -servername $($nodeNames[$ip]).nexus.lab 2>&1 | grep -E 'Verify return code: 0|Verification: OK'"
        $out -match '0\s*\(ok\)|Verification: OK'
    } | Out-Null
}

# ─── Section 8: RR DNS otel.nexus.lab ─────────────────────────────────────
Write-Section 'Round-robin DNS otel.nexus.lab resolves to both .182 and .183'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip : getent ahostsv4 otel.nexus.lab returns 2 IPs (.182 + .183)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "getent ahostsv4 otel.nexus.lab | awk '{print `$1}' | sort -u"
        ($out -match '192\.168\.70\.182') -and ($out -match '192\.168\.70\.183')
    } | Out-Null
}

# ─── Section 9: Cross-tier (prom-1 scrapes node_exporter on otel nodes) ───
Write-Section 'Prom HA scrapes node_exporter on the 2 OTel Collector nodes'
foreach ($ip in $otelIps) {
    Test-Check -Description "$ip : node_exporter :9100 reachable from prom-1 (.170)" -Probe {
        (Invoke-RemoteCommand -Ip '192.168.70.170' -Command "/usr/bin/curl -fsS --max-time 4 http://${ip}:9100/metrics | head -3 | grep -c '^# HELP'") -match '(?m)^[1-9]'
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== smoke-0.I.5 summary ===' -ForegroundColor Cyan
if ($failures.Count -eq 0) {
    Write-Host "ALL CHECKS GREEN" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILURES ($($failures.Count)):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
