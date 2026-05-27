/*
 * role-overlay-grafana-pg-replication.tf -- Phase 0.I.4, ADR-0038
 *
 * Stands up the Grafana state-DB master-replica HA pair (mirrors 0.L.2
 * iceberg-pg / 0.L.4 registry-pg):
 *   0. connect ethernet1 backplane on both (NO-CARRIER auto-fix; streaming
 *      replication rides VMnet10).
 *   1. PRIMARY (grafana-pg-1): conf.d drop-in (wal_level=replica, ssl) +
 *      pg_hba (replication over backplane + grafana/admin over VMnet11 TLS) +
 *      roles (repluser + grafana) + the grafana DB.
 *   2. REPLICA (grafana-pg-2): stop + wipe PGDATA + pg_basebackup -R from the
 *      primary's backplane IP + start as a hot standby.
 *   3. keepalived on both (VRRP VIP .185, unicast, state BACKUP + nopreempt so
 *      a recovered old-primary never flaps the VIP back; notify_master promotes
 *      a standby on failover).
 *   4. verify pg_stat_replication shows the standby streaming + VIP bound.
 *
 * Per [[keepalived-check-versioned-binary]] the check script execs the
 * versioned absolute pg_isready binary (/usr/lib/postgresql/17/bin/pg_isready)
 * NOT the /usr/bin/pg_isready pg_wrapper symlink.
 *
 * Hex KV passwords (openssl rand -hex) are inline-safe in SQL (no quoting traps).
 * All creds read on-node via the local Vault Agent token; never transit the host.
 *
 * Selective ops: var.enable_grafana_pg_replication.
 */

resource "null_resource" "grafana_pg_replication" {
  count = var.enable_grafana_pg_replication ? 1 : 0

  triggers = {
    tls_pg_ids = join(",", [for k, r in null_resource.grafana_tls : r.id if can(regex("grafana-pg", k))])
    pg_repl_v  = "2" # v2: T24 -- write pg_hba on replica too (failover -> new-primary must accept new standby)
    ssh_user   = var.obs_node_user
  }

  depends_on = [null_resource.grafana_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.obs_node_user}'
      $vmrunPath   = '${var.vmrun_path}'
      $vmOutRoot   = '${var.vm_output_dir_root}'
      $primaryIp   = '192.168.70.180'
      $replicaIp   = '192.168.70.181'
      $primaryBp   = '192.168.10.180'
      $replicaBp   = '192.168.10.181'
      $vip         = '${var.grafana_db_vip}'
      $kvSuper     = '${var.kv_grafana_pg_superuser_password_path}'
      $kvRepl      = '${var.kv_grafana_pg_replication_password_path}'
      $kvGrafana   = '${var.kv_grafana_db_password_path}'
      $grafanaDb   = '${var.grafana_db_name}'
      $grafanaUser = '${var.grafana_db_user}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # ── 0. Connect the VMnet10 backplane (NO-CARRIER auto-fix) ───────────
      foreach ($n in @(@{h='grafana-pg-1';ip=$primaryIp;bp=$primaryBp}, @{h='grafana-pg-2';ip=$replicaIp;bp=$replicaBp})) {
        $vmx = Join-Path $vmOutRoot ("01-foundation\{0}\{0}.vmx" -f $n.h)
        & $vmrunPath connectNamedDevice $vmx ethernet1 2>&1 | Out-Null
      }
      Start-Sleep -Seconds 3
      foreach ($n in @(@{ip=$primaryIp;bp=$primaryBp}, @{ip=$replicaIp;bp=$replicaBp})) {
        ssh @sshOpts "$sshUser@$($n.ip)" 'sudo systemctl restart systemd-networkd' 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(2); $up = $false
        while ((Get-Date) -lt $deadline) {
          $has = (ssh @sshOpts "$sshUser@$($n.ip)" "ip -4 -o addr show nic1 2>/dev/null | grep -c '$($n.bp)'" 2>&1 | Out-String).Trim()
          if ($has -match '(?m)^[1-9]') { $up = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $up) { throw "[grafana-pg] backplane nic1 never came up on $($n.ip)" }
      }
      Write-Host "[grafana-pg] backplane up on both nodes"

      # ── 1. PRIMARY setup ────────────────────────────────────────────────
      $primaryScript = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
SUPERPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvSuper)
REPLPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRepl)
GRAFPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvGrafana)
[ -n "`$SUPERPW" ] && [ -n "`$REPLPW" ] && [ -n "`$GRAFPW" ] || { echo "ERROR: empty PG creds from KV" >&2; exit 1; }
PGVER=17
CONF=/etc/postgresql/`$PGVER/main
sudo mkdir -p `$CONF/conf.d
sudo tee `$CONF/conf.d/nexus-grafana.conf >/dev/null <<EOF
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
password_encryption = scram-sha-256
ssl = on
ssl_cert_file = '/etc/nexus-grafana-pg/tls/server.crt'
ssl_key_file = '/etc/nexus-grafana-pg/tls/server.key'
ssl_ca_file = '/etc/nexus-grafana-pg/tls/ca.crt'
EOF
grep -q "include_dir = 'conf.d'" `$CONF/postgresql.conf || echo "include_dir = 'conf.d'" | sudo tee -a `$CONF/postgresql.conf >/dev/null
if ! sudo grep -q 'NEXUS-GRAFANA-HBA' `$CONF/pg_hba.conf; then
  sudo tee -a `$CONF/pg_hba.conf >/dev/null <<EOF
# NEXUS-GRAFANA-HBA
host    replication   repluser   192.168.10.0/24   scram-sha-256
hostssl $grafanaDb    $grafanaUser 192.168.70.0/24   scram-sha-256
hostssl all           postgres   192.168.70.0/24   scram-sha-256
EOF
fi
sudo pg_ctlcluster `$PGVER main start 2>/dev/null || sudo systemctl start postgresql@`$PGVER-main || true
sudo systemctl enable postgresql@`$PGVER-main >/dev/null 2>&1 || true
for i in `$(seq 1 30); do sudo -u postgres pg_isready -q && break; sleep 2; done
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '`$SUPERPW'"
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='repluser'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER ROLE repluser WITH REPLICATION LOGIN PASSWORD '`$REPLPW'"
else
  sudo -u postgres psql -c "CREATE ROLE repluser WITH REPLICATION LOGIN PASSWORD '`$REPLPW'"
