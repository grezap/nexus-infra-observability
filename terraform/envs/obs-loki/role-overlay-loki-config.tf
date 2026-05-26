/*
 * role-overlay-loki-config.tf -- Phase 0.I.2, ADR-0038
 *
 * For each Loki node, render /etc/nexus-loki/loki.yaml as a Vault Agent
 * template (so the MinIO S3 access/secret keys are pulled from KV at render
 * time + rotated automatically when the KV value changes). Config carries:
 *   - server: HTTPS :3100 + gRPC :9095 (TLS via /etc/nexus-loki/tls/)
 *   - memberlist: bind :7946 on backplane; join_members points at 3 Loki backplane IPs
 *   - schema_config: TSDB v13 + object_store=s3 from 2024-01-01
 *   - storage_config: s3 endpoint=https://minio.nexus.lab:9000 bucket=loki
 *     access_key_id + secret_access_key from Vault KV at render time
 *   - common.replication_factor=3
 *   - compactor + ingester + querier + ruler (single-binary mode)
 */

locals {
  loki_config_per_host = {
    "loki-1" = { vmnet10 = "192.168.10.172", vmnet11 = "192.168.70.172" }
    "loki-2" = { vmnet10 = "192.168.10.173", vmnet11 = "192.168.70.173" }
    "loki-3" = { vmnet10 = "192.168.10.174", vmnet11 = "192.168.70.174" }
  }

  loki_config_active = {
    for host, spec in local.loki_config_per_host : host => spec
    if(
      var.enable_loki_config && var.enable_loki_tls && var.enable_loki_vault_agents
      && lookup(local.loki_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "loki_config" {
  for_each = local.loki_config_active

  triggers = {
    tls_id        = null_resource.loki_tls[each.key].id
    loki_config_v = "3" # v3: T12 fix -- ingester chunk_idle_period=30s + WAL enabled (sub-minute push->query round-trip for smoke)
    kv_s3_ak_path = var.kv_loki_s3_access_key_path
    kv_s3_sk_path = var.kv_loki_s3_secret_key_path

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.obs_node_user
  }

  depends_on = [null_resource.loki_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName    = '${each.key}'
      $ip          = '${each.value.vmnet11}'
      $vmnet10     = '${each.value.vmnet10}'
      $kvAk        = '${var.kv_loki_s3_access_key_path}'
      $kvSk        = '${var.kv_loki_s3_secret_key_path}'
      $bucket      = '${var.minio_loki_bucket}'
      $s3Endpoint  = '${var.minio_s3_endpoint}'
      $sshUser     = '${var.obs_node_user}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[loki-config $hostName] rendering /etc/nexus-loki/loki.yaml"

      # Vault Agent template -- the S3 access/secret keys come from KV at
      # render time. instance_addr pinned to the backplane IP so memberlist
      # advertises the right address.
      $lokiYmlTemplate = @"
# 70-template-loki-yaml.hcl -- Phase 0.I.2 (rendered for $hostName).
template {
  contents = <<EOT
auth_enabled: false

server:
  http_listen_address: 0.0.0.0
  http_listen_port: 3100
  grpc_listen_address: 0.0.0.0
  grpc_listen_port: 9095
  http_tls_config:
    cert_file: /etc/nexus-loki/tls/server.crt
    key_file:  /etc/nexus-loki/tls/server.key
    client_auth_type: NoClientCert
  # T10 transient (handbook §3.A): gRPC :9095 is plain-text inter-component
  # backplane traffic on VMnet10 (segmentation = security boundary). Enabling
  # grpc_tls_config without matching per-component grpc_client_config blocks
  # made distributor->ingester writes fail "error reading server preface: EOF".
  # Simpler + correct: rely on VMnet10 trust, TLS on the client-facing :3100.

common:
  instance_addr: $vmnet10
  path_prefix: /var/lib/nexus-loki
  replication_factor: 3
  ring:
    kvstore:
      store: memberlist
  storage:
    s3:
      endpoint: $s3Endpoint
      bucketnames: $bucket
      access_key_id: {{ with secret `"$kvAk`" }}{{ .Data.data.value }}{{ end }}
      secret_access_key: {{ with secret `"$kvSk`" }}{{ .Data.data.value }}{{ end }}
      s3forcepathstyle: true
      insecure: false

memberlist:
  bind_addr: ["$vmnet10"]
  bind_port: 7946
  join_members:
    - "192.168.10.172:7946"
    - "192.168.10.173:7946"
    - "192.168.10.174:7946"

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /var/lib/nexus-loki/tsdb-shipper-active
    cache_location: /var/lib/nexus-loki/tsdb-shipper-cache
    cache_ttl: 24h
  aws:
    endpoint: $s3Endpoint
    bucketnames: $bucket
    access_key_id: {{ with secret `"$kvAk`" }}{{ .Data.data.value }}{{ end }}
    secret_access_key: {{ with secret `"$kvSk`" }}{{ .Data.data.value }}{{ end }}
    s3forcepathstyle: true
    insecure: false

compactor:
  working_directory: /var/lib/nexus-loki/compactor
  retention_enabled: true
  delete_request_store: s3

# T12 transient (handbook §3.A): default chunk_idle_period=30m delays small-
# stream visibility on query (smoke probes timed out at 90s). Lab-friendly
# 30s gives sub-minute push->query round-trip; production tunes back up.
ingester:
  chunk_idle_period: 30s
  max_chunk_age: 2h
  chunk_target_size: 1572864
  chunk_retain_period: 30s
  wal:
    enabled: true
    dir: /var/lib/nexus-loki/wal

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_query_lookback: 0s
  retention_period: 168h
  allow_structured_metadata: true

ruler:
  storage:
    type: s3
    s3:
      endpoint: $s3Endpoint
      bucketnames: $bucket
      access_key_id: {{ with secret `"$kvAk`" }}{{ .Data.data.value }}{{ end }}
      secret_access_key: {{ with secret `"$kvSk`" }}{{ .Data.data.value }}{{ end }}
      s3forcepathstyle: true
  rule_path: /var/lib/nexus-loki/rules-temp
  alertmanager_url: https://alertmanager.nexus.lab:9093
  ring:
    kvstore:
      store: memberlist
EOT
  destination = "/etc/nexus-loki/loki.yaml"
  perms       = "0640"
  user        = "root"
  group       = "loki"
  command     = "/bin/sh -c 'sudo systemctl is-active nexus-loki >/dev/null 2>&1 && sudo systemctl reload nexus-loki || true'"
}
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($lokiYmlTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
echo '$b64' | base64 -d | sudo tee /etc/vault-agent/70-template-loki-yaml.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-loki-yaml.hcl
sudo chmod 0644 /etc/vault-agent/70-template-loki-yaml.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/nexus-loki/loki.yaml && break
  sleep 2
done
if ! sudo test -s /etc/nexus-loki/loki.yaml; then
  echo "[loki-config stage] ERROR: loki.yaml not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 30 >&2
  exit 1
fi
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[loki-config $hostName] config render stage failed (rc=$LASTEXITCODE)" }
      Write-Host "[loki-config $hostName] loki.yaml rendered"
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
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-loki-yaml.hcl /etc/nexus-loki/loki.yaml; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
