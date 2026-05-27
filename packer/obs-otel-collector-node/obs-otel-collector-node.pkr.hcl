/*
 * obs-otel-collector-node -- NexusPlatform OTel Collector node template
 * (Phase 0.I.5, ADR-0038).
 *
 * Per-engine template. Installs OpenTelemetry Collector Contrib (Go binary,
 * upstream release tarball). Two instances clone into the 01-foundation tier
 * extension per vms.yaml:
 *   - otel-collector-1/2 (.182/.183)
 *
 * Active-active pair fronted by **round-robin DNS** `otel.nexus.lab` (no VIP
 * per ADR-0031 -- write paths retry on connection failure; OTel exporters
 * have native retry-with-backoff). Each Collector receives OTLP from the app
 * fleet and fans out: traces -> Tempo (OTLP gRPC), metrics -> Prometheus
 * remote-write, logs -> Loki push.
 *
 *   - OS: Debian 13. Default RAM 2 GB (Collector is lightweight; batch
 *     processor caps memory).
 *   - Dual-NIC: OTLP receivers + node_exporter on VMnet11; no backplane
 *     traffic (Collectors are independent; clients retry on connection
 *     failure -- ADR-0031). nic1 reserved.
 *
 * nexus-otel-collector.service is delivered DISABLED. The Terraform obs-otel
 * env renders /etc/nexus-otel-collector/config.yaml + TLS material, then
 * enables + starts the service on both nodes in parallel.
 *
 * Build:   cd packer/obs-otel-collector-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "obs-otel-collector-node" {
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
    "annotation"           = "obs-otel-collector-node template (Phase 0.I.5, ADR-0038) -- built by Packer; OTel Collector Contrib ${var.otel_version}; RR DNS otel.nexus.lab (no VIP per ADR-0031)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "obs-otel-collector-node"
  sources = ["source.vmware-iso.obs-otel-collector-node"]

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
      "ansible/roles/obs_otel_collector",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "obs_otel_version=${var.otel_version}",
      "--extra-vars", "obs_otel_download_url=${var.otel_download_url}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- obs-otel-collector-node post-install checks ---'",
      "ls -la /opt/otel-collector/otelcol-contrib /usr/local/bin/otelcol-contrib 2>/dev/null || true",
      "test -x /opt/otel-collector/otelcol-contrib || (echo 'ERROR: /opt/otel-collector/otelcol-contrib missing' && exit 1)",
      "sudo test -d /etc/nexus-otel-collector || (echo 'ERROR: /etc/nexus-otel-collector dir missing' && exit 1)",
      "sudo test -d /etc/nexus-otel-collector/tls",
      "systemctl cat nexus-otel-collector.service > /dev/null",
      "systemctl cat observability-node-firstboot.service > /dev/null",
      "systemctl is-enabled observability-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "if systemctl is-enabled --quiet nexus-otel-collector.service; then echo 'ERROR: nexus-otel-collector.service still enabled at bake'; exit 1; fi",
      "id otel",
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