fi
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$grafanaUser'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER ROLE $grafanaUser WITH LOGIN PASSWORD '`$GRAFPW'"
else
  sudo -u postgres psql -c "CREATE ROLE $grafanaUser WITH LOGIN PASSWORD '`$GRAFPW'"
fi
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$grafanaDb'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE $grafanaDb OWNER $grafanaUser"
sudo pg_ctlcluster `$PGVER main reload 2>/dev/null || sudo systemctl reload postgresql@`$PGVER-main || true
echo PRIMARY_OK
"@
      Write-Host "[grafana-pg] configuring PRIMARY (grafana-pg-1)"
      $out = ($primaryScript -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$primaryIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'PRIMARY_OK') { Write-Host $out.Trim(); throw "[grafana-pg] primary setup failed (rc=$LASTEXITCODE)" }

      # ── 2. REPLICA setup (pg_basebackup from primary backplane) ─────────
      $replicaScript = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
REPLPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRepl)
[ -n "`$REPLPW" ] || { echo "ERROR: empty replication password from KV" >&2; exit 1; }
PGVER=17
CONF=/etc/postgresql/`$PGVER/main
DATA=/var/lib/postgresql/`$PGVER/main
sudo mkdir -p `$CONF/conf.d
sudo tee `$CONF/conf.d/nexus-grafana.conf >/dev/null <<EOF
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
password_encryption = scram-sha-256
ssl = on
ssl_cert_file = '/etc/nexus-grafana-pg/tls/server.crt'
ssl_key_file = '/etc/nexus-grafana-pg/tls/server.key'
ssl_ca_file = '/etc/nexus-grafana-pg/tls/ca.crt'
EOF
grep -q "include_dir = 'conf.d'" `$CONF/postgresql.conf || echo "include_dir = 'conf.d'" | sudo tee -a `$CONF/postgresql.conf >/dev/null
# T24 fix: replica must ALSO carry the replication pg_hba so that after a failover
# (replica -> primary) it accepts the old-primary as the new standby. pg_basebackup
# only copies the DATA dir; pg_hba.conf is in /etc/ and stays as Debian's default
# unless we write it explicitly here.
if ! sudo grep -q 'NEXUS-GRAFANA-HBA' `$CONF/pg_hba.conf; then
  sudo tee -a `$CONF/pg_hba.conf >/dev/null <<EOF
