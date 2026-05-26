/*
 * role-overlay-loki-bootstrap.tf -- Phase 0.I.2, ADR-0038 -- exit gate
 *
 * Enable + start nexus-loki.service on ALL 3 Loki nodes in PARALLEL (so
 * the memberlist ring forms cluster-wide on first boot; sequential start
 * would race with one node briefly being a singleton -- same lesson as
 * feedback_nomad_tls_rolling_restart_must_be_parallel.md). Then verify:
 *   - All 3 Loki /ready return ready (with 503 retries for ~30s during
 *     "ingester not ready: please retry").
 *   - Memberlist ring has 3 members on all 3 nodes (probe via /metrics
 *     `cortex_member_ring_members` gauge or /memberlist endpoint).
 *   - End-to-end push: write a log line via the loki-1 push API + query
 *     it back via the loki-3 query API (proves S3 backend + ring works).
 *
 * Selective ops: var.enable_loki_config (the upstream).
 */

resource "null_resource" "loki_bootstrap" {
  count = var.enable_loki_config && length(local.loki_config_active) >= 3 ? 1 : 0

  triggers = {
    config_ids       = join(",", [for h in keys(local.loki_config_active) : null_resource.loki_config[h].id])
    loki_bootstrap_v = "5" # v5: T13 final -- bootstrap verifies ring only; push/query round-trip moved to smoke-0.I.2.ps1 (eventual consistency 1-6 min)
  }

  depends_on = [null_resource.loki_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.obs_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $nodes = @(
        @{ name = 'loki-1'; ip = '192.168.70.172' },
        @{ name = 'loki-2'; ip = '192.168.70.173' },
        @{ name = 'loki-3'; ip = '192.168.70.174' }
      )

      Write-Host "[loki-bootstrap] enabling + starting nexus-loki in parallel on all 3 nodes"

      $jobs = foreach ($n in $nodes) {
        $name = $n.name; $ip = $n.ip
        Start-Job -ScriptBlock {
          param($sshUser, $name, $ip, $sshOpts)
          $cmd = @"
set -euo pipefail
sudo systemctl daemon-reload
sudo systemctl enable nexus-loki.service
sudo systemctl start nexus-loki.service
sleep 5
sudo systemctl is-active nexus-loki.service
"@
          $out = ($cmd -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
          [PSCustomObject]@{ Name = $name; ExitCode = $LASTEXITCODE; Output = $out }
        } -ArgumentList $sshUser, $name, $ip, $sshOpts
      }
      $results = $jobs | Wait-Job | Receive-Job
      $jobs | Remove-Job
      foreach ($r in $results) {
        Write-Host "[loki-bootstrap $($r.Name)] $($r.Output.Trim())"
        if ($r.ExitCode -ne 0) { throw "[loki-bootstrap $($r.Name)] enable+start failed (rc=$($r.ExitCode))" }
      }

      Write-Host "[loki-bootstrap] verifying /ready on all 3 nodes (ingesters may need ~30s to settle)"
      Start-Sleep -Seconds 10
      $deadline = (Get-Date).AddSeconds(120)
      $allReady = $false
      $lastDiag = ''
      while ((Get-Date) -lt $deadline) {
        $bothOk = $true
        foreach ($n in $nodes) {
          $check = (ssh @sshOpts "$sshUser@$($n.ip)" "curl -fsk --resolve $($n.name).nexus.lab:3100:127.0.0.1 https://$($n.name).nexus.lab:3100/ready 2>&1" 2>&1 | Out-String).Trim()
          if ($check -notmatch '(?i)ready') { $bothOk = $false; $lastDiag = "$($n.name): $check" }
        }
        if ($bothOk) { $allReady = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $allReady) {
        Write-Host "[loki-bootstrap] last diagnostic: $lastDiag"
        $j = (ssh @sshOpts "$sshUser@$($nodes[0].ip)" "sudo journalctl -u nexus-loki --no-pager -n 60" 2>&1 | Out-String)
        Write-Host $j
        throw "[loki-bootstrap] /ready did not return ready within 120s"
      }
      Write-Host "[loki-bootstrap] all 3 Loki nodes /ready"

      # Verify the memberlist ring formed cluster-wide (3 members visible from
      # each node). Bootstrap deliberately does NOT do an end-to-end log
      # push+query round-trip -- that has a 1-6 min eventual-consistency
      # floor (WAL -> chunk_idle_period -> S3 PUT -> TSDB index -> cross-node
      # index visibility) which is too variable for a tight exit gate. The
      # data-plane round-trip is in smoke-0.I.2.ps1 §S3 round-trip with a
      # 6-min retry budget. T11/T12/T13 transients in handbook §3.A.
      Write-Host "[loki-bootstrap] verifying memberlist ring formed (3 members on each node)"
      $ringDeadline = (Get-Date).AddSeconds(60)
      $ringOk = $false
      $lastRing = ''
      while ((Get-Date) -lt $ringDeadline) {
        $bothOk = $true
        foreach ($n in $nodes) {
          $body = (ssh @sshOpts "$sshUser@$($n.ip)" "curl -fsk --resolve $($n.name).nexus.lab:3100:127.0.0.1 https://$($n.name).nexus.lab:3100/memberlist 2>/dev/null" 2>&1 | Out-String)
          $count = ([regex]::Matches($body, '192\.168\.10\.17[234]')).Count
          if ($count -lt 3) { $bothOk = $false; $lastRing = "$($n.name) ring count=$count (want 3)" }
        }
        if ($bothOk) { $ringOk = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $ringOk) { throw "[loki-bootstrap] memberlist ring failed to form (3 members) within 60s: $lastRing" }
      Write-Host "[loki-bootstrap] memberlist ring formed (3 members on all 3 nodes)"
      Write-Host "[loki-bootstrap] Phase 0.I.2 exit gate GREEN (push/query round-trip deferred to smoke-0.I.2)"
    PWSH
  }
}
