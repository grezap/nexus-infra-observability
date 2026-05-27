/*
 * role-overlay-grafana-config.tf -- Phase 0.I.4, ADR-0038
 *
 * For each Grafana app node (grafana-1/2):
 *   1. Read sticky creds via Vault Agent token (admin pw, session secret_key,
 *      grafana DB pw, prom basic-auth pw -- for datasource provisioning).
 *   2. Render /etc/grafana/grafana.ini:
 *        - [server]   protocol=https; http_addr=0.0.0.0; http_port=3000;
 *                     cert_file/cert_key from /etc/nexus-grafana/tls/;
 *                     root_url against the VIP DNS name.
 *        - [database] type=postgres; host=grafana-db.nexus.lab:5432;
 *                     name/user from KV; ssl_mode=verify-full + ca.crt.
 *        - [security] admin_user=admin; admin_password=<sticky>;
 *                     secret_key=<sticky session-key>.
 *        - [users]    auto_assign_org_role=Viewer (defensive default).
 *   3. Render /etc/grafana/provisioning/datasources/nexus-obs.yaml:
 *        - Prometheus HA via prometheus.nexus.lab:9090 (basic-auth from KV)
 *        - Loki        via loki.nexus.lab:3100
 *        - Tempo       via tempo.nexus.lab:3200
 *      All datasources point to the existing leaf certs via the obs CA pin.
 *   4. Render /etc/keepalived/keepalived.conf for the APP pair VRRP VIP .184
 *      (track_script chk_grafana = HTTPS :3000 /api/health).
 *   5. Enable + start grafana-server + keepalived.
 *
 * Selective ops: var.enable_grafana_config.
 */

locals {
  grafana_app_specs = {
    "grafana-1" = { ip = "192.168.70.178", peer = "192.168.70.179", prio = 110 }
    "grafana-2" = { ip = "192.168.70.179", peer = "192.168.70.178", prio = 100 }
  }
  grafana_app_active = {
    for host, spec in local.grafana_app_specs : host => spec
    if var.enable_grafana_config && lookup(local.grafana_tls_active, host, null) != null
  }
}

resource "null_resource" "grafana_config" {
  for_each = local.grafana_app_active

  triggers = {
    pg_repl_id  = length(null_resource.grafana_pg_replication) > 0 ? null_resource.grafana_pg_replication[0].id : "disabled"
    tls_id      = null_resource.grafana_tls[each.key].id
    config_v    = "2" # v2: T21 -- sudo-prefix the apply-time /api/health curl (0750-root:grafana traversal trap)
    destroy_ip  = each.value.ip
    destroy_ssh = var.obs_node_user
  }

  depends_on = [
    null_resource.grafana_tls,
    null_resource.grafana_pg_replication,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName  = '${each.key}'
      $ip        = '${each.value.ip}'
      $peer      = '${each.value.peer}'
      $prio      = ${each.value.prio}
      $vip       = '${var.grafana_vip}'
      $vipDns    = '${var.grafana_dns_name}'
      $pgVipDns  = '${var.grafana_db_dns_name}'
      $grafDb    = '${var.grafana_db_name}'
      $grafUser  = '${var.grafana_db_user}'
      $promDns   = '${var.prometheus_dns_name}'
      $lokiDns   = '${var.loki_dns_name}'
      $tempoDns  = '${var.tempo_dns_name}'
      $kvAdmin   = '${var.kv_grafana_admin_password_path}'
      $kvSession = '${var.kv_grafana_session_key_path}'
      $kvGrafDb  = '${var.kv_grafana_db_password_path}'
      $kvProm    = '${var.kv_prometheus_web_auth_password_path}'
      $sshUser   = '${var.obs_node_user}'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[grafana-config $hostName] rendering /etc/grafana/grafana.ini + datasources + keepalived"

      $stage = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
ADMINPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvAdmin)
SESSION=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvSession)
GRAFPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvGrafDb)
PROMPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=password $kvProm)
[ -n "`$ADMINPW" ] && [ -n "`$SESSION" ] && [ -n "`$GRAFPW" ] && [ -n "`$PROMPW" ] || { echo "ERROR: empty creds from KV" >&2; exit 1; }

# ── 1. grafana.ini ────────────────────────────────────────────────────────
sudo install -d -m 0750 -o root -g grafana /etc/grafana
sudo tee /etc/grafana/grafana.ini >/dev/null <<EOF
# NexusPlatform Phase 0.I.4 -- Grafana HA over shared PG state + VRRP VIP .184
# (rendered by terraform/envs/obs-grafana/role-overlay-grafana-config.tf)

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning

[server]
protocol = https
http_addr = 0.0.0.0
http_port = 3000
domain = $vipDns
root_url = https://$vipDns:3000/
cert_file = /etc/nexus-grafana/tls/server.crt
cert_key  = /etc/nexus-grafana/tls/server.key