# NEXUS-GRAFANA-HBA
host    replication   repluser   192.168.10.0/24   scram-sha-256
hostssl $grafanaDb    $grafanaUser 192.168.70.0/24   scram-sha-256
hostssl all           postgres   192.168.70.0/24   scram-sha-256
EOF
fi
# walreceiver auths via .pgpass for the bg streaming connection.
echo "$${primaryBp}:5432:replication:repluser:`$REPLPW" | sudo tee /var/lib/postgresql/.pgpass >/dev/null
sudo chown postgres:postgres /var/lib/postgresql/.pgpass
sudo chmod 0600 /var/lib/postgresql/.pgpass
# Idempotent: if already a standby + streaming, no-op.
if sudo test -f `$DATA/standby.signal; then
  if sudo -u postgres psql -tAc "SELECT status FROM pg_stat_wal_receiver" 2>/dev/null | grep -qi streaming; then
    echo "REPLICA_OK (already standby + streaming)"; exit 0
  fi
  sudo pg_ctlcluster `$PGVER main restart 2>/dev/null || sudo systemctl restart postgresql@`$PGVER-main || true
  echo "REPLICA_OK (already standby; .pgpass refreshed + restarted)"; exit 0
fi
sudo pg_ctlcluster `$PGVER main stop 2>/dev/null || sudo systemctl stop postgresql@`$PGVER-main || true
sudo rm -rf `$DATA
sudo install -d -m 0700 -o postgres -g postgres `$DATA
sudo -u postgres env PGPASSWORD="`$REPLPW" pg_basebackup -h $primaryBp -p 5432 -U repluser -D `$DATA -Fp -Xs -P -R
sudo pg_ctlcluster `$PGVER main start 2>/dev/null || sudo systemctl start postgresql@`$PGVER-main
sudo systemctl enable postgresql@`$PGVER-main >/dev/null 2>&1 || true
for i in `$(seq 1 30); do sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | grep -qi t && break; sleep 2; done
echo REPLICA_OK
"@
      Write-Host "[grafana-pg] configuring REPLICA (grafana-pg-2) via pg_basebackup"
      $out = ($replicaScript -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$replicaIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'REPLICA_OK') { Write-Host $out.Trim(); throw "[grafana-pg] replica setup failed (rc=$LASTEXITCODE)" }

      # ── 3. keepalived on both (VRRP VIP, state BACKUP + nopreempt) ──────
      $promote = @'
#!/bin/bash
# nexus-grafana-pg-promote.sh -- promote this PG node if standby (failover).
if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
  /usr/bin/pg_ctlcluster 17 main promote
fi
'@
      $promoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($promote -replace "`r`n","`n")))
      foreach ($n in @(@{ip=$primaryIp;src=$primaryIp;peer=$replicaIp;prio=110}, @{ip=$replicaIp;src=$replicaIp;peer=$primaryIp;prio=100})) {
        $kaConf = @"
global_defs {
  script_user root
}
vrrp_script chk_pg {
  script "/usr/local/sbin/nexus-pg-check.sh"
  interval 5
  fall 2
  rise 2
}
vrrp_instance VI_GRAFANA_DB {
  state BACKUP
  nopreempt
  interface nic0
  virtual_router_id 85
  priority $($n.prio)
  advert_int 1
  unicast_src_ip $($n.src)
  unicast_peer {
    $($n.peer)
  }
  authentication {
    auth_type PASS
    auth_pass grafdbvr
  }
  virtual_ipaddress {
    $vip/24 dev nic0
  }
  notify_master "/etc/keepalived/nexus-grafana-pg-promote.sh"
  track_script {
    chk_pg
  }
}
"@
        $kaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kaConf -replace "`r`n","`n")))
        $kaStage = @"
