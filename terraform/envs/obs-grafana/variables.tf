# nexus-infra-observability / terraform / envs / obs-grafana / variables.tf

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
  default = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
}
variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}
variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles (4 nodes) ─────────────────────────────────────────────
variable "enable_grafana_1" {
  type    = bool
  default = true
}
variable "enable_grafana_2" {
  type    = bool
  default = true
}
variable "enable_grafana_pg_1" {
  type    = bool
  default = true
}
variable "enable_grafana_pg_2" {
  type    = bool
  default = true
}

# Per-VM MACs (block :BA-:BD per network.md — grafana :BA/:BB, grafana-pg :BC/:BD).
variable "mac_grafana_1_primary" {
  type    = string
  default = "00:50:56:3F:00:BA"
}
variable "mac_grafana_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:BA"
}
variable "mac_grafana_2_primary" {
  type    = string
  default = "00:50:56:3F:00:BB"
}
variable "mac_grafana_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:BB"
}
variable "mac_grafana_pg_1_primary" {
  type    = string
  default = "00:50:56:3F:00:BC"
}
variable "mac_grafana_pg_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:BC"
}
variable "mac_grafana_pg_2_primary" {
  type    = string
  default = "00:50:56:3F:00:BD"
}
variable "mac_grafana_pg_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:BD"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_grafana_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_grafana_vault_agents" {
  type    = bool
  default = true
}
variable "enable_grafana_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_grafana_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_grafana_pg_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_grafana_pg_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_grafana_tls" {
  type    = bool
  default = true
}
variable "enable_grafana_pg_replication" {
  type    = bool
  default = true
}
variable "enable_grafana_config" {
  type    = bool
  default = true
}
variable "enable_grafana_bootstrap" {
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

# ─── KV creds paths (sticky-seeded by the security env's obs-creds-seed v3) ─
variable "kv_grafana_pg_superuser_password_path" {
  type    = string
  default = "nexus/observability/grafana-pg/superuser-password"
}
variable "kv_grafana_pg_replication_password_path" {
  type    = string
  default = "nexus/observability/grafana-pg/replication-password"
}
variable "kv_grafana_db_password_path" {
  type        = string
  default     = "nexus/observability/grafana-pg/grafana-db-password"
  description = "Password for the `grafana` PG user that Grafana app uses to read/write its state-DB."
}
variable "kv_grafana_admin_password_path" {
  type    = string
  default = "nexus/observability/grafana/admin-password"
}
variable "kv_grafana_session_key_path" {
  type        = string
  default     = "nexus/observability/grafana/session-key"
  description = "Grafana [security] secret_key (cookie signing key)."
}

# ─── Topology vars ────────────────────────────────────────────────────────
variable "grafana_dns_name" {
  type    = string
  default = "grafana.nexus.lab"
}
variable "grafana_vip" {
  type    = string
  default = "192.168.70.184"
}
variable "grafana_db_dns_name" {
  type    = string
  default = "grafana-db.nexus.lab"
}
variable "grafana_db_vip" {
  type    = string
  default = "192.168.70.185"
}
variable "grafana_db_name" {
  type        = string
  default     = "grafana"
  description = "Postgres database name that Grafana uses for its state."
}
variable "grafana_db_user" {
  type        = string
  default     = "grafana"
  description = "Postgres role that Grafana authenticates as."
}

# ─── Datasource pre-provisioning targets (existing RR DNS) ────────────────
variable "prometheus_dns_name" {
  type    = string
  default = "prometheus.nexus.lab"
}
variable "loki_dns_name" {
  type    = string
  default = "loki.nexus.lab"
}
variable "tempo_dns_name" {
  type    = string
  default = "tempo.nexus.lab"
}

# ─── KV creds for the Prom + AM basic auth (Grafana datasource needs them) ─
variable "kv_prometheus_web_auth_password_path" {
  type    = string
  default = "nexus/observability/prometheus/web-auth-password"
}
