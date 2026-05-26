/*
 * role-overlay-prom-config.tf -- Phase 0.I.1, ADR-0038 -- render prometheus.yml + alertmanager.yml + cluster.env
 *
 * For each Prom node, render:
 *   - /etc/nexus-prometheus/prometheus.yml  (TLS-listening Prom + scrape targets)
 *   - /etc/nexus-prometheus/web.yml         (basic-auth via Vault KV bcrypt)
 *   - /etc/nexus-alertmanager/alertmanager.yml (null receiver for v0.1; AM mesh)
 *   - /etc/nexus-alertmanager/web.yml        (basic-auth via Vault KV bcrypt)
 *   - /etc/nexus-alertmanager/cluster.env    (NEXUS_AM_PEER -- the OTHER prom's
 *     VMnet10 IP + :9094 for gossip mesh; NEXUS_VMNET10_IP -- self for advertise)
 *
 * Scrape targets (initial v0.1 set; 0.I.6 fleet rollout expands to every VM):
 *   - prom-1/2 self                          (node_exporter :9100 + Prom :9090)
 *   - alertmanager mesh peer self            (:9093)
 *   - 6 foundation VMs (vault-1/2/3 + vault-transit + dc-nexus + nexus-gateway)
 *     via node_exporter :9100 + Vault :8200/metrics
 *
 * Selective ops: var.enable_prom_config AND var.enable_prom_tls AND var.enable_prom_vault_agents.
 */

