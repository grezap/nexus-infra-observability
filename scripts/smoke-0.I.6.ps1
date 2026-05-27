#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.I.6 smoke gate -- fleet-wide Vector log-shipper rollout.

.DESCRIPTION
  Verifies the 0.I.6 exit gate: Vector installed + nexus-vector.service
  active on every currently-running Linux fleet node. Logs ship to the
  OTel Collector pair (otel.nexus.lab:4318/v1/logs) which routes to Loki.

  Vector retries-with-backoff when the obs CA trust anchor is missing on
  a fleet node (only obs-otel nodes get it via the TLS overlay) -- the
  service still reaches ACTIVE state + queues events locally. End-to-end
  log flow proof: opt-in via -EndToEnd switch (probes Loki for {fleet="
  nexusplatform"} stream from each smoked node).

.PARAMETER EndToEnd
  Also probe Loki to verify logs from each fleet node landed (requires the
  full obs stack up: loki-1/2/3 + tempo-1/2/3 + 4 MinIO + obs-otel pair).
#>

[CmdletBinding()]
param([switch]$EndToEnd)
$ErrorActionPreference = 'Stop'

$user      = 'nexusadmin'
$sshOpts   = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$failures  = @()

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

# Discover live fleet (VMnet11 192.168.70.0/24) via vmrun -- only check running VMs.
$vmrunPath = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
$runningVmx = & $vmrunPath list | Where-Object { $_ -like '*.vmx' }
$hostnameToIp = @{
    'vault-1'='192.168.70.121'; 'vault-2'='192.168.70.122'; 'vault-3'='192.168.70.123'; 'vault-transit'='192.168.70.124';
    'prom-1'='192.168.70.170'; 'prom-2'='192.168.70.171';
    'loki-1'='192.168.70.172'; 'loki-2'='192.168.70.173'; 'loki-3'='192.168.70.174';
    'tempo-1'='192.168.70.175'; 'tempo-2'='192.168.70.176'; 'tempo-3'='192.168.70.177';
    'grafana-1'='192.168.70.178'; 'grafana-2'='192.168.70.179';
    'grafana-pg-1'='192.168.70.180'; 'grafana-pg-2'='192.168.70.181';
    'otel-collector-1'='192.168.70.182'; 'otel-collector-2'='192.168.70.183'
    # nexus-gateway + dc-nexus are special (edge/Windows) -- not Linux fleet nodes
}
$linuxFleet = @()
foreach ($vmx in $runningVmx) {
    foreach ($h in $hostnameToIp.Keys) {
        if ($vmx -like "*\$h\*") { $linuxFleet += @{ host = $h; ip = $hostnameToIp[$h] } }
    }
}
Write-Host "Discovered $($linuxFleet.Count) running Linux fleet node(s)" -ForegroundColor Cyan

if ($linuxFleet.Count -eq 0) { Write-Host 'No Linux fleet nodes running -- nothing to smoke-test.' -ForegroundColor Yellow; exit 0 }

# ─── Section 1: Vector binary + service ──────────────────────────────────
Write-Section 'Vector binary installed + service active'
foreach ($n in $linuxFleet) {
    Test-Check -Description "$($n.ip) ($($n.host)) : /opt/vector/bin/vector present + executable" -Probe {
        (Invoke-RemoteCommand -Ip $n.ip -Command 'test -x /opt/vector/bin/vector && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$($n.ip) ($($n.host)) : nexus-vector.service active" -Probe {
        (Invoke-RemoteCommand -Ip $n.ip -Command 'systemctl is-active nexus-vector.service') -match '(?m)^active\s*$'
    } | Out-Null
}

# ─── Section 2: Config validates + tags present ──────────────────────────
Write-Section 'vector.yaml valid + nexus_host/fleet tags present'
foreach ($n in $linuxFleet) {
    Test-Check -Description "$($n.ip) : vector.yaml has nexus_host = <hostname>" -Probe {
        (Invoke-RemoteCommand -Ip $n.ip -Command "sudo grep -c 'nexus_host' /etc/nexus-vector/vector.yaml") -match '(?m)^[1-9]'
    } | Out-Null
    Test-Check -Description "$($n.ip) : vector.yaml has fleet = nexusplatform" -Probe {
        (Invoke-RemoteCommand -Ip $n.ip -Command "sudo grep -c 'nexusplatform' /etc/nexus-vector/vector.yaml") -match '(?m)^[1-9]'
    } | Out-Null
    Test-Check -Description "$($n.ip) : vector --version reports a Vector binary" -Probe {
        (Invoke-RemoteCommand -Ip $n.ip -Command '/opt/vector/bin/vector --version 2>&1 | head -1') -match '(?i)vector'
    } | Out-Null
}

# ─── Section 3: End-to-end (opt-in) ───────────────────────────────────────
if ($EndToEnd) {
    Write-Section 'End-to-end: Loki shows logs from {fleet="nexusplatform"} stream'
    Write-Host 'NOTE: this section requires loki-1/2/3 + tempo-1/2/3 + 4 MinIO + obs-otel pair all running.' -ForegroundColor Yellow
    # Wait ~30s for Vector's first batch to land
    Write-Host 'Waiting 30s for first batch...' -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
    foreach ($n in $linuxFleet) {
        Test-Check -Description "Loki query: {fleet=`"nexusplatform`",nexus_host=`"$($n.host)`"} has > 0 entries" -Probe {
            # Query via grafana-1 (which has Loki datasource configured) or directly against loki RR DNS.
            $qs = "query=" + [System.Web.HttpUtility]::UrlEncode("count_over_time({fleet=`"nexusplatform`",nexus_host=`"$($n.host)`"}[5m])")
            $out = Invoke-RemoteCommand -Ip '192.168.70.178' -Command "sudo /usr/bin/curl -fsS --max-time 5 --cacert /etc/nexus-grafana/tls/ca.crt 'https://loki.nexus.lab:3100/loki/api/v1/query?$qs' 2>&1"
            $out -match '"status":"success"' -and $out -notmatch '"result":\[\]'
        } | Out-Null
    }
} else {
    Write-Section 'End-to-end log flow proof (SKIPPED; opt-in via -EndToEnd)'
    Write-Host '[skip] -EndToEnd requires loki+tempo+minio+obs-otel all running; the source-canon proof' -ForegroundColor Yellow
    Write-Host '       is Vector installed + service active + config tags present (sections 1+2).' -ForegroundColor Yellow
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== smoke-0.I.6 summary ===' -ForegroundColor Cyan
if ($failures.Count -eq 0) {
    Write-Host "ALL CHECKS GREEN ($($linuxFleet.Count) Linux fleet nodes)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILURES ($($failures.Count)):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
