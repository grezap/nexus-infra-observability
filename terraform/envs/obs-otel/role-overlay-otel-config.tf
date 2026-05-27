/*
 * role-overlay-otel-config.tf -- Phase 0.I.5, ADR-0038
 *
 * Renders /etc/nexus-otel-collector/config.yaml on both nodes:
 *   - receivers.otlp.protocols.{grpc,http} with TLS (server.crt/key + ca.crt)
 *   - processors: memory_limiter (limit_mib=400) + batch + attributes (adds
 *     nexus_collector=<host>, fleet=nexusplatform)
 *   - exporters:
 *       otlp/tempo            -> tempo.nexus.lab:4317 (gRPC; tls.ca_file=ca.crt)
 *       otlphttp/loki         -> https://loki.nexus.lab:3100/otlp/v1/logs
 *                                 (Loki 3.x native OTLP receiver; deprecated
 *                                 loki exporter removed in OTel Collector 0.86+)
 *       prometheusremotewrite -> https://prometheus.nexus.lab:9090/api/v1/write
 *                                 (basic auth from KV; Prom must have
 *                                 --web.enable-remote-write-receiver -- baked
 *                                 in 0.I.1 + retried-with-backoff if rejected)
 *   - service.pipelines: traces[otlp/tempo], metrics[prometheusremotewrite],
 *                        logs[otlphttp/loki]
 *
 * Enables + starts nexus-otel-collector.service in parallel on both nodes.
 *
 * Selective ops: var.enable_otel_config.
 */

locals {
  otel_config_specs = {
    "otel-collector-1" = { ip = "192.168.70.182" }
    "otel-collector-2" = { ip = "192.168.70.183" }
  }
  otel_config_active = {
    for host, spec in local.otel_config_specs : host => spec
    if var.enable_otel_config && lookup(local.otel_tls_active, host, null) != null
  }
}

resource "null_resource" "otel_config" {
  for_each = local.otel_config_active

  triggers = {
    tls_id      = null_resource.otel_tls[each.key].id
    config_v    = "1"
    destroy_ip  = each.value.ip
    destroy_ssh = var.obs_node_user
  }

  depends_on = [null_resource.otel_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.ip}'
      $tempoDns = '${var.tempo_dns_name}'
      $promDns  = '${var.prometheus_dns_name}'
      $lokiDns  = '${var.loki_dns_name}'
      $kvProm   = '${var.kv_prometheus_web_auth_password_path}'
      $sshUser  = '${var.obs_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[otel-config $hostName] rendering /etc/nexus-otel-collector/config.yaml + enabling service"

      $stage = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
PROMPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=password $kvProm)
[ -n "`$PROMPW" ] || { echo "ERROR: empty prom basic-auth pw" >&2; exit 1; }

sudo tee /etc/nexus-otel-collector/config.yaml >/dev/null <<EOF
# NexusPlatform Phase 0.I.5 -- OTel Collector Contrib (ADR-0038)
# Rendered by terraform/envs/obs-otel/role-overlay-otel-config.tf
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        tls:
          cert_file: /etc/nexus-otel-collector/tls/server.crt
          key_file:  /etc/nexus-otel-collector/tls/server.key
          ca_file:   /etc/nexus-otel-collector/tls/ca.crt
      http:
        endpoint: 0.0.0.0:4318
        tls:
          cert_file: /etc/nexus-otel-collector/tls/server.crt
          key_file:  /etc/nexus-otel-collector/tls/server.key
          ca_file:   /etc/nexus-otel-collector/tls/ca.crt

processors:
  memory_limiter:
    check_interval: 5s
    limit_mib: 400
    spike_limit_mib: 100
  batch:
    timeout: 5s
    send_batch_size: 1024
  attributes:
    actions:
      - key: nexus_collector
        value: $hostName
        action: upsert
      - key: fleet
        value: nexusplatform
        action: upsert

exporters:
  otlp/tempo:
    endpoint: $${tempoDns}:4317
    tls:
      ca_file: /etc/nexus-otel-collector/tls/ca.crt
      insecure: false
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 60s
      max_elapsed_time: 300s
  otlphttp/loki:
    endpoint: https://$${lokiDns}:3100/otlp
    tls:
      ca_file: /etc/nexus-otel-collector/tls/ca.crt
      insecure: false
    retry_on_failure:
      enabled: true
  prometheusremotewrite:
    endpoint: https://$${promDns}:9090/api/v1/write
    tls:
      ca_file: /etc/nexus-otel-collector/tls/ca.crt
      insecure: false
    auth:
      authenticator: basicauth/prom
    retry_on_failure:
      enabled: true

extensions:
  basicauth/prom:
    client_auth:
      username: admin
      password: `$PROMPW
  health_check:
    endpoint: 127.0.0.1:13133
  zpages:
    endpoint: 127.0.0.1:55679

service:
  extensions: [basicauth/prom, health_check, zpages]
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, attributes, batch]
      exporters:  [otlp/tempo]
    metrics:
      receivers:  [otlp]
      processors: [memory_limiter, attributes, batch]
      exporters:  [prometheusremotewrite]
    logs:
      receivers:  [otlp]
      processors: [memory_limiter, attributes, batch]
      exporters:  [otlphttp/loki]
  telemetry:
    logs:
      level: info
EOF
sudo chown root:otel /etc/nexus-otel-collector/config.yaml
sudo chmod 0640 /etc/nexus-otel-collector/config.yaml

sudo systemctl daemon-reload
sudo systemctl enable nexus-otel-collector >/dev/null 2>&1 || true
sudo systemctl restart nexus-otel-collector

# Wait for the health_check extension to come up on 127.0.0.1:13133.
for i in `$(seq 1 30); do
  if /usr/bin/curl -fsS --max-time 4 http://127.0.0.1:13133/ >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
/usr/bin/curl -fsS --max-time 4 http://127.0.0.1:13133/ >/dev/null 2>&1 || { sudo journalctl -u nexus-otel-collector --no-pager -n 20; echo "ERROR: /health did not 200 within 90s" >&2; exit 1; }
echo OTEL_CONFIG_OK
"@
      $out = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'OTEL_CONFIG_OK') { Write-Host $out.Trim(); throw "[otel-config $hostName] failed (rc=$LASTEXITCODE)" }
      Write-Host "[otel-config $hostName] nexus-otel-collector up; /health 200"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip      = '${self.triggers.destroy_ip}'
      $sshUser = '${self.triggers.destroy_ssh}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-otel-collector 2>/dev/null; sudo rm -f /etc/nexus-otel-collector/config.yaml" 2>$null
      exit 0
    PWSH
  }
}
