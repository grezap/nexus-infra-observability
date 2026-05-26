# nexus-infra-observability / terraform / envs / obs-tempo / main.tf
#
# Phase 0.I.3 per-cluster Terraform state for the Tempo simple-scalable cluster
# (ADR-0038):
#   - tempo-1/2/3 (.172/.173/.174) -- each runs ALL components (read + write +
#     backend); memberlist gossip on backplane :7946 forms the ring;
#     replication_factor=3.
#   - Durable storage in MinIO bucket `tempo` (0.L.1) via `nexus-tempo-app`
#     tenant + scoped `tempo-tenant` policy (provisioned by the obs-tenants
#     overlay in nexus-infra-lakehouse).
#
# Cross-env prerequisites (run FIRST):
#   1. nexus-infra-vmware foundation env applied (dhcp reservations + RR DNS
#      tempo.nexus.lab + per-host A-records).
#   2. nexus-infra-vmware security env applied (observability-server PKI +
#      3 AppRole sidecars at $HOME/.nexus/vault-agent-observability-tempo-{1,2,3}.json
#      + KV seeds at nexus/observability/tempo/s3-{access,secret}-key).
#   3. nexus-infra-lakehouse lakehouse-minio env applied (obs-tenants overlay
#      creates the bucket `tempo` + `nexus-tempo-app` user + `tempo-tenant` policy).
#   4. Packer template built (obs-tempo-node).
#   5. The 4 MinIO VMs powered on (0.L.1).
#
# Apply order:
#   modules (3) -> nftables-backplane -> vault-agents (3) -> tls (3)
#   -> tempo-config (render /etc/nexus-tempo/tempo.yaml on all 3 nodes; enable +
#      start in parallel; verify ring members == 3 + push/query round-trip)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Tempo simple-scalable cluster (3 nodes, memberlist ring) ──────────────
module "tempo_1" {
  source = "../../modules/vm"
  count  = var.enable_tempo_1 ? 1 : 0

  vm_name           = "tempo-1"
  template_vmx_path = "${var.template_root}/obs-tempo-node/obs-tempo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/tempo-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_tempo_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_tempo_1_secondary
}

module "tempo_2" {
  source = "../../modules/vm"
  count  = var.enable_tempo_2 ? 1 : 0

  vm_name           = "tempo-2"
  template_vmx_path = "${var.template_root}/obs-tempo-node/obs-tempo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/tempo-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_tempo_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_tempo_2_secondary
}

module "tempo_3" {
  source = "../../modules/vm"
  count  = var.enable_tempo_3 ? 1 : 0

  vm_name           = "tempo-3"
  template_vmx_path = "${var.template_root}/obs-tempo-node/obs-tempo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/01-foundation/tempo-3"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_tempo_3_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_tempo_3_secondary
}
