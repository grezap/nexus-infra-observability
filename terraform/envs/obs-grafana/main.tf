# nexus-infra-observability / terraform / envs / obs-grafana / main.tf
#
# Phase 0.I.4 per-cluster Terraform state for the Grafana HA tier (ADR-0038).
# Most complex sub-phase of 0.I -- 4 VMs + 2 VRRP VIPs + cross-pair PG state:
#   - grafana-pg-1/2 (.180/.181)  PG 17 streaming-repl + keepalived VRRP VIP
#                                 grafana-db.nexus.lab .185 (canonical mirror of
#                                 0.L.2 iceberg-db / 0.L.4 registry-db).
#   - grafana-1/2     (.178/.179) Active-active Grafana 11.x over the shared PG
#                                 state-DB + keepalived VRRP VIP
#                                 grafana.nexus.lab .184 (front door, cert IP-SAN
#                                 includes the VIP).
#
# Cross-env prerequisites (run in nexus-infra-vmware FIRST):
#   1. foundation env applied (dhcp-host reservations + RR DNS + A-records for
#      all 4 hosts + 2 VIPs; ADR-0025 unicast VRRP).
#   2. security env applied (observability-server PKI role covers all 14 obs
#      hosts + the 2 VIP DNS + .184/.185 IPs; 14 AppRole sidecars including
#      grafana-1/2 + grafana-pg-1/2; KV seeds at nexus/observability/grafana/*
#      + nexus/observability/grafana-pg/* sticky-hex passwords).
#   3. Packer templates built (obs-grafana-node + obs-grafana-pg-node).
#   4. Prom HA + Loki + Tempo running (datasource pre-provisioning probes them).
#
# Apply order:
#   modules (4) -> nftables-backplane (per role) -> vault-agents (4) -> tls (4)
#   -> pg-replication (grafana-pg pair: PG config + repluser + grafana DB + user
#                      + keepalived VIP .185)
#   -> grafana-config (grafana-1/2: grafana.ini against VIP .185 + datasource
#                      provisioning for Prom/Loki/Tempo + enable grafana-server
#                      + keepalived VIP .184)
#   -> bootstrap (verify Grafana :3000 + datasource health + ADR-0025 VIP failover)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Grafana HA app pair (active-active over shared PG; VRRP VIP .184) ────
module "grafana_1" {
  source = "../../modules/vm"
  count  = var.enable_grafana_1 ? 1 : 0

  vm_name           = "grafana-1"
  template_vmx_path = "${var.template_root}/obs-grafana-node/obs-grafana-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/grafana-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_grafana_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_grafana_1_secondary
}

module "grafana_2" {
  source = "../../modules/vm"
  count  = var.enable_grafana_2 ? 1 : 0

  vm_name           = "grafana-2"
  template_vmx_path = "${var.template_root}/obs-grafana-node/obs-grafana-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/grafana-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_grafana_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_grafana_2_secondary
}

# ─── Grafana state-DB pair (PG17 streaming-repl; VRRP VIP .185) ───────────
module "grafana_pg_1" {
  source = "../../modules/vm"
  count  = var.enable_grafana_pg_1 ? 1 : 0

  vm_name           = "grafana-pg-1"
  template_vmx_path = "${var.template_root}/obs-grafana-pg-node/obs-grafana-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/grafana-pg-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_grafana_pg_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_grafana_pg_1_secondary
}

module "grafana_pg_2" {
  source = "../../modules/vm"
  count  = var.enable_grafana_pg_2 ? 1 : 0

  vm_name           = "grafana-pg-2"
  template_vmx_path = "${var.template_root}/obs-grafana-pg-node/obs-grafana-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/grafana-pg-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_grafana_pg_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_grafana_pg_2_secondary
}
