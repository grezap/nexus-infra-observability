# nexus-infra-observability / terraform / envs / obs-prom / main.tf
#
# Phase 0.I.1 per-cluster Terraform state for the Prometheus HA + Alertmanager
# mesh (ADR-0038):
#   - prom-1 (.170) + prom-2 (.171)
#   - Both Proms scrape every fleet target independently (Grafana datasource
#     dedups on the read side); Alertmanager runs as a 2-node gossip mesh
#     co-resident on the Prom pair.
#
# Cross-env prerequisites (run in nexus-infra-vmware FIRST):
#   1. foundation env applied (dhcp reservations :B2/:B3 -> .170/.171
#      + RR DNS prometheus.nexus.lab + VRRP VIP placeholders .184/.185
#      for 0.I.4 future-readiness).
#   2. security env applied (observability-server PKI role + 2 AppRole sidecars
#      at $HOME/.nexus/vault-agent-observability-prom-{1,2}.json + KV seeds
#      at nexus/observability/prometheus/* + nexus/observability/alertmanager/*).
#   3. Packer template built (obs-prom-node).
#
# Apply order:
#   modules (2) -> nftables-backplane -> vault-agents (2) -> tls (2)
#   -> prom-config (render prom.yml + alertmanager.yml + cluster.env on both
#      nodes from vms.yaml scrape targets + Vault KV creds; enable + start
#      both services; AM mesh forms via :9094 backplane gossip)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Prometheus HA pair (each node co-hosts Alertmanager mesh peer) ───────
module "prom_1" {
  source = "../../modules/vm"
  count  = var.enable_prom_1 ? 1 : 0

  vm_name           = "prom-1"
  template_vmx_path = "${var.template_root}/obs-prom-node/obs-prom-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/prom-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_prom_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_prom_1_secondary
}

module "prom_2" {
  source = "../../modules/vm"
  count  = var.enable_prom_2 ? 1 : 0

  vm_name           = "prom-2"
  template_vmx_path = "${var.template_root}/obs-prom-node/obs-prom-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/prom-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_prom_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_prom_2_secondary
}
