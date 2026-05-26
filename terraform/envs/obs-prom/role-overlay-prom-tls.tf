/*
 * role-overlay-prom-tls.tf -- Phase 0.I.1, ADR-0038 -- Prom HA cert render
 *
 * Per-host Vault Agent PKI template -> leaf + key (PKCS#8) + ca-chain.
 * Single cert per node covers BOTH co-resident services (Prometheus :9090 +
 * Alertmanager :9093 + AM mesh :9094), landed in /etc/nexus-prometheus/tls/
 * AND /etc/nexus-alertmanager/tls/ (same bytes, two services). SANs cover:
 *   - $hostName.nexus.lab + $hostName (CN + DNS SAN)
 *   - prometheus.nexus.lab (the RR DNS for Prom)
 *   - alertmanager.nexus.lab (the RR DNS for AM)
 *   - localhost (smoke-gate local probes)
 *   - IP SANs: VMnet10 backplane + VMnet11 mgmt + 127.0.0.1
 *
 * Port of the lakehouse iceberg-tls overlay shape; same split-script
 * skeleton + PKCS#8 + SSH-stdin + HCL-heredoc escaping per
 * memory/feedback_vault_agent_template_hcl_heredoc.md.
 *
 * Selective ops: var.enable_prom_tls AND var.enable_prom_vault_agents.
 */

locals {
  prom_tls_per_host = {
    "prom-1" = { vmnet10 = "192.168.10.170", vmnet11 = "192.168.70.170" }
    "prom-2" = { vmnet10 = "192.168.10.171", vmnet11 = "192.168.70.171" }
  }

  prom_tls_active = {
    for host, spec in local.prom_tls_per_host : host => spec
    if(
      var.enable_prom_tls && var.enable_prom_vault_agents
      && lookup(local.prom_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "prom_tls" {
  for_each = local.prom_tls_active

  triggers = {
    va_id         = null_resource.prom_vault_agent[each.key].id
    pki_role_name = var.vault_pki_obs_role_name
    prom_tls_v    = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.obs_node_user
  }

  depends_on = [null_resource.prom_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $pkiRole  = '${var.vault_pki_obs_role_name}'
      $sshUser  = '${var.obs_node_user}'
      $cn       = "$hostName.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,prometheus.nexus.lab,alertmanager.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[prom-tls $hostName] cert render via Vault Agent PKI template -> /etc/nexus-{prometheus,alertmanager}/tls/"

      $splitScript = @'
#!/bin/bash
set -euo pipefail
# prom-tls-split.sh -- split the Vault Agent bundle into leaf-chain.pem + key.pem + ca-chain.pem
# and install into BOTH /etc/nexus-prometheus/tls/ and /etc/nexus-alertmanager/tls/.
BUNDLE=/etc/nexus-prometheus/tls/bundle.pem
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"
LEAF=""; KEY=""; CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*) KEY=$f ;;
    *"BEGIN CERTIFICATE"*) if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi ;;
  esac
done
if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[prom-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2; exit 1
fi
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
[ -s "$ROOT_BUNDLE" ] || { echo "[prom-tls-split] ERROR: $ROOT_BUNDLE missing" >&2; exit 1; }
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"
cat "$LEAF" "$CA" > "$TMP/leaf-chain.pem"

# Install into both service dirs (same bytes).
for svc in prometheus alertmanager; do
  destdir=/etc/nexus-$svc/tls
  case "$svc" in
    prometheus)   owner=prometheus;   group=prometheus   ;;
    alertmanager) owner=alertmanager; group=alertmanager ;;
  esac
  sudo install -m 0644 -o "$owner" -g "$group" "$TMP/leaf-chain.pem" "$destdir/server.crt"
  sudo install -m 0600 -o "$owner" -g "$group" "$TMP/key-pkcs8.pem"  "$destdir/server.key"
  sudo install -m 0644 -o "$owner" -g "$group" "$TMP/ca-chain.pem"   "$destdir/ca.crt"
done
sudo install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/obs-ca.pem
echo "[prom-tls-split] $(date -u +%FT%TZ) bundle split -> /etc/nexus-{prometheus,alertmanager}/tls/{server.crt,server.key,ca.crt}"
'@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      $vaultAgentTemplate = @"
# 60-template-prom-tls.hcl -- Phase 0.I.1 (rendered for $hostName).
template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT
  destination     = "/etc/nexus-prometheus/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "prometheus"
  command         = "/usr/local/sbin/prom-tls-split.sh"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
# alertmanager user/group provisioned by the obs_prom role at bake time;
# prometheus user/group provisioned by apt (prometheus-node-exporter).
sudo mkdir -p /etc/nexus-prometheus/tls /etc/nexus-alertmanager/tls
sudo chown root:prometheus   /etc/nexus-prometheus/tls
sudo chown root:alertmanager /etc/nexus-alertmanager/tls
sudo chmod 0750 /etc/nexus-prometheus/tls /etc/nexus-alertmanager/tls
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/prom-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/prom-tls-split.sh
sudo chmod 0755 /usr/local/sbin/prom-tls-split.sh
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-prom-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-prom-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-prom-tls.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/nexus-prometheus/tls/bundle.pem && break
  sleep 2
done
if ! sudo test -s /etc/nexus-prometheus/tls/bundle.pem; then
  echo "[prom-tls stage] ERROR: bundle.pem not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/prom-tls-split.sh
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[prom-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)" }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s /etc/nexus-prometheus/tls/server.crt && sudo test -s /etc/nexus-alertmanager/tls/server.crt && sudo openssl x509 -in /etc/nexus-prometheus/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) { throw "[prom-tls $hostName] cert files not rendered (CN=$cn) within 60s" }
      Write-Host "[prom-tls $hostName] cert rendered (CN=$cn) in /etc/nexus-{prometheus,alertmanager}/tls/"
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
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-prom-tls.hcl /etc/nexus-prometheus/tls/bundle.pem /etc/nexus-prometheus/tls/server.crt /etc/nexus-prometheus/tls/server.key /etc/nexus-prometheus/tls/ca.crt /etc/nexus-alertmanager/tls/server.crt /etc/nexus-alertmanager/tls/server.key /etc/nexus-alertmanager/tls/ca.crt /etc/ssl/certs/obs-ca.pem /usr/local/sbin/prom-tls-split.sh; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
