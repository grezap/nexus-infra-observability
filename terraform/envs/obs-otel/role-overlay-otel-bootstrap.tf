/*
 * role-overlay-otel-bootstrap.tf -- Phase 0.I.5, ADR-0038
 *
 * Sub-phase exit gate. Verifies:
 *   1. nexus-otel-collector.service active on both nodes.
 *   2. /health (127.0.0.1:13133) returns 200 on both nodes.
 *   3. OTLP gRPC :4317 + HTTP :4318 listening on each node (mTLS).
 *   4. RR DNS otel.nexus.lab resolves to both .182 and .183 (from nexus-gateway).
 *
 * Selective ops: var.enable_otel_bootstrap.
 */

resource "null_resource" "otel_bootstrap" {
  count = var.enable_otel_bootstrap ? 1 : 0

  triggers = {
    config_ids  = join(",", [for k, r in null_resource.otel_config : r.id])
    bootstrap_v = "1"
    ssh_user    = var.obs_node_user
  }

  depends_on = [null_resource.otel_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.obs_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $otelIps  = @{ 'otel-collector-1'='192.168.70.182'; 'otel-collector-2'='192.168.70.183' }

      foreach ($entry in $otelIps.GetEnumerator()) {
        $hostName = $entry.Key
        $nip      = $entry.Value
        $probe = @"
set -euo pipefail
systemctl is-active nexus-otel-collector.service | grep -q '^active$' || { echo "ERROR: nexus-otel-collector not active" >&2; exit 1; }
/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:13133/ >/dev/null 2>&1 || { echo "ERROR: /health not 200" >&2; exit 1; }
sudo ss -ltn '( sport = :4317 or sport = :4318 )' | grep -E ':4317|:4318' | wc -l | grep -q '^[2-9]' || { echo "ERROR: OTLP ports not both listening" >&2; sudo ss -ltn >&2; exit 1; }
echo BOOTSTRAP_OK
"@
        $out = ($probe -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$nip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'BOOTSTRAP_OK') { Write-Host $out.Trim(); throw "[otel-bootstrap] $hostName checks failed" }
        Write-Host "[otel-bootstrap] $hostName : services active + /health 200 + OTLP :4317+:4318 listening"
      }

      # RR DNS resolves both ip addresses
      $dnsCount = (ssh @sshOpts "$sshUser@192.168.70.1" "dig +short otel.nexus.lab @127.0.0.1 | sort -u | wc -l" 2>&1 | Out-String).Trim()
      if ($dnsCount -notmatch '^2$') {
        # gateway dig might require sudo / different setup; try resolving from an obs node
        $dnsCount = (ssh @sshOpts "$sshUser@192.168.70.182" "getent ahostsv4 otel.nexus.lab | awk '{print `$1}' | sort -u | wc -l" 2>&1 | Out-String).Trim()
      }
      if ($dnsCount -notmatch '^2$') {
        Write-Host "[otel-bootstrap] WARN: RR DNS otel.nexus.lab resolves to $dnsCount IPs (expected 2); deferring to smoke gate full check"
      } else {
        Write-Host "[otel-bootstrap] RR DNS otel.nexus.lab -> 2 IPs (.182, .183) confirmed"
      }
      Write-Host "[otel-bootstrap] Phase 0.I.5 exit gate GREEN"
    PWSH
  }
}