set -euo pipefail
# keepalived's track_script must call the VERSIONED pg_isready (NOT the
# /usr/bin/pg_isready pg_wrapper symlink, which fails under keepalived's exec
# context -> chk_pg returns 1 -> no MASTER -> no VIP). Per
# [[keepalived-check-versioned-binary]].
sudo tee /usr/local/sbin/nexus-pg-check.sh >/dev/null <<'EOS'
#!/bin/bash
exec /usr/lib/postgresql/17/bin/pg_isready -q -h 127.0.0.1 -p 5432
EOS
sudo chmod 0755 /usr/local/sbin/nexus-pg-check.sh
echo '$promoteB64' | base64 -d | sudo tee /etc/keepalived/nexus-grafana-pg-promote.sh >/dev/null
sudo chmod 0755 /etc/keepalived/nexus-grafana-pg-promote.sh
echo '$kaB64' | base64 -d | sudo tee /etc/keepalived/keepalived.conf >/dev/null
sudo systemctl enable keepalived >/dev/null 2>&1 || true
sudo systemctl restart keepalived
echo KA_OK
"@
        $out = ($kaStage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($n.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'KA_OK') { Write-Host $out.Trim(); throw "[grafana-pg] keepalived setup failed on $($n.ip) (rc=$LASTEXITCODE)" }
      }

      # ── 4. Verify replication + VIP bound (poll; async) ─────────────────
      $rep = "0"
      $vdeadline = (Get-Date).AddMinutes(4)
      while ((Get-Date) -lt $vdeadline) {
        $rep = (ssh @sshOpts "$sshUser@$primaryIp" "sudo -u postgres psql -tAc 'SELECT count(*) FROM pg_stat_replication'" 2>&1 | Out-String).Trim()
        if ($rep -match '(?m)^[1-9]') { break }
        Start-Sleep -Seconds 5
      }
      if ($rep -notmatch '(?m)^[1-9]') {
        $diag = (ssh @sshOpts "$sshUser@$replicaIp" "sudo journalctl -u postgresql@17-main --no-pager -n 15" 2>&1 | Out-String)
        Write-Host "pg_stat_replication=$rep`n--- replica PG log ---`n$diag"
        throw "[grafana-pg] primary shows no streaming standby"
      }
      $vipUp = $false
      $vdeadline2 = (Get-Date).AddMinutes(2)
      while ((Get-Date) -lt $vdeadline2) {
        $cnt = 0
        foreach ($pgip in @($primaryIp, $replicaIp)) {
          $h = (ssh @sshOpts "$sshUser@$pgip" "ip -4 -o addr show nic0 | grep -c '$vip'" 2>&1 | Out-String).Trim()
          if ($h -match '(?m)^[1-9]') { $cnt++ }
        }
        if ($cnt -eq 1) { $vipUp = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $vipUp) {
        $kj = (ssh @sshOpts "$sshUser@$primaryIp" "sudo journalctl -u keepalived --no-pager -n 15" 2>&1 | Out-String)
        Write-Host "--- keepalived (grafana-pg-1) ---`n$kj"
        throw "[grafana-pg] VRRP VIP $vip not bound on exactly one PG node"
      }
      Write-Host "[grafana-pg] HA pair up -- streaming standby count=$rep; VIP $vip bound"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.180','192.168.70.181')) {
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now keepalived 2>/dev/null; sudo systemctl disable --now postgresql@17-main 2>/dev/null; sudo rm -f /etc/keepalived/keepalived.conf /etc/keepalived/nexus-grafana-pg-promote.sh /etc/postgresql/17/main/conf.d/nexus-grafana.conf" 2>$null
      }
      exit 0
    PWSH
  }
}
