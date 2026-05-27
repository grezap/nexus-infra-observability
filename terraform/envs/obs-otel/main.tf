# nexus-infra-observability / terraform / envs / obs-otel / main.tf
#
# Phase 0.I.5 per-cluster Terraform state for the OTel Collector pair (ADR-0038).
# 2 nodes, active-active, fronted by **round-robin DNS** `otel.nexus.lab` --
# NO VIP per ADR-0031 (write paths retry; OTel exporters have native
# retry-with-backoff).
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env applied (dhcp reservations + RR DNS
#      otel.nexus.lab + per-host A-records for .182/.183).
#   2. nexus-infra-vmware security env applied (observability-server PKI role
#      already covers otel-collector-1/2.nexus.lab + otel.nexus.lab; 14 AppRole
#      sidecars include otel-collector-1/2).
#   3. Packer template built (obs-otel-collector-node).
#   4. Prom HA + Loki + Tempo running (the routing targets).
#
# Apply order:
#   modules (2) -> nftables-backplane -> vault-agents (2) -> tls (2)
#   -> otel-config (render config.yaml with TLS receivers + Tempo/Prom-RW/Loki
#                   exporters + pipelines; enable + start in parallel)
#   -> otel-bootstrap (exit gate: services up + OTLP receivers listening +
#                      /debug/servicez 200; data-plane round-trip opt-in
#                      via -Strict on smoke)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

module "otel_collector_1" {
  source = "../../modules/vm"
  count  = var.enable_otel_collector_1 ? 1 : 0

  vm_name           = "otel-collector-1"
  template_vmx_path = "${var.template_root}/obs-otel-collector-node/obs-otel-collector-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/otel-collector-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_otel_collector_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_otel_collector_1_secondary
}

module "otel_collector_2" {
  source = "../../modules/vm"
  count  = var.enable_otel_collector_2 ? 1 : 0

  vm_name           = "otel-collector-2"
  template_vmx_path = "${var.template_root}/obs-otel-collector-node/obs-otel-collector-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/otel-collector-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_otel_collector_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_otel_collector_2_secondary
}
