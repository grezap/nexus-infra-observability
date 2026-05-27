/*
 * obs-grafana-node -- NexusPlatform Grafana HA app-server template
 * (Phase 0.I.4, ADR-0038).
 *
 * Per-engine template. Installs Grafana OSS 11.x (apt.grafana.com) + keepalived.
 * Two instances clone into the 01-foundation tier extension per vms.yaml:
 *   - grafana-1 (.178) keepalived MASTER candidate (prio 110)
 *   - grafana-2 (.179) keepalived BACKUP            (prio 100)
 *
 * The pair runs ACTIVE-ACTIVE over a shared PG state store (grafana-pg-1/2 +
 * VRRP VIP grafana-db.nexus.lab .185). The app VIP grafana.nexus.lab .184
 * floats to the current MASTER (cert IP-SAN includes the VIP, so any client
 * that hits the VIP sees a valid leaf regardless of which node holds it).
 *
 *   - OS: Debian 13. Default RAM 3 GB (Grafana 11.x heap + alerting + datasource caches).
 *   - Dual-NIC: ethernet0 = VMnet11 (HTTPS :3000 + VRRP), ethernet1 = VMnet10
 *     (backplane: for future intra-grafana coordination; currently unused).
 *
 * The stock grafana-server.service is delivered DISABLED. The Terraform
 * obs-grafana env's overlays render:
 *   - /etc/nexus-grafana/grafana.ini      (HTTPS + PG datasource + sticky admin)
 *   - /etc/nexus-grafana/tls/             (Vault-Agent-rendered leaf + key + CA)
 *   - /etc/grafana/provisioning/datasources/nexus-obs.yaml  (Prom/Loki/Tempo)
 *   - /etc/keepalived/keepalived.conf     (VRRP VIP .184 for grafana.nexus.lab)
 * and then enables grafana-server + keepalived in parallel.
 *
 * Build:   cd packer/obs-grafana-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "obs-grafana-node" {
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
    "annotation"           = "obs-grafana-node template (Phase 0.I.4, ADR-0038) -- built by Packer; Grafana OSS ${var.grafana_version} + keepalived; active-active HA pair over shared PG (VRRP VIP .184)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "obs-grafana-node"
  sources = ["source.vmware-iso.obs-grafana-node"]

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
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https lsb-release"
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
      "ansible/roles/obs_grafana",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "obs_grafana_version=${var.grafana_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- obs-grafana-node post-install checks ---'",
      "ls -la /usr/sbin/grafana-server /usr/sbin/keepalived 2>/dev/null || true",
      "test -x /usr/sbin/grafana-server || (echo 'ERROR: /usr/sbin/grafana-server missing or not executable' && exit 1)",
      "test -x /usr/sbin/keepalived     || (echo 'ERROR: /usr/sbin/keepalived missing or not executable'     && exit 1)",
      "sudo test -d /etc/grafana && sudo test -d /etc/nexus-grafana && sudo test -d /etc/nexus-grafana/tls",
      "systemctl cat observability-node-firstboot.service > /dev/null",
      "systemctl is-enabled observability-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "if systemctl is-enabled --quiet grafana-server.service; then echo 'ERROR: grafana-server.service still enabled at bake'; exit 1; fi",
      "if systemctl is-enabled --quiet keepalived.service;     then echo 'ERROR: keepalived.service still enabled at bake';     exit 1; fi",
      "id grafana",
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
