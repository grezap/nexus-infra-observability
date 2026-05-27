/*
 * role-overlay-grafana-nftables-backplane.tf -- Phase 0.I.4, ADR-0038
 *
 * Pushes the per-role nftables ruleset to all 4 nodes + `nft -f`:
 *   - grafana-1/2 app pair: HTTPS :3000 from VMnet11 + VRRP (proto 112) + node
 *     exporter; VMnet10 trusted backplane (reserved).
 *   - grafana-pg-1/2 PG pair: PostgreSQL :5432 + VRRP on VMnet11; trusted
 *     VMnet10 backplane for streaming replication.
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md +
 * feedback_nftables_runtime_add_after_drop.md (atomic `nft -f`).
 */

locals {
  grafana_app_nodes = {
    "grafana-1" = "192.168.70.178"
    "grafana-2" = "192.168.70.179"
  }
  grafana_pg_nodes = {
    "grafana-pg-1" = "192.168.70.180"
    "grafana-pg-2" = "192.168.70.181"
  }
}

resource "null_resource" "grafana_nftables_backplane" {
  count = var.enable_grafana_nftables_backplane ? 1 : 0

  triggers = {
    node_ips     = join(",", concat(values(local.grafana_app_nodes), values(local.grafana_pg_nodes)))
    nftables_v   = "1"
    ssh_user     = var.obs_node_user
    boot_timeout = var.obs_cluster_timeout_minutes
  }

  depends_on = [
    module.grafana_1, module.grafana_2, module.grafana_pg_1, module.grafana_pg_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $appNodes    = @{ ${join("; ", [for h, ip in local.grafana_app_nodes : "'${h}' = '${ip}'"])} }
      $pgNodes     = @{ ${join("; ", [for h, ip in local.grafana_pg_nodes : "'${h}' = '${ip}'"])} }
      $sshUser     = '${var.obs_node_user}'
      $bootTimeout = ${var.obs_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $appRuleset = @'
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
        iifname "nic1" ip saddr 192.168.10.0/24 accept comment "trusted backplane (VMnet10) -- reserved"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 3000 accept comment "Grafana HTTPS :3000 from VMnet11 (direct + VIP .184)"
        iifname "nic0" ip saddr 192.168.70.0/24 ip protocol vrrp accept comment "keepalived VRRP (unicast) from VMnet11"
        counter drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
'@
      $pgRuleset = @'
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
        iifname "nic1" ip saddr 192.168.10.0/24 accept comment "trusted backplane (VMnet10) -- PG streaming replication"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 5432 accept comment "PostgreSQL :5432 from VMnet11 (direct + VIP .185)"
        iifname "nic0" ip saddr 192.168.70.0/24 ip protocol vrrp accept comment "keepalived VRRP (unicast) from VMnet11"
        counter drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
'@
      $appRulesetB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($appRuleset -replace "`r`n","`n")))
      $pgRulesetB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($pgRuleset  -replace "`r`n","`n")))

      function Push-Nft($entries, $b64) {
        foreach ($entry in $entries.GetEnumerator()) {
          $hostName = $entry.Key
          $ip       = $entry.Value
          Write-Host "[grafana-nftables $hostName] waiting for SSH + firstboot marker..."
          $deadline = (Get-Date).AddMinutes($bootTimeout)
          $booted = $false
          while ((Get-Date) -lt $deadline) {
            $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/observability-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
            if ($probe -match 'READY') { $booted = $true; break }
            Start-Sleep -Seconds 15
          }
          if (-not $booted) { throw "[grafana-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

          $apply = @"
set -euo pipefail
echo '$b64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
          $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
          if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') { Write-Host $out.Trim(); throw "[grafana-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)" }
          Write-Host "[grafana-nftables $hostName] ruleset applied"
        }
      }

      Push-Nft -entries $appNodes -b64 $appRulesetB64
      Push-Nft -entries $pgNodes  -b64 $pgRulesetB64
    PWSH
  }
}
