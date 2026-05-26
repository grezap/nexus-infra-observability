/*
 * obs-prom-node -- NexusPlatform Prometheus + Alertmanager node template
 * (Phase 0.I.1, ADR-0038).
 *
 * Per-engine template. Installs Prometheus + Alertmanager (Go binaries; no JVM).
 * Two instances clone into the 01-foundation tier extension per vms.yaml:
 *   - prom-1/2 (.170/.171)
 *
 * Both Proms in the HA pair scrape every fleet target independently; Grafana's
 * Prometheus datasource dedups on the read side (ADR-0038). Alertmanager runs
 * as a 2-node gossip mesh co-resident on the Prom pair (cluster.peer.url) --
 * Alertmanager dedupes fired alerts cluster-wide.
 *
 *   - OS: Debian 13. Default RAM 4 GB (Prom TSDB + retention + queries + AM mesh).
 *   - Dual-NIC: client/Grafana traffic on VMnet11 (Prom :9090 HTTPS, AM :9093 HTTPS);
 *     mesh / backplane coordination on VMnet10 (AM mesh :9094, scrape from build
 *     host + every fleet VM via the VMnet11 mgmt plane).
 *
 * nexus-prometheus.service + nexus-alertmanager.service are delivered DISABLED.
 * The Terraform obs-prom env's role overlays render /etc/nexus-prometheus/
 * prometheus.yml (scrape targets from vms.yaml + Alertmanager :9093 alerting
 * block) + /etc/nexus-alertmanager/alertmanager.yml (cluster peers + routes),
 * then enable + start both services on both nodes together so the mesh forms.
 *
 * Build:   cd packer/obs-prom-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "obs-prom-node" {
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
    "annotation"           = "obs-prom-node template (Phase 0.I.1, ADR-0038) -- built by Packer; Prometheus ${var.prometheus_version} + Alertmanager ${var.alertmanager_version}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "obs-prom-node"
  sources = ["source.vmware-iso.obs-prom-node"]

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
      "ansible/roles/obs_prom",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "obs_prometheus_version=${var.prometheus_version}",
      "--extra-vars", "obs_prometheus_download_url=${var.prometheus_download_url}",
      "--extra-vars", "obs_alertmanager_version=${var.alertmanager_version}",
      "--extra-vars", "obs_alertmanager_download_url=${var.alertmanager_download_url}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- obs-prom-node post-install checks ---'",
      "test -x /opt/prometheus/prometheus",
      "test -x /opt/prometheus/promtool",
      "test -x /opt/alertmanager/alertmanager",
      "test -x /opt/alertmanager/amtool",
      "test -d /etc/nexus-prometheus",
      "test -d /etc/nexus-alertmanager",
      "systemctl cat nexus-prometheus.service > /dev/null",
      "systemctl cat nexus-alertmanager.service > /dev/null",
      "systemctl cat observability-node-firstboot.service > /dev/null",
      "systemctl is-enabled observability-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-prometheus.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-prometheus.service not disabled at bake' && exit 1)",
      "systemctl is-enabled nexus-alertmanager.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-alertmanager.service not disabled at bake' && exit 1)",
      "id prometheus",
      "id alertmanager",
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
