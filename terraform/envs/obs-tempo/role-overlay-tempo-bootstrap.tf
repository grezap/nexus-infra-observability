/*
 * role-overlay-tempo-bootstrap.tf -- Phase 0.I.3, ADR-0038 -- exit gate
 *
 * Enable + start nexus-tempo.service on all 3 Tempo nodes in PARALLEL
 * (memberlist ring forms cluster-wide on first boot). Then verify:
 *   - Tempo /ready on :3200 returns ready
 *   - memberlist ring has 3 members
 *
 * The end-to-end trace push -> query round-trip lives in smoke-0.I.3.ps1
 * (analogous to the Loki §3.B T13/T14 lesson -- Tempo's S3 push has the
 * same eventual-consistency floor as Loki).
 */

resource "null_resource" "tempo_bootstrap" {
  count = var.enable_tempo_config && length(local.tempo_config_active) >= 3 ? 1 : 0

  triggers = {
    config_ids        = join(",", [for h in keys(local.tempo_config_active) : null_resource.tempo_config[h].id])
    tempo_bootstrap_v = "1"
  }

  depends_on = [null_resource.tempo_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.obs_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $nodes = @(
        @{ name = 'tempo-1'; ip = '192.168.70.175' },
        @{ name = 'tempo-2'; ip = '192.168.70.176' },
        @{ name = 'tempo-3'; ip = '192.168.70.177' }
      )

      Write-Host "[tempo-bootstrap] enabling + starting nexus-tempo in parallel"
      $jobs = foreach ($n in $nodes) {
        $name = $n.name; $ip = $n.ip
        Start-Job -ScriptBlock {
          param($sshUser, $name, $ip, $sshOpts)
          $cmd = @"
set -euo pipefail
sudo systemctl daemon-reload
sudo systemctl enable nexus-tempo.service
sudo systemctl start nexus-tempo.service
sleep 5
sudo systemctl is-active nexus-tempo.service
"@
          $out = ($cmd -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
          [PSCustomObject]@{ Name = $name; ExitCode = $LASTEXITCODE; Output = $out }
        } -ArgumentList $sshUser, $name, $ip, $sshOpts
      }
      $results = $jobs | Wait-Job | Receive-Job
      $jobs | Remove-Job
      foreach ($r in $results) {
        Write-Host "[tempo-bootstrap $($r.Name)] $($r.Output.Trim())"
        if ($r.ExitCode -ne 0) { throw "[tempo-bootstrap $($r.Name)] enable+start failed (rc=$($r.ExitCode))" }
      }

      Write-Host "[tempo-bootstrap] verifying /ready on all 3 nodes"
      Start-Sleep -Seconds 10
      $deadline = (Get-Date).AddSeconds(120)
      $allReady = $false
      $lastDiag = ''
      while ((Get-Date) -lt $deadline) {
        $bothOk = $true
        foreach ($n in $nodes) {
          $check = (ssh @sshOpts "$sshUser@$($n.ip)" "curl -fsk --resolve $($n.name).nexus.lab:3200:127.0.0.1 https://$($n.name).nexus.lab:3200/ready 2>&1" 2>&1 | Out-String).Trim()
          if ($check -notmatch '(?i)ready') { $bothOk = $false; $lastDiag = "$($n.name): $check" }
        }
        if ($bothOk) { $allReady = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $allReady) {
        Write-Host "[tempo-bootstrap] last diagnostic: $lastDiag"
        $j = (ssh @sshOpts "$sshUser@$($nodes[0].ip)" "sudo journalctl -u nexus-tempo --no-pager -n 60" 2>&1 | Out-String)
        Write-Host $j
        throw "[tempo-bootstrap] /ready did not return ready within 120s"
      }
      Write-Host "[tempo-bootstrap] all 3 Tempo nodes /ready"

      # Verify memberlist ring has 3 members
      Write-Host "[tempo-bootstrap] verifying memberlist ring (3 members)"
      $ringDeadline = (Get-Date).AddSeconds(60)
      $ringOk = $false
      while ((Get-Date) -lt $ringDeadline) {
        $bothOk = $true
        foreach ($n in $nodes) {
          $body = (ssh @sshOpts "$sshUser@$($n.ip)" "curl -fsk --resolve $($n.name).nexus.lab:3200:127.0.0.1 https://$($n.name).nexus.lab:3200/memberlist 2>/dev/null" 2>&1 | Out-String)
          $count = ([regex]::Matches($body, '192\.168\.10\.17[567]')).Count
          if ($count -lt 3) { $bothOk = $false; $lastDiag = "$($n.name) ring count=$count" }
        }
        if ($bothOk) { $ringOk = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $ringOk) { throw "[tempo-bootstrap] memberlist ring failed to form (3 members) within 60s: $lastDiag" }
      Write-Host "[tempo-bootstrap] memberlist ring formed (3 members on all 3 nodes)"
      Write-Host "[tempo-bootstrap] Phase 0.I.3 exit gate GREEN"
    PWSH
  }
}
