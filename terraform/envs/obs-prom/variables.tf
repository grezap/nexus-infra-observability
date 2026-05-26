# nexus-infra-observability / terraform / envs / obs-prom / variables.tf

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

# ─── Per-VM toggles (2 nodes) ─────────────────────────────────────────────
variable "enable_prom_1" {
  type    = bool
  default = true
}
variable "enable_prom_2" {
  type    = bool
  default = true
}

# Per-VM MACs (block :B2/:B3, just past registry high-water :B1; obs tier
# block :B2-:BF spans all 14 Phase 0.I obs nodes per network.md).
# MUST match nexus-infra-vmware foundation env's mac_obs_prom_{1,2}_primary.
variable "mac_prom_1_primary" {
  type    = string
  default = "00:50:56:3F:00:B2"
}
variable "mac_prom_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:B2"
}
variable "mac_prom_2_primary" {
  type    = string
  default = "00:50:56:3F:00:B3"
}
variable "mac_prom_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:B3"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_prom_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_prom_vault_agents" {
  type    = bool
  default = true
}
variable "enable_prom_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_prom_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_prom_tls" {
  type    = bool
  default = true
}
variable "enable_prom_config" {
  type        = bool
  default     = true
  description = "role-overlay-prom-config.tf -- render /etc/nexus-prometheus/prometheus.yml (scrape targets from vms.yaml) + /etc/nexus-alertmanager/alertmanager.yml (mesh peers + routes) + /etc/nexus-alertmanager/cluster.env (NEXUS_AM_PEER backplane gossip URL); enable + start both services on both nodes (AM mesh forms via :9094)."
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

# ─── KV creds (sticky-seeded by the security env) ─────────────────────────
variable "kv_prom_web_auth_path" {
  type        = string
  default     = "nexus/observability/prometheus/web-auth-password"
  description = "Prometheus web auth (operator basic-auth) password. Sticky-seeded; rotation = re-render web.yml + SIGHUP."
}
variable "kv_alertmanager_web_auth_path" {
  type    = string
  default = "nexus/observability/alertmanager/web-auth-password"
}
variable "kv_alertmanager_slack_webhook_path" {
  type        = string
  default     = "nexus/observability/alertmanager/slack-webhook"
  description = "Placeholder for the Slack/webhook route receiver URL. Lab default is a noop receiver."
}

# ─── Topology vars ────────────────────────────────────────────────────────
variable "prom_1_vmnet10_ip" {
  type    = string
  default = "192.168.10.170"
}
variable "prom_2_vmnet10_ip" {
  type    = string
  default = "192.168.10.171"
}
variable "prom_1_vmnet11_ip" {
  type    = string
  default = "192.168.70.170"
}
variable "prom_2_vmnet11_ip" {
  type    = string
  default = "192.168.70.171"
}
variable "prom_dns_name" {
  type    = string
  default = "prometheus.nexus.lab"
}
variable "alertmanager_dns_name" {
  type    = string
  default = "alertmanager.nexus.lab"
}