[database]
type = postgres
host = $${pgVipDns}:5432
name = $grafDb
user = $grafUser
password = `$GRAFPW
ssl_mode = verify-full
ca_cert_path = /etc/nexus-grafana/tls/ca.crt

[security]
admin_user = admin
admin_password = `$ADMINPW
secret_key = `$SESSION
cookie_secure = true
cookie_samesite = strict
strict_transport_security = true

[users]
auto_assign_org_role = Viewer
default_theme = dark

[auth]
disable_login_form = false

[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false

[log]
mode = file console
level = info
EOF
sudo chown root:grafana /etc/grafana/grafana.ini
sudo chmod 0640 /etc/grafana/grafana.ini

# ── 2. Datasource provisioning ────────────────────────────────────────────
sudo install -d -m 0750 -o root -g grafana /etc/grafana/provisioning/datasources
sudo tee /etc/grafana/provisioning/datasources/nexus-obs.yaml >/dev/null <<EOF
apiVersion: 1
deleteDatasources:
  - { name: Prometheus, orgId: 1 }
  - { name: Loki,       orgId: 1 }
  - { name: Tempo,      orgId: 1 }
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: https://$${promDns}:9090
    isDefault: true
    basicAuth: true
    basicAuthUser: admin
    secureJsonData:
      basicAuthPassword: `$PROMPW
    jsonData:
      tlsAuthWithCACert: true
      tlsSkipVerify: false
    secureJsonData_extra:
      tlsCACert: ''
  - name: Loki
    type: loki
    access: proxy
    url: https://$${lokiDns}:3100
    jsonData:
      tlsAuthWithCACert: true
      tlsSkipVerify: false
      maxLines: 5000
      derivedFields:
        - { name: TraceID, matcherRegex: 'traceID=(\w+)', url: '$${__value.raw}', datasourceUid: tempo }
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: https://$${tempoDns}:3200
    jsonData:
      tlsAuthWithCACert: true
      tlsSkipVerify: false
EOF
# T(0.I.4): Grafana's provisioning YAML cannot inline CA cert content for the
# tlsAuthWithCACert path; instead, pin the OS-trust path by symlinking the
# obs-CA into the system trust store on each grafana node.
sudo cp /etc/nexus-grafana/tls/ca.crt /usr/local/share/ca-certificates/nexus-obs-ca.crt
sudo update-ca-certificates >/dev/null 2>&1
sudo chown root:grafana /etc/grafana/provisioning/datasources/nexus-obs.yaml
sudo chmod 0640 /etc/grafana/provisioning/datasources/nexus-obs.yaml

# ── 3. keepalived for the APP pair VRRP VIP .184 ──────────────────────────
sudo tee /usr/local/sbin/nexus-grafana-check.sh >/dev/null <<'EOS'
#!/bin/bash
# Health check for the grafana app keepalived chk_grafana.
# Connects to local Grafana over HTTPS; certificate trust pinned via curl --cacert.
# keepalived runs as root (script_user root), so no sudo needed for the cacert read.
exec /usr/bin/curl -fsS --max-time 4 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:127.0.0.1 https://grafana.nexus.lab:3000/api/health -o /dev/null
EOS
sudo chmod 0755 /usr/local/sbin/nexus-grafana-check.sh

sudo tee /etc/keepalived/keepalived.conf >/dev/null <<EOF
global_defs {
  script_user root
}
vrrp_script chk_grafana {
  script "/usr/local/sbin/nexus-grafana-check.sh"
  interval 5
  fall 3
  rise 2
}
vrrp_instance VI_GRAFANA {
  state BACKUP
  nopreempt
  interface nic0
  virtual_router_id 84
  priority $prio
  advert_int 1
  unicast_src_ip $ip
  unicast_peer {
    $peer
  }
  authentication {
    auth_type PASS
    auth_pass grafanvr
  }
  virtual_ipaddress {
    $vip/24 dev nic0
  }
  track_script {
    chk_grafana
  }
}
EOF

# ── 4. Enable + start grafana-server + keepalived ─────────────────────────
sudo systemctl daemon-reload
sudo systemctl enable grafana-server >/dev/null 2>&1 || true
sudo systemctl restart grafana-server
sudo systemctl enable keepalived >/dev/null 2>&1 || true
sudo systemctl restart keepalived

# Wait up to 90s for /api/health to return 200 against the cert.
for i in `$(seq 1 30); do
  if sudo /usr/bin/curl -fsS --max-time 4 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:127.0.0.1 https://grafana.nexus.lab:3000/api/health >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
sudo /usr/bin/curl -fsS --max-time 4 --cacert /etc/nexus-grafana/tls/ca.crt --resolve grafana.nexus.lab:3000:127.0.0.1 https://grafana.nexus.lab:3000/api/health >/dev/null 2>&1 || { sudo journalctl -u grafana-server --no-pager -n 20; echo "ERROR: grafana-server /api/health did not return 200" >&2; exit 1; }
echo GRAFANA_CONFIG_OK
"@
      $out = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'GRAFANA_CONFIG_OK') { Write-Host $out.Trim(); throw "[grafana-config $hostName] failed (rc=$LASTEXITCODE)" }
      Write-Host "[grafana-config $hostName] grafana-server + keepalived up; /api/health 200"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip      = '${self.triggers.destroy_ip}'
      $sshUser = '${self.triggers.destroy_ssh}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now grafana-server keepalived 2>/dev/null; sudo rm -f /etc/grafana/grafana.ini /etc/grafana/provisioning/datasources/nexus-obs.yaml /etc/keepalived/keepalived.conf /usr/local/sbin/nexus-grafana-check.sh /usr/local/share/ca-certificates/nexus-obs-ca.crt; sudo update-ca-certificates --fresh >/dev/null 2>&1" 2>$null
      exit 0
    PWSH
  }
}
