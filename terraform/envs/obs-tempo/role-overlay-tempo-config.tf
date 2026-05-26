/*
 * role-overlay-tempo-config.tf -- Phase 0.I.3, ADR-0038
 *
 * Render /etc/nexus-tempo/tempo.yaml on each of the 3 Tempo nodes as a
 * Vault Agent template -- the MinIO S3 access/secret keys are pulled from
 * KV at render time. Tempo single-binary scalable mode:
 *   - server :3200 HTTP, :9095 gRPC (HTTPS via /etc/nexus-tempo/tls/)
 *   - distributor receivers: OTLP gRPC :4317 + OTLP HTTP :4318 (TLS)
 *   - ingester + querier + compactor + metrics_generator
 *   - memberlist :7946 on backplane
 *   - storage.trace.backend=s3, bucket=tempo, KV-rendered creds
 */

locals {
  tempo_config_per_host = {
    "tempo-1" = { vmnet10 = "192.168.10.175", vmnet11 = "192.168.70.175" }
    "tempo-2" = { vmnet10 = "192.168.10.176", vmnet11 = "192.168.70.176" }
    "tempo-3" = { vmnet10 = "192.168.10.177", vmnet11 = "192.168.70.177" }
  }

  tempo_config_active = {
    for host, spec in local.tempo_config_per_host : host => spec
    if(
      var.enable_tempo_config && var.enable_tempo_tls && var.enable_tempo_vault_agents
      && lookup(local.tempo_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "tempo_config" {
  for_each = local.tempo_config_active

  triggers = {
    tls_id         = null_resource.tempo_tls[each.key].id
    tempo_config_v = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.obs_node_user
  }

  depends_on = [null_resource.tempo_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName    = '${each.key}'
      $ip          = '${each.value.vmnet11}'
      $vmnet10     = '${each.value.vmnet10}'
      $kvAk        = '${var.kv_tempo_s3_access_key_path}'
      $kvSk        = '${var.kv_tempo_s3_secret_key_path}'
      $bucket      = '${var.minio_tempo_bucket}'
      $s3Endpoint  = '${var.minio_s3_endpoint}'
      $sshUser     = '${var.obs_node_user}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[tempo-config $hostName] rendering /etc/nexus-tempo/tempo.yaml"

      $tempoYmlTemplate = @"
# 70-template-tempo-yaml.hcl -- Phase 0.I.3 (rendered for $hostName).
template {
  contents = <<EOT
server:
  http_listen_address: 0.0.0.0
  http_listen_port: 3200
  grpc_listen_address: 0.0.0.0
  grpc_listen_port: 9095
  http_tls_config:
    cert_file: /etc/nexus-tempo/tls/server.crt
    key_file:  /etc/nexus-tempo/tls/server.key
    client_auth_type: NoClientCert
  # gRPC backplane :9095 stays plain-text (VMnet10 segmentation) -- mirrors
  # the Loki T10 lesson (handbook §3.B T10).

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
          tls:
            cert_file: /etc/nexus-tempo/tls/server.crt
            key_file:  /etc/nexus-tempo/tls/server.key
        http:
          endpoint: 0.0.0.0:4318
          tls:
            cert_file: /etc/nexus-tempo/tls/server.crt
            key_file:  /etc/nexus-tempo/tls/server.key
  log_received_spans:
    enabled: false

ingester:
  lifecycler:
    address: $vmnet10
    ring:
      kvstore:
        store: memberlist
      replication_factor: 3
  max_block_duration: 5m

memberlist:
  bind_addr: ["$vmnet10"]
  bind_port: 7946
  join_members:
    - "192.168.10.175:7946"
    - "192.168.10.176:7946"
    - "192.168.10.177:7946"

compactor:
  compaction:
    block_retention: 168h

storage:
  trace:
    backend: s3
    s3:
      endpoint: $s3Endpoint
      bucket: $bucket
      access_key: {{ with secret `"$kvAk`" }}{{ .Data.data.value }}{{ end }}
      secret_key: {{ with secret `"$kvSk`" }}{{ .Data.data.value }}{{ end }}
      insecure: false
      forcepathstyle: true
    pool:
      max_workers: 100
      queue_depth: 10000
    wal:
      path: /var/lib/nexus-tempo/wal
    local:
      path: /var/lib/nexus-tempo/blocks

metrics_generator:
  storage:
    path: /var/lib/nexus-tempo/generator-wal
EOT
  destination = "/etc/nexus-tempo/tempo.yaml"
  perms       = "0640"
  user        = "root"
  group       = "tempo"
  command     = "/bin/sh -c 'sudo systemctl is-active nexus-tempo >/dev/null 2>&1 && sudo systemctl reload nexus-tempo || true'"
}
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($tempoYmlTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
echo '$b64' | base64 -d | sudo tee /etc/vault-agent/70-template-tempo-yaml.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-tempo-yaml.hcl
sudo chmod 0644 /etc/vault-agent/70-template-tempo-yaml.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/nexus-tempo/tempo.yaml && break
  sleep 2
done
if ! sudo test -s /etc/nexus-tempo/tempo.yaml; then
  echo "[tempo-config stage] ERROR: tempo.yaml not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 30 >&2
  exit 1
fi
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[tempo-config $hostName] config render stage failed (rc=$LASTEXITCODE)" }
      Write-Host "[tempo-config $hostName] tempo.yaml rendered"
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
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-tempo-yaml.hcl /etc/nexus-tempo/tempo.yaml; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
