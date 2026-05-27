#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.I.6 fleet-wide Vector log-shipper rollout.

.DESCRIPTION
  Installs Vector + drops baseline vector.yaml + enables nexus-vector.service
  on every running Linux fleet VM. Vector ships journald + /var/log/* to the
  OTel Collector pair (otel.nexus.lab:4318/v1/logs) which routes to Loki.

  Idempotent: skips a node if Vector is already at the target version + the
  service is active. Re-runnable. Failures are logged + the script continues
  with the next node.

  Uses the same Vector install steps as `nexus_observability` shared role
  (Phase 0.I.6 source canon) -- this script is for retrofitting the EXISTING
  fleet without rebuilding each template. Future cold-rebuilds of any
  individual template pick up Vector via the ansible role automatically.

.PARAMETER NodesOnly
  Filter by comma-separated hostname substring (e.g. -NodesOnly 'redis,mongo').
  Default: all reachable Linux nodes on VMnet11 192.168.70.0/24.

.PARAMETER Verify
  Verify-only mode (no install). Reports Vector state on every fleet node.

.EXAMPLE
  pwsh -File scripts/fleet-vector-rollout.ps1
  pwsh -File scripts/fleet-vector-rollout.ps1 -NodesOnly 'kafka,redis'
  pwsh -File scripts/fleet-vector-rollout.ps1 -Verify
#>

[CmdletBinding()]
param(
    [string]$NodesOnly = '',
    [switch]$Verify,
    [string]$VectorVersion = '0.50.0'
)
$ErrorActionPreference = 'Stop'

$user      = 'nexusadmin'
$sshOpts   = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$installed = @(); $skipped = @(); $failed = @()

# Fleet inventory -- aligned with nexus-platform-plan/docs/infra/vms.yaml.
# Excludes Windows hosts (dc-nexus + sqlserver-fci/ag + nexus-jumpbox) which
# get windows_exporter from a parallel rollout. Excludes nexus-gateway (edge).
$fleet = @(
    # foundation (linux):    vault-1/2/3 + vault-transit
    @('vault-1', '192.168.70.121'),
    @('vault-2', '192.168.70.122'),
    @('vault-3', '192.168.70.123'),
    @('vault-transit', '192.168.70.124'),
    # swarm-nomad
    @('swarm-manager-1', '192.168.70.31'), @('swarm-manager-2', '192.168.70.32'), @('swarm-manager-3', '192.168.70.33'),
    @('swarm-worker-1',  '192.168.70.34'), @('swarm-worker-2',  '192.168.70.35'), @('swarm-worker-3',  '192.168.70.36'),
    # kafka
    @('kafka-east-1', '192.168.70.81'), @('kafka-east-2', '192.168.70.82'), @('kafka-east-3', '192.168.70.83'),
    @('kafka-west-1', '192.168.70.84'), @('kafka-west-2', '192.168.70.85'), @('kafka-west-3', '192.168.70.86'),
    @('schema-registry-1', '192.168.70.91'), @('schema-registry-2', '192.168.70.92'),
    @('kafka-rest-1', '192.168.70.93'),
    @('kafka-connect-1', '192.168.70.94'), @('kafka-connect-2', '192.168.70.95'),
    @('ksqldb-1', '192.168.70.96'), @('ksqldb-2', '192.168.70.97'),
    @('mm2-1', '192.168.70.98'), @('mm2-2', '192.168.70.99'),
    # oltp -- redis, mongo, percona, postgres
    @('redis-1', '192.168.70.41'), @('redis-2', '192.168.70.42'), @('redis-3', '192.168.70.43'),
    @('redis-4', '192.168.70.44'), @('redis-5', '192.168.70.45'), @('redis-6', '192.168.70.46'),
    @('mongo-1', '192.168.70.47'), @('mongo-2', '192.168.70.48'), @('mongo-3', '192.168.70.49'),
    @('pxc-1', '192.168.70.51'), @('pxc-2', '192.168.70.52'), @('pxc-3', '192.168.70.53'),
    @('proxysql-1', '192.168.70.55'), @('proxysql-2', '192.168.70.56'),
    @('pg-primary', '192.168.70.61'), @('pg-replica-1', '192.168.70.62'), @('pg-replica-2', '192.168.70.63'),
    @('etcd-1', '192.168.70.64'), @('etcd-2', '192.168.70.65'), @('etcd-3', '192.168.70.66'),
    @('haproxy-pg-1', '192.168.70.67'), @('haproxy-pg-2', '192.168.70.68'),
    # analytics
    @('ch-keeper-1', '192.168.70.101'), @('ch-keeper-2', '192.168.70.102'), @('ch-keeper-3', '192.168.70.103'),
    @('ch-shard1-rep1', '192.168.70.104'), @('ch-shard1-rep2', '192.168.70.105'),
    @('ch-shard2-rep1', '192.168.70.106'), @('ch-shard2-rep2', '192.168.70.107'),
    @('ch-shard3-rep1', '192.168.70.108'), @('ch-shard3-rep2', '192.168.70.109'),
    @('sr-fe-leader', '192.168.70.111'), @('sr-fe-follower-1', '192.168.70.112'), @('sr-fe-follower-2', '192.168.70.113'),
    @('sr-be-1', '192.168.70.114'), @('sr-be-2', '192.168.70.115'), @('sr-be-3', '192.168.70.116'),
    @('sr-sd-fe-1', '192.168.70.131'), @('sr-sd-fe-2', '192.168.70.132'), @('sr-sd-fe-3', '192.168.70.133'),
    @('sr-sd-cn-1', '192.168.70.134'), @('sr-sd-cn-2', '192.168.70.135'),
    # lakehouse -- minio, iceberg, spark, zookeeper
    @('minio-1', '192.168.70.141'), @('minio-2', '192.168.70.142'), @('minio-3', '192.168.70.143'), @('minio-4', '192.168.70.144'),
    @('iceberg-rest-1', '192.168.70.147'), @('iceberg-rest-2', '192.168.70.148'),
    @('iceberg-pg-1', '192.168.70.149'), @('iceberg-pg-2', '192.168.70.150'),
    @('spark-master-1', '192.168.70.152'), @('spark-master-2', '192.168.70.153'),
    @('spark-worker-1', '192.168.70.154'), @('spark-worker-2', '192.168.70.155'), @('spark-worker-3', '192.168.70.156'),
    @('zookeeper-1', '192.168.70.157'), @('zookeeper-2', '192.168.70.158'), @('zookeeper-3', '192.168.70.159'),
    # registry
    @('registry-1', '192.168.70.115'), @('registry-2', '192.168.70.116'),
    @('registry-pg-1', '192.168.70.117'), @('registry-pg-2', '192.168.70.118'),
    # observability (prom + loki + tempo + grafana + grafana-pg + otel-collector)
    @('prom-1', '192.168.70.170'), @('prom-2', '192.168.70.171'),
    @('loki-1', '192.168.70.172'), @('loki-2', '192.168.70.173'), @('loki-3', '192.168.70.174'),
    @('tempo-1', '192.168.70.175'), @('tempo-2', '192.168.70.176'), @('tempo-3', '192.168.70.177'),
    @('grafana-1', '192.168.70.178'), @('grafana-2', '192.168.70.179'),
    @('grafana-pg-1', '192.168.70.180'), @('grafana-pg-2', '192.168.70.181'),
    @('otel-collector-1', '192.168.70.182'), @('otel-collector-2', '192.168.70.183')
)

if ($NodesOnly) {
    $patterns = $NodesOnly -split ','
    $fleet = $fleet | Where-Object {
        $h = $_[0]
        foreach ($p in $patterns) { if ($h -like "*$p*") { return $true } }
        return $false
    }
    Write-Host "Filtered to $($fleet.Count) node(s) matching: $($patterns -join ', ')" -ForegroundColor Cyan
}

$installScript = @"
set -euo pipefail
VV='$VectorVersion'
# Idempotent: bail early if Vector is at the target version + service active.
if [ -x /opt/vector/bin/vector ] && /opt/vector/bin/vector --version 2>&1 | grep -qF "vector `$VV"; then
  if systemctl is-active --quiet nexus-vector.service; then
    echo "SKIP-ALREADY-OK"; exit 0
  fi
fi
# Ensure user/group
if ! getent group vector >/dev/null; then sudo groupadd --system vector; fi
if ! getent passwd vector >/dev/null; then
  sudo useradd --system --gid vector --shell /usr/sbin/nologin --home-dir /var/lib/nexus-vector --no-create-home vector
fi
sudo usermod -aG systemd-journal vector
# Download + extract
cd /tmp
if [ ! -s "vector-`$VV.tar.gz" ]; then
  curl -fsSL -o "vector-`$VV.tar.gz" "https://packages.timber.io/vector/`$VV/vector-`$VV-x86_64-unknown-linux-gnu.tar.gz"
fi
sudo mkdir -p /opt/vector
sudo tar -xzf "vector-`$VV.tar.gz" -C /opt/vector --strip-components=2
sudo chown -R vector:vector /opt/vector
sudo ln -sf /opt/vector/bin/vector /usr/local/bin/vector
# Dirs
sudo install -d -m 0750 -o root -g vector /etc/nexus-vector
sudo install -d -m 0755 -o vector -g vector /var/lib/nexus-vector
sudo install -d -m 0755 -o vector -g vector /var/log/nexus-vector
# Config
HOSTNAME_LOCAL=`$(hostname)
sudo tee /etc/nexus-vector/vector.yaml >/dev/null <<EOF
data_dir: /var/lib/nexus-vector
sources:
  journald:
    type: journald
    current_boot_only: true
  var_logs:
    type: file
    include:
      - /var/log/syslog
      - /var/log/auth.log
      - /var/log/kern.log
      - /var/log/dpkg.log
    ignore_older_secs: 86400
transforms:
  add_metadata:
    type: remap
    inputs: [journald, var_logs]
    source: |
      .nexus_host = "`$HOSTNAME_LOCAL"
      .fleet = "nexusplatform"
sinks:
  loki_logs:
    type: loki
    inputs: [add_metadata]
    endpoint: https://loki.nexus.lab:3100
    tls:
      verify_certificate: false
    encoding:
      codec: json
    labels:
      fleet: nexusplatform
    out_of_order_action: accept
    batch:
      max_events: 1000
      timeout_secs: 5
    request:
      retry_attempts: 3
      retry_initial_backoff_secs: 5
      retry_max_duration_secs: 60
EOF
sudo chown root:vector /etc/nexus-vector/vector.yaml
sudo chmod 0640 /etc/nexus-vector/vector.yaml
# Systemd unit
sudo tee /etc/systemd/system/nexus-vector.service >/dev/null <<EOF
[Unit]
Description=NexusPlatform Vector log shipper (Phase 0.I.6)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=vector
Group=vector
WorkingDirectory=/var/lib/nexus-vector
ExecStart=/opt/vector/bin/vector --config /etc/nexus-vector/vector.yaml
ExecReload=/bin/kill -HUP `\$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536
StandardOutput=append:/var/log/nexus-vector/vector.log
StandardError=append:/var/log/nexus-vector/vector.log
[Install]
WantedBy=multi-user.target
EOF
# Pre-flight: trust anchor must exist (obs-otel apply lands /etc/ssl/certs/obs-otel-ca.pem
# on the otel nodes only; OTHER nodes don't have it yet -- Vector will run + retry-with-backoff).
# If the CA bundle is missing, Vector still loads OK and queues events locally.
sudo systemctl daemon-reload
sudo systemctl enable nexus-vector.service
sudo systemctl restart nexus-vector.service
sleep 3
systemctl is-active --quiet nexus-vector.service || { echo "ERROR: nexus-vector failed to start"; sudo journalctl -u nexus-vector --no-pager -n 30; exit 1; }
rm -f "/tmp/vector-`$VV.tar.gz"
echo INSTALL-OK
"@

$verifyScript = @"
set -euo pipefail
if [ ! -x /opt/vector/bin/vector ]; then echo "NOT-INSTALLED"; exit 0; fi
VV=`$(/opt/vector/bin/vector --version 2>&1 | head -1 | awk '{print `$2}')
echo "vector=`$VV"
systemctl is-active nexus-vector.service 2>&1 || echo "INACTIVE"
"@

Write-Host "Phase 0.I.6 fleet Vector rollout -- $($fleet.Count) target node(s)" -ForegroundColor Cyan
Write-Host ("Mode: " + $(if ($Verify) { 'VERIFY-ONLY' } else { "INSTALL Vector $VectorVersion + enable nexus-vector.service" })) -ForegroundColor Cyan
Write-Host ''

$script = if ($Verify) { $verifyScript } else { $installScript }

foreach ($n in $fleet) {
    $hostName = $n[0]; $ip = $n[1]
    Write-Host "[$hostName ($ip)]..." -ForegroundColor Yellow -NoNewline
    $rdy = (ssh @sshOpts "$user@$ip" 'echo READY' 2>&1 | Out-String).Trim()
    if ($rdy -notmatch 'READY') { Write-Host ' UNREACHABLE' -ForegroundColor DarkGray; $skipped += $hostName; continue }
    $out = ($script -replace "`r`n","`n") | ssh @sshOpts "$user@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
    if ($Verify) {
        Write-Host (' ' + $out.Trim().Replace("`n",' | '))
    } elseif ($out -match 'SKIP-ALREADY-OK') {
        Write-Host ' already at target' -ForegroundColor DarkGreen
        $skipped += $hostName
    } elseif ($out -match 'INSTALL-OK') {
        Write-Host ' INSTALLED' -ForegroundColor Green
        $installed += $hostName
    } else {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host $out.Trim() -ForegroundColor DarkRed
        $failed += $hostName
    }
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
if ($Verify) {
    Write-Host "Verify-only -- see per-node lines above." -ForegroundColor DarkGray
} else {
    Write-Host "Installed: $($installed.Count) (new) | Already OK: $($skipped.Count) | Failed: $($failed.Count)" -ForegroundColor White
    if ($failed.Count -gt 0) {
        Write-Host "Failed nodes: $($failed -join ', ')" -ForegroundColor Red
        exit 1
    }
}