locals {
  prom_config_per_host = {
    "prom-1" = { vmnet10 = "192.168.10.170", vmnet11 = "192.168.70.170", peer_vmnet10 = "192.168.10.171" }
    "prom-2" = { vmnet10 = "192.168.10.171", vmnet11 = "192.168.70.171", peer_vmnet10 = "192.168.10.170" }
  }

  prom_config_active = {
    for host, spec in local.prom_config_per_host : host => spec
    if(
      var.enable_prom_config && var.enable_prom_tls && var.enable_prom_vault_agents
      && lookup(local.prom_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "prom_config" {
  for_each = local.prom_config_active

  triggers = {
    tls_id           = null_resource.prom_tls[each.key].id
    peer_vmnet10     = each.value.peer_vmnet10
    prom_config_v    = "3" # v3: T6 fix -- drop basic_auth_users from web.yml (TLS-only; smoke /-/ready no longer 401s)
    kv_web_auth_path = var.kv_prom_web_auth_path
    kv_am_auth_path  = var.kv_alertmanager_web_auth_path

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.obs_node_user
  }

  depends_on = [null_resource.prom_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName    = '${each.key}'
      $ip          = '${each.value.vmnet11}'
      $vmnet10     = '${each.value.vmnet10}'
      $peerVmnet10 = '${each.value.peer_vmnet10}'
      $kvWebPath   = '${var.kv_prom_web_auth_path}'
      $kvAmPath    = '${var.kv_alertmanager_web_auth_path}'
      $sshUser     = '${var.obs_node_user}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[prom-config $hostName] rendering prometheus.yml + alertmanager.yml + cluster.env"

      # Render the prometheus.yml + alertmanager.yml + web.yml templates as
      # Vault Agent templates (so the basic-auth bcrypt is pulled from KV at
      # render time + rotated automatically when the KV value changes).

      $promYmlTemplate = @"
# 70-template-prometheus-yml.hcl -- Phase 0.I.1 (rendered for $hostName).
template {
  contents = <<EOT
global:
  scrape_interval:     30s
  evaluation_interval: 30s
  external_labels:
    cluster: nexus-observability
    replica: $hostName

alerting:
  alertmanagers:
    - scheme: https
      tls_config:
        ca_file: /etc/nexus-prometheus/tls/ca.crt
        cert_file: /etc/nexus-prometheus/tls/server.crt
        key_file: /etc/nexus-prometheus/tls/server.key
      static_configs:
        - targets: ['prom-1.nexus.lab:9093', 'prom-2.nexus.lab:9093']

scrape_configs:
  - job_name: prometheus
    scheme: https
    tls_config:
      ca_file: /etc/nexus-prometheus/tls/ca.crt
      cert_file: /etc/nexus-prometheus/tls/server.crt
      key_file: /etc/nexus-prometheus/tls/server.key
    static_configs:
      - targets: ['prom-1.nexus.lab:9090', 'prom-2.nexus.lab:9090']

  - job_name: alertmanager
    scheme: https
    tls_config:
      ca_file: /etc/nexus-prometheus/tls/ca.crt
      cert_file: /etc/nexus-prometheus/tls/server.crt
      key_file: /etc/nexus-prometheus/tls/server.key
    static_configs:
      - targets: ['prom-1.nexus.lab:9093', 'prom-2.nexus.lab:9093']

  - job_name: node_exporter
    static_configs:
      - targets:
          - 'prom-1.nexus.lab:9100'
          - 'prom-2.nexus.lab:9100'
          - 'vault-1.nexus.lab:9100'
          - 'vault-2.nexus.lab:9100'
          - 'vault-3.nexus.lab:9100'
          - 'vault-transit.nexus.lab:9100'
          - 'nexus-gateway.nexus.lab:9100'
EOT
  destination = "/etc/nexus-prometheus/prometheus.yml"
  perms       = "0640"
  user        = "root"
  group       = "prometheus"
  command     = "/bin/sh -c 'sudo systemctl is-active nexus-prometheus >/dev/null 2>&1 && sudo systemctl reload nexus-prometheus || true'"
}
"@

      # Prom + AM web.yml: TLS only for v0.1 (no basic_auth_users -- the
      # basic_auth gates ALL endpoints including /-/ready, which makes the
      # bootstrap overlay readiness probe impossible without baking the
      # admin password into the probe. Grafana adds session auth in 0.I.4
      # as the real human-facing auth story; the obs tier is internal-only
      # so TLS at the wire layer is sufficient. T6 transient (handbook §3.A).
      $promWebTemplate = @"
# 71-template-prometheus-webyml.hcl -- Phase 0.I.1 (rendered for $hostName).
template {
  contents = <<EOT
tls_server_config:
  cert_file: /etc/nexus-prometheus/tls/server.crt
  key_file:  /etc/nexus-prometheus/tls/server.key
  client_auth_type: NoClientCert
EOT
  destination = "/etc/nexus-prometheus/web.yml"
  perms       = "0640"
  user        = "root"
  group       = "prometheus"
}
"@

      $amYmlTemplate = @"
# 72-template-alertmanager-yml.hcl -- Phase 0.I.1 (rendered for $hostName).
template {
  contents = <<EOT
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'null'

receivers:
  - name: 'null'

inhibit_rules: []
EOT
  destination = "/etc/nexus-alertmanager/alertmanager.yml"
  perms       = "0640"
  user        = "root"
  group       = "alertmanager"
  command     = "/bin/sh -c 'sudo systemctl is-active nexus-alertmanager >/dev/null 2>&1 && sudo systemctl reload nexus-alertmanager || true'"
}
"@

      $amWebTemplate = @"
# 73-template-alertmanager-webyml.hcl -- Phase 0.I.1 (rendered for $hostName).
template {
  contents = <<EOT
tls_server_config:
  cert_file: /etc/nexus-alertmanager/tls/server.crt
  key_file:  /etc/nexus-alertmanager/tls/server.key
  client_auth_type: NoClientCert
EOT
  destination = "/etc/nexus-alertmanager/web.yml"
  perms       = "0640"
  user        = "root"
  group       = "alertmanager"
}
"@

      # cluster.env is rendered as a regular env file (not a Vault Agent template,
      # since the AM mesh peer URL is static cluster topology).
      # T5 transient (handbook §3.A): `$peerVmnet10:9094` parses as scope-
      # qualified var per feedback_powershell_url_scope_qualifier.md; brace it.
      $clusterEnv = @"
# Phase 0.I.1 -- /etc/nexus-alertmanager/cluster.env. Static topology vars
# consumed by nexus-alertmanager.service (EnvironmentFile=).
NEXUS_VMNET10_IP=$vmnet10
NEXUS_AM_PEER=$${peerVmnet10}:9094
"@

      $promYmlB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($promYmlTemplate -replace "`r`n","`n")))
      $promWebB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($promWebTemplate -replace "`r`n","`n")))
      $amYmlB64      = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($amYmlTemplate -replace "`r`n","`n")))
      $amWebB64      = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($amWebTemplate -replace "`r`n","`n")))
      $clusterEnvB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($clusterEnv -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
echo '$promYmlB64' | base64 -d | sudo tee /etc/vault-agent/70-template-prometheus-yml.hcl > /dev/null
echo '$promWebB64' | base64 -d | sudo tee /etc/vault-agent/71-template-prometheus-webyml.hcl > /dev/null
echo '$amYmlB64'   | base64 -d | sudo tee /etc/vault-agent/72-template-alertmanager-yml.hcl > /dev/null
echo '$amWebB64'   | base64 -d | sudo tee /etc/vault-agent/73-template-alertmanager-webyml.hcl > /dev/null
echo '$clusterEnvB64' | base64 -d | sudo tee /etc/nexus-alertmanager/cluster.env > /dev/null
sudo chown root:alertmanager /etc/nexus-alertmanager/cluster.env
sudo chmod 0640 /etc/nexus-alertmanager/cluster.env
sudo chown root:root /etc/vault-agent/7*-template-*.hcl
sudo chmod 0644 /etc/vault-agent/7*-template-*.hcl
sudo systemctl restart nexus-vault-agent.service
# Wait for all 4 templates to render
for i in 1 2 3 4 5 6 7 8 9 10; do
  if sudo test -s /etc/nexus-prometheus/prometheus.yml \
     && sudo test -s /etc/nexus-prometheus/web.yml \
     && sudo test -s /etc/nexus-alertmanager/alertmanager.yml \
     && sudo test -s /etc/nexus-alertmanager/web.yml; then
    break
  fi
  sleep 2
done
if ! sudo test -s /etc/nexus-prometheus/prometheus.yml; then
  echo "[prom-config stage] ERROR: prometheus.yml not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 30 >&2
  exit 1
fi
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[prom-config $hostName] config render stage failed (rc=$LASTEXITCODE)" }
      Write-Host "[prom-config $hostName] prometheus.yml + alertmanager.yml + 2 web.yml + cluster.env rendered"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/7[0-3]-template-*.hcl /etc/nexus-prometheus/prometheus.yml /etc/nexus-prometheus/web.yml /etc/nexus-alertmanager/alertmanager.yml /etc/nexus-alertmanager/web.yml /etc/nexus-alertmanager/cluster.env; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
