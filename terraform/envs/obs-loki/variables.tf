# nexus-infra-observability / terraform / envs / obs-loki / variables.tf

# --- Shared paths -----------------------------------------------------------
variable "template_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform\\_templates"
}
variable "vm_output_dir_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform"
}
variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}
variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}
variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles (3 nodes) ─────────────────────────────────────────────
variable "enable_loki_1" {
  type    = bool
  default = true
}
variable "enable_loki_2" {
  type    = bool
  default = true
}
variable "enable_loki_3" {
  type    = bool
  default = true
}

# Per-VM MACs (block :B4-:B6, after prom :B2/:B3 per network.md).
variable "mac_loki_1_primary" {
  type    = string
  default = "00:50:56:3F:00:B4"
}
variable "mac_loki_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:B4"
}
variable "mac_loki_2_primary" {
  type    = string
  default = "00:50:56:3F:00:B5"
}
variable "mac_loki_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:B5"
}
variable "mac_loki_3_primary" {
  type    = string
  default = "00:50:56:3F:00:B6"
}
variable "mac_loki_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:B6"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_loki_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_loki_vault_agents" {
  type    = bool
  default = true
}
variable "enable_loki_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_loki_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_loki_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_loki_tls" {
  type    = bool
  default = true
}
variable "enable_loki_config" {
  type    = bool
  default = true
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────
variable "obs_node_user" {
  type    = string
  default = "nexusadmin"
}
variable "obs_cluster_timeout_minutes" {
  type    = number
  default = 25
}
variable "vault_agent_version" {
  type    = string
  default = "1.18.5"
}
variable "vault_agent_obs_creds_dir" {
  type    = string
  default = "$HOME/.nexus"
}
variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}
variable "vault_pki_obs_role_name" {
  type    = string
  default = "observability-server"
}

# ─── KV creds (sticky-seeded by the security env's obs-creds-seed) ─────────
variable "kv_loki_s3_access_key_path" {
  type    = string
  default = "nexus/observability/loki/s3-access-key"
}
variable "kv_loki_s3_secret_key_path" {
  type    = string
  default = "nexus/observability/loki/s3-secret-key"
}

# ─── Topology vars ────────────────────────────────────────────────────────
variable "loki_dns_name" {
  type    = string
  default = "loki.nexus.lab"
}
variable "minio_s3_endpoint" {
  type    = string
  default = "minio.nexus.lab:9000"
}
variable "minio_loki_bucket" {
  type    = string
  default = "loki"
}
