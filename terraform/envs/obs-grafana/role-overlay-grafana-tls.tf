/*
 * role-overlay-grafana-tls.tf -- Phase 0.I.4, ADR-0038 -- Grafana cert render
 *
 * Per-host Vault Agent PKI template -> leaf + key (PKCS#8) + ca-chain into:
 *   grafana-1/2  : /etc/nexus-grafana/tls/{server.crt,server.key,ca.crt}      (owner root:grafana 0640/0750)
 *   grafana-pg-* : /etc/nexus-grafana-pg/tls/{server.crt,server.key,ca.crt}   (owner root:postgres 0640/0750)
 *
 * SAN coverage (per role):
 *   - Grafana app:  CN <host>.nexus.lab + DNS <host>, <host>.nexus.lab, grafana.nexus.lab, localhost
 *                   IP SANs: VMnet10 backplane + VMnet11 mgmt + .184 (VIP) + 127.0.0.1
 *   - Grafana PG:   CN <host>.nexus.lab + DNS <host>, <host>.nexus.lab, grafana-db.nexus.lab, localhost
 *                   IP SANs: VMnet10 backplane + VMnet11 mgmt + .185 (VIP) + 127.0.0.1
 *
 * The VIP IP-SAN is what makes `sslmode=verify-full` against the floating VIP
 * validate regardless of which node holds it (ADR-0025 LB-tier HA canon).
 *
 * Selective ops: var.enable_grafana_tls AND var.enable_grafana_vault_agents.
 */

