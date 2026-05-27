# nexus-infra-observability / terraform / envs / obs-otel / variables.tf

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

variable "enable_otel_collector_1" {
  type    = bool
  default = true
}
variable "enable_otel_collector_2" {
  type    = bool
  default = true
}

# MAC block :BE-:BF (after grafana :BA-:BD)
variable "mac_otel_collector_1_primary" {
  type    = string
  default = "00:50:56:3F:00:BE"
}
variable "mac_otel_collector_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:BE"
}
variable "mac_otel_collector_2_primary" {
  type    = string
  default = "00:50:56:3F:00:BF"
}
variable "mac_otel_collector_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:BF"
}

variable "enable_otel_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_otel_vault_agents" {
  type    = bool
  default = true
}
variable "enable_otel_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_otel_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_otel_tls" {
  type    = bool
  default = true
}
variable "enable_otel_config" {
  type    = bool
  default = true
}
variable "enable_otel_bootstrap" {
  type    = bool
  default = true
}

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

# Topology
variable "otel_dns_name" {
  type    = string
  default = "otel.nexus.lab"
}
variable "tempo_dns_name" {
  type    = string
  default = "tempo.nexus.lab"
}
variable "prometheus_dns_name" {
  type    = string
  default = "prometheus.nexus.lab"
}
variable "loki_dns_name" {
  type    = string
  default = "loki.nexus.lab"
}
variable "kv_prometheus_web_auth_password_path" {
  type    = string
  default = "nexus/observability/prometheus/web-auth-password"
}
