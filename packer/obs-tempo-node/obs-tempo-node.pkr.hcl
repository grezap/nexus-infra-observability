/*
 * obs-tempo-node -- NexusPlatform Tempo node template (Phase 0.I.3, ADR-0038).
 *
 * Per-engine template. Installs Tempo 3.x as a single-binary in simple-scalable
 * mode + logcli. Go binary; no JVM. Three instances clone into the
 * 01-foundation tier extension per vms.yaml:
 *   - tempo-1/2/3 (.172/.173/.174)
 *
 * Each Tempo node runs ALL components (read + write + backend). Memberlist
 * gossip on backplane :7946 forms the ring; replication_factor=3 (every chunk
 * lands on all 3 nodes during ingest; quorum read on the way out). Durable
 * storage is MinIO bucket `tempo` (the 0.L.1 object store) via the dedicated
 * `nexus-tempo-app` MinIO tenant + scoped `tempo-tenant` policy (ADR-0038 +
 * 0.I.3 obs-tenants).
 *
 *   - OS: Debian 13. Default RAM 4 GB (Tempo ingest + query + TSDB shipper at lab scale).
 *   - Dual-NIC: client traffic (push :3100 + gRPC :9095) on VMnet11;
 *     memberlist ring (:7946) on VMnet10 backplane.
 *
 * nexus-tempo.service is delivered DISABLED. The Terraform obs-tempo env's role
 * overlays render /etc/nexus-tempo/tempo.yaml (memberlist ring members + S3
 * backend with KV-rendered access/secret keys + TLS) + /etc/nexus-tempo/web.yml,
 * then enable + start all 3 nodes in parallel so the ring forms cluster-wide.
 *
 * Build:   cd packer/obs-tempo-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "obs-tempo-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20"

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "obs-tempo-node template (Phase 0.I.3, ADR-0038) -- built by Packer; Grafana Tempo ${var.tempo_version} single-binary simple-scalable"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "obs-tempo-node"
  sources = ["source.vmware-iso.obs-tempo-node"]

  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/observability_firstboot",
      "ansible/roles/obs_tempo",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "obs_tempo_version=${var.tempo_version}",
      "--extra-vars", "obs_tempo_download_url=${var.tempo_download_url}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- obs-tempo-node post-install checks ---'",
      "test -x /opt/tempo/tempo",
      "test -x /usr/local/bin/tempo",
      "test -d /etc/nexus-tempo",
      "test -d /var/lib/nexus-tempo",
      "systemctl cat nexus-tempo.service > /dev/null",
      "systemctl cat observability-node-firstboot.service > /dev/null",
      "systemctl is-enabled observability-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-tempo.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-tempo.service not disabled at bake' && exit 1)",
      "id tempo",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
