/*
 * role-overlay-loki-tls.tf -- Phase 0.I.2, ADR-0038 -- Loki cert render
 *
 * Per-host Vault Agent PKI template -> leaf + key (PKCS#8) + ca-chain into
 * /etc/nexus-loki/tls/{server.crt,server.key,ca.crt}. SANs cover:
 *   - $hostName.nexus.lab + $hostName (CN + DNS SAN)
 *   - loki.nexus.lab (the RR DNS)
 *   - localhost
 *   - IP SANs: VMnet10 backplane + VMnet11 mgmt + 127.0.0.1
 *
 * Selective ops: var.enable_loki_tls AND var.enable_loki_vault_agents.
 */

locals {
  loki_tls_per_host = {
    "loki-1" = { vmnet10 = "192.168.10.172", vmnet11 = "192.168.70.172" }
    "loki-2" = { vmnet10 = "192.168.10.173", vmnet11 = "192.168.70.173" }
    "loki-3" = { vmnet10 = "192.168.10.174", vmnet11 = "192.168.70.174" }
  }

  loki_tls_active = {
    for host, spec in local.loki_tls_per_host : host => spec
    if(
      var.enable_loki_tls && var.enable_loki_vault_agents
      && lookup(local.loki_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "loki_tls" {
  for_each = local.loki_tls_active

  triggers = {
    va_id         = null_resource.loki_vault_agent[each.key].id
    pki_role_name = var.vault_pki_obs_role_name
    loki_tls_v    = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.obs_node_user
  }

  depends_on = [null_resource.loki_vault_agent]

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
      $altNames = "$hostName,$hostName.nexus.lab,loki.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[loki-tls $hostName] cert render via Vault Agent PKI template -> /etc/nexus-loki/tls/"

      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/nexus-loki/tls/bundle.pem
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
  echo "[loki-tls-split] ERROR: bundle missing leaf/key/ca" >&2; exit 1
fi
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
[ -s "$ROOT_BUNDLE" ] || { echo "[loki-tls-split] ERROR: $ROOT_BUNDLE missing" >&2; exit 1; }
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"
cat "$LEAF" "$CA" > "$TMP/leaf-chain.pem"
sudo install -m 0644 -o loki -g loki "$TMP/leaf-chain.pem" /etc/nexus-loki/tls/server.crt
sudo install -m 0600 -o loki -g loki "$TMP/key-pkcs8.pem"  /etc/nexus-loki/tls/server.key
sudo install -m 0644 -o loki -g loki "$TMP/ca-chain.pem"   /etc/nexus-loki/tls/ca.crt
sudo install -m 0644 -o root -g root "$TMP/ca-chain.pem"  /etc/ssl/certs/obs-loki-ca.pem
echo "[loki-tls-split] $(date -u +%FT%TZ) bundle split -> /etc/nexus-loki/tls/{server.crt,server.key,ca.crt}"
'@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      $vaultAgentTemplate = @"
# 60-template-loki-tls.hcl -- Phase 0.I.2 (rendered for $hostName).
template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT
  destination     = "/etc/nexus-loki/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "loki"
  command         = "/usr/local/sbin/loki-tls-split.sh"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/loki-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/loki-tls-split.sh
sudo chmod 0755 /usr/local/sbin/loki-tls-split.sh
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-loki-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-loki-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-loki-tls.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/nexus-loki/tls/bundle.pem && break
  sleep 2
done
if ! sudo test -s /etc/nexus-loki/tls/bundle.pem; then
  echo "[loki-tls stage] ERROR: bundle.pem not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/loki-tls-split.sh
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[loki-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)" }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s /etc/nexus-loki/tls/server.crt && sudo openssl x509 -in /etc/nexus-loki/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) { throw "[loki-tls $hostName] cert files not rendered (CN=$cn) within 60s" }
      Write-Host "[loki-tls $hostName] cert rendered (CN=$cn) in /etc/nexus-loki/tls/"
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
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-loki-tls.hcl /etc/nexus-loki/tls/bundle.pem /etc/nexus-loki/tls/server.crt /etc/nexus-loki/tls/server.key /etc/nexus-loki/tls/ca.crt /etc/ssl/certs/obs-loki-ca.pem /usr/local/sbin/loki-tls-split.sh; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
