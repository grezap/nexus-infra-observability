<#
.SYNOPSIS
    Operator wrapper for the nexus-infra-observability tier (Phase 0.I, ADR-0038).

.DESCRIPTION
    Per-cluster Terraform state + per-engine Packer template canon
    (memory/feedback_per_cluster_state_per_engine_template.md). One verb per
    sub-phase; sub-phases are independent and idempotent.

    Verbs (sub-phase -> cluster):
      prom        0.I.1   Prometheus HA + Alertmanager (2 VMs)
      loki        0.I.2   Loki simple-scalable on MinIO (3 VMs)
      tempo       0.I.3   Tempo scalable on MinIO (3 VMs)
      grafana     0.I.4   Grafana HA + Grafana PG HA + 2 VRRP VIPs (2+2 VMs)
      otel        0.I.5   OTel Collector pair (2 VMs)
      all         (chain all 5 above, in order, with smoke gates between)

    Actions: apply | destroy | plan | refresh
    Selective: -Vars 'enable_<name>=true|false' (override defaults).

.EXAMPLE
    pwsh -File scripts\observability.ps1 prom apply

.EXAMPLE
    pwsh -File scripts\observability.ps1 grafana apply -Vars 'enable_keepalived=true'

.NOTES
    Cross-tier prerequisites — run FIRST in nexus-infra-vmware:
      1. pwsh -File scripts\foundation.ps1 apply  (dhcp + DNS for .170-.185 + VIPs)
      2. pwsh -File scripts\security.ps1   apply  (observability-server PKI + AppRoles + KV)
    AND in nexus-infra-lakehouse:
      3. pwsh -File scripts\lakehouse-minio.ps1 apply -Vars "enable_obs_tenants=true"
         (creates nexus-loki-app + nexus-tempo-app + buckets loki + tempo)

    The 6 foundation VMs (gateway + dc-nexus + vault-1/2/3 + vault-transit)
    AND the 4 MinIO VMs (0.L.1) must be running before any verb here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('prom', 'loki', 'tempo', 'grafana', 'otel', 'all')]
    [string]$Verb,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateSet('apply', 'destroy', 'plan', 'refresh')]
    [string]$Action,

    [Parameter(Position = 2)]
    [string[]]$Vars
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$tfBase = Join-Path $repoRoot 'terraform/envs'

# Map verb -> per-cluster TF env dir
$envMap = @{
    prom    = 'obs-prom'
    loki    = 'obs-loki'
    tempo   = 'obs-tempo'
    grafana = 'obs-grafana'
    otel    = 'obs-otel'
}

function Invoke-TerraformAction {
    param([string]$EnvName, [string]$Act, [string[]]$VarArgs)

    $envDir = Join-Path $tfBase $EnvName
    if (-not (Test-Path $envDir)) {
        throw "Terraform env dir not found: $envDir (sub-phase may not be scaffolded yet)"
    }

    Write-Host "==> terraform -chdir=$envDir $Act" -ForegroundColor Cyan

    $tfArgs = @("-chdir=$envDir", $Act)
    if ($Act -in @('apply', 'plan', 'destroy', 'refresh')) {
        if ($Act -ne 'plan') { $tfArgs += '-auto-approve' }
        foreach ($v in ($VarArgs ?? @())) {
            $tfArgs += @('-var', $v)
        }
    }

    & terraform @tfArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform $Act failed (exit $LASTEXITCODE)" }
}

if ($Verb -eq 'all') {
    if ($Action -ne 'apply') {
        throw "'all' verb is supported only for apply (use sub-phase verbs for destroy/plan/refresh)"
    }
    foreach ($v in @('prom', 'loki', 'tempo', 'grafana', 'otel')) {
        Write-Host "`n========== Phase 0.I sub-phase: $v ==========" -ForegroundColor Green
        Invoke-TerraformAction -EnvName $envMap[$v] -Act 'apply' -VarArgs $Vars

        $smokeIdx = @{ prom=1; loki=2; tempo=3; grafana=4; otel=5 }[$v]
        $smoke = Join-Path $repoRoot "scripts/smoke-0.I.$smokeIdx.ps1"
        if (Test-Path $smoke) {
            Write-Host "==> running smoke gate $smoke" -ForegroundColor Cyan
            pwsh -File $smoke
            if ($LASTEXITCODE -ne 0) { throw "smoke-0.I.$smokeIdx FAILED" }
        } else {
            Write-Warning "Smoke gate not found: $smoke (sub-phase may not be sealed yet)"
        }
    }
    Write-Host "`n========== Phase 0.I full apply COMPLETE ==========" -ForegroundColor Green
    return
}

Invoke-TerraformAction -EnvName $envMap[$Verb] -Act $Action -VarArgs $Vars
