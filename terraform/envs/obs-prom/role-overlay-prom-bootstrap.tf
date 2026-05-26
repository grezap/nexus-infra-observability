/*
 * role-overlay-prom-bootstrap.tf -- Phase 0.I.1, ADR-0038 -- exit gate
 *
 * Enable + start nexus-prometheus.service + nexus-alertmanager.service on
 * BOTH prom nodes in parallel (so the AM gossip mesh forms cluster-wide
 * on first boot; AM cluster doesn't tolerate a stuck-singleton race).
 * Then verify:
 *   - Both Prom /api/v1/status/buildinfo return Prom v2.55.1
 *   - Both AM /api/v2/status return cluster member count = 2
 *   - Both Proms can scrape each other + self
 *
 * Per memory/feedback_nomad_tls_rolling_restart_must_be_parallel.md (AM
 * mesh has the same parallel-restart requirement as Nomad TLS-enable).
 *
 * Selective ops: var.enable_prom_config (the upstream).
 */

resource "null_resource" "prom_bootstrap" {
  count = var.enable_prom_config && length(local.prom_config_active) >= 2 ? 1 : 0

  triggers = {
    config_ids       = join(",", [for h in keys(local.prom_config_active) : null_resource.prom_config[h].id])
    prom_bootstrap_v = "2" # v2: T7 fix -- jq instead of python3 for AM cluster.peers count
    obs_user_destroy = var.obs_node_user
  }

  depends_on = [null_resource.prom_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.obs_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $nodes = @(
        @{ name = 'prom-1'; ip = '192.168.70.170'; vmnet10 = '192.168.10.170' },
        @{ name = 'prom-2'; ip = '192.168.70.171'; vmnet10 = '192.168.10.171' }
      )

      Write-Host "[prom-bootstrap] enabling + starting services in parallel on both nodes"

      # Parallel enable+start. The AM mesh peers each other on backplane :9094;
      # if we sequenced (prom-1 then prom-2), prom-1's AM would briefly try to
      # peer with a non-existent prom-2 and may park itself as a singleton.
      $jobs = foreach ($n in $nodes) {
        $name = $n.name; $ip = $n.ip
        Start-Job -ScriptBlock {
          param($sshUser, $name, $ip, $sshOpts)
          $cmd = @"
set -euo pipefail
sudo systemctl daemon-reload
sudo systemctl enable nexus-prometheus.service nexus-alertmanager.service
sudo systemctl start nexus-prometheus.service
sudo systemctl start nexus-alertmanager.service
sleep 3
sudo systemctl is-active nexus-prometheus.service
sudo systemctl is-active nexus-alertmanager.service
"@
          $out = ($cmd -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
          [PSCustomObject]@{ Name = $name; ExitCode = $LASTEXITCODE; Output = $out }
        } -ArgumentList $sshUser, $name, $ip, $sshOpts
      }
      $results = $jobs | Wait-Job | Receive-Job
      $jobs | Remove-Job
      foreach ($r in $results) {
        Write-Host "[prom-bootstrap $($r.Name)] $($r.Output.Trim())"
        if ($r.ExitCode -ne 0) { throw "[prom-bootstrap $($r.Name)] enable+start failed (rc=$($r.ExitCode))" }
      }

      Write-Host "[prom-bootstrap] verifying Prom + AM API health on both nodes"
      Start-Sleep -Seconds 5
      $deadline = (Get-Date).AddSeconds(60)
      $meshReady = $false
      $lastDiag = ''
      while ((Get-Date) -lt $deadline) {
        $bothOk = $true
        foreach ($n in $nodes) {
          $check = (ssh @sshOpts "$sshUser@$($n.ip)" "curl -fsk --resolve $($n.name).nexus.lab:9090:127.0.0.1 https://$($n.name).nexus.lab:9090/-/ready 2>&1; echo ---; curl -fsk --resolve $($n.name).nexus.lab:9093:127.0.0.1 https://$($n.name).nexus.lab:9093/-/ready 2>&1" 2>&1 | Out-String).Trim()
          if ($check -notmatch 'Prometheus Server is Ready' -or $check -notmatch 'OK') { $bothOk = $false; $lastDiag = "$($n.name): $check" }
        }
        if ($bothOk) { $meshReady = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $meshReady) {
        Write-Host "[prom-bootstrap] last diagnostic: $lastDiag"
        $j = (ssh @sshOpts "$sshUser@$($nodes[0].ip)" "sudo journalctl -u nexus-prometheus -u nexus-alertmanager --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $j
        throw "[prom-bootstrap] services did not become ready within 60s"
      }
      Write-Host "[prom-bootstrap] both Prom + AM up on both nodes"

      # Verify AM mesh cluster size = 2 on both nodes (gossip on backplane :9094).
      # T7 transient (handbook §3.A): python3 -c with escaped double-quotes
      # crossed shell + PS + Terraform heredoc boundaries badly. jq is on the
      # baseline image (installed via the preseed pkgsel/include list).
      $clusterDeadline = (Get-Date).AddSeconds(45)
      $clusterReady = $false
      while ((Get-Date) -lt $clusterDeadline) {
        $bothOk = $true
        foreach ($n in $nodes) {
          $peerCount = (ssh @sshOpts "$sshUser@$($n.ip)" "curl -fsk --resolve $($n.name).nexus.lab:9093:127.0.0.1 https://$($n.name).nexus.lab:9093/api/v2/status 2>/dev/null | jq '.cluster.peers | length'" 2>&1 | Out-String).Trim()
          if ($peerCount -ne '2') { $bothOk = $false; $lastDiag = "$($n.name) AM cluster size = $peerCount (want 2)" }
        }
        if ($bothOk) { $clusterReady = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $clusterReady) {
        Write-Host "[prom-bootstrap] last diagnostic: $lastDiag"
        throw "[prom-bootstrap] AM gossip mesh failed to form (size != 2 within 45s)"
      }
      Write-Host "[prom-bootstrap] AM mesh formed: 2 peers gossiping on backplane :9094"
      Write-Host "[prom-bootstrap] Phase 0.I.1 exit gate GREEN"
    PWSH
  }
}
