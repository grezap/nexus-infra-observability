/*
 * role-overlay-prom-nftables-backplane.tf -- Phase 0.I.1, ADR-0038
 *
 * Pushes the per-cluster nftables ruleset to both Prom HA nodes + `nft -f`.
 * Single combined ruleset (opening a port a node doesn't listen on is
 * harmless): trust the VMnet10 backplane (Alertmanager gossip mesh on
 * :9094) + open Prom :9090 (Grafana queries + nexus-cli probes) + AM
 * :9093 (Grafana datasource + nexus-cli probes) on VMnet11.
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md +
 * feedback_nftables_runtime_add_after_drop.md (atomic `nft -f`).
 */

locals {
  prom_all_nodes = {
    "prom-1" = "192.168.70.170"
    "prom-2" = "192.168.70.171"
  }
}

resource "null_resource" "prom_nftables_backplane" {
  count = var.enable_prom_nftables_backplane ? 1 : 0

  triggers = {
    node_ips     = join(",", values(local.prom_all_nodes))
    nftables_v   = "1"
    ssh_user     = var.obs_node_user
    boot_timeout = var.obs_cluster_timeout_minutes
  }

  depends_on = [
    module.prom_1, module.prom_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes       = @{ ${join("; ", [for h, ip in local.prom_all_nodes : "'${h}' = '${ip}'"])} }
      $sshUser     = '${var.obs_node_user}'
      $bootTimeout = ${var.obs_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state { established, related } accept
        ct state invalid drop
        ip protocol icmp   accept
        ip6 nexthdr icmpv6 accept
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 22   accept comment "SSH from VMnet11"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 9100 accept comment "node_exporter from VMnet11"
        iifname "nic1" ip saddr 192.168.10.0/24 accept comment "trusted cluster backplane (VMnet10) -- AM mesh gossip :9094"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 9090, 9093 } accept comment "Prometheus :9090 + Alertmanager :9093 from VMnet11 (Grafana, nexus-cli)"
        counter drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
'@
      $rulesetB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($ruleset -replace "`r`n","`n")))

      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key
        $ip       = $entry.Value
        Write-Host "[prom-nftables $hostName] waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $booted = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/observability-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $booted = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $booted) { throw "[prom-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

        $apply = @"
set -euo pipefail
echo '$rulesetB64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
        $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') { Write-Host $out.Trim(); throw "[prom-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)" }
        Write-Host "[prom-nftables $hostName] ruleset applied"
      }
    PWSH
  }
}