locals {
  grafana_tls_per_host = {
    "grafana-1"    = { vmnet10 = "192.168.10.178", vmnet11 = "192.168.70.178", role = "app", svc_dir = "/etc/nexus-grafana", svc_user = "grafana", vip = "192.168.70.184", vip_dns = "grafana.nexus.lab" }
    "grafana-2"    = { vmnet10 = "192.168.10.179", vmnet11 = "192.168.70.179", role = "app", svc_dir = "/etc/nexus-grafana", svc_user = "grafana", vip = "192.168.70.184", vip_dns = "grafana.nexus.lab" }
    "grafana-pg-1" = { vmnet10 = "192.168.10.180", vmnet11 = "192.168.70.180", role = "pg", svc_dir = "/etc/nexus-grafana-pg", svc_user = "postgres", vip = "192.168.70.185", vip_dns = "grafana-db.nexus.lab" }
    "grafana-pg-2" = { vmnet10 = "192.168.10.181", vmnet11 = "192.168.70.181", role = "pg", svc_dir = "/etc/nexus-grafana-pg", svc_user = "postgres", vip = "192.168.70.185", vip_dns = "grafana-db.nexus.lab" }
  }

  grafana_tls_active = {
    for host, spec in local.grafana_tls_per_host : host => spec
    if(
      var.enable_grafana_tls && var.enable_grafana_vault_agents
      && lookup(local.grafana_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "grafana_tls" {
  for_each = local.grafana_tls_active

  triggers = {
    va_id         = null_resource.grafana_vault_agent[each.key].id
    pki_role_name = var.vault_pki_obs_role_name
    grafana_tls_v = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.obs_node_user
    destroy_svc_dir  = each.value.svc_dir
  }

  depends_on = [null_resource.grafana_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $role     = '${each.value.role}'
      $svcDir   = '${each.value.svc_dir}'
      $svcUser  = '${each.value.svc_user}'
      $vip      = '${each.value.vip}'
      $vipDns   = '${each.value.vip_dns}'
      $pkiRole  = '${var.vault_pki_obs_role_name}'
      $sshUser  = '${var.obs_node_user}'
      $cn       = "$hostName.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$vipDns,localhost"
      $ipSans   = "$vmnet10,$ip,$vip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[grafana-tls $hostName] cert render via Vault Agent PKI template -> $svcDir/tls/ (role=$role; SAN +$vipDns +$vip)"

      $splitScript = @"
#!/bin/bash
set -euo pipefail
BUNDLE=$svcDir/tls/bundle.pem
TMP=`$(mktemp -d)
trap "rm -rf `$TMP" EXIT
awk -v tmp="`$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "`$BUNDLE"
LEAF=""; KEY=""; CA=""
for f in "`$TMP"/block-*; do
  hdr=`$(head -1 "`$f")
  case "`$hdr" in
    *"PRIVATE KEY"*) KEY=`$f ;;
    *"BEGIN CERTIFICATE"*) if [ -z "`$LEAF" ]; then LEAF=`$f; else CA=`$f; fi ;;
  esac
done
if [ -z "`$LEAF" ] || [ -z "`$KEY" ] || [ -z "`$CA" ]; then
  echo "[grafana-tls-split] ERROR: bundle missing leaf/key/ca" >&2; exit 1
fi
openssl pkcs8 -topk8 -nocrypt -in "`$KEY" -out "`$TMP/key-pkcs8.pem"
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
[ -s "`$ROOT_BUNDLE" ] || { echo "[grafana-tls-split] ERROR: `$ROOT_BUNDLE missing" >&2; exit 1; }
cat "`$CA" "`$ROOT_BUNDLE" > "`$TMP/ca-chain.pem"
cat "`$LEAF" "`$CA" > "`$TMP/leaf-chain.pem"
sudo install -m 0644 -o $svcUser -g $svcUser "`$TMP/leaf-chain.pem" $svcDir/tls/server.crt
sudo install -m 0600 -o $svcUser -g $svcUser "`$TMP/key-pkcs8.pem"  $svcDir/tls/server.key
sudo install -m 0644 -o $svcUser -g $svcUser "`$TMP/ca-chain.pem"   $svcDir/tls/ca.crt
sudo install -m 0644 -o root -g root "`$TMP/ca-chain.pem"  /etc/ssl/certs/obs-grafana-$role-ca.pem
echo "[grafana-tls-split] `$(date -u +%FT%TZ) bundle split -> $svcDir/tls/{server.crt,server.key,ca.crt}"
"@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      $vaultAgentTemplate = @"
# 60-template-grafana-$role-tls.hcl -- Phase 0.I.4 (rendered for $hostName).
template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT
  destination     = "$svcDir/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "$svcUser"
  command         = "/usr/local/sbin/grafana-tls-split.sh"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
sudo install -d -m 0750 -o root -g $svcUser $svcDir/tls
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/grafana-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/grafana-tls-split.sh
sudo chmod 0755 /usr/local/sbin/grafana-tls-split.sh
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-grafana-$role-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-grafana-$role-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-grafana-$role-tls.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s $svcDir/tls/bundle.pem && break
  sleep 2
done
if ! sudo test -s $svcDir/tls/bundle.pem; then
  echo "[grafana-tls stage] ERROR: bundle.pem not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/grafana-tls-split.sh
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[grafana-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)" }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $svcDir/tls/server.crt && sudo openssl x509 -in $svcDir/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) { throw "[grafana-tls $hostName] cert files not rendered (CN=$cn) within 60s" }
      $sanCheck = (ssh @sshOpts "$sshUser@$ip" "sudo openssl x509 -in $svcDir/tls/server.crt -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1" 2>&1 | Out-String).Trim()
      if ($sanCheck -notmatch $vip) { throw "[grafana-tls $hostName] cert does NOT include VIP IP-SAN $vip -- SAN line: $sanCheck" }
      Write-Host "[grafana-tls $hostName] cert rendered (CN=$cn; IP-SAN includes VIP $vip) in $svcDir/tls/"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $svcDir   = '${self.triggers.destroy_svc_dir}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-grafana-*.hcl $svcDir/tls/bundle.pem $svcDir/tls/server.crt $svcDir/tls/server.key $svcDir/tls/ca.crt /etc/ssl/certs/obs-grafana-*-ca.pem /usr/local/sbin/grafana-tls-split.sh; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
