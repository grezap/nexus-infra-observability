/*
 * obs-grafana-node -- Packer template variables (Phase 0.I.4, ADR-0038)
 *
 * Per-engine template: Grafana OSS 11.x (apt.grafana.com) + keepalived. The
 * active-active HA app pair fronted by VRRP VIP grafana.nexus.lab .184.
 */

variable "vm_name" {
  type        = string
  default     = "obs-grafana-node"
  description = "VM display name + output .vmx basename. Per-clone names (grafana-1/2) set by terraform/envs/obs-grafana/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/obs-grafana-node"
  description = "Absolute directory for the built template."
}

variable "iso_url" {
  type    = string
  default = "H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso"
  # Local ISO from the lab canon dir (H:/VMS/ISO/, project_iso_directory). The
  # upstream mirror rotates point releases off iso-cd/ into archive within months
  # (13.5.0 already 404s there as of 2026-07), so a remote default breaks replay;
  # the checksum below still pins integrity. For a fresh host, fetch the ISO into
  # H:/VMS/ISO/ once (or override -var iso_url=<url> against the archive mirror).
}

variable "iso_checksum" {
  type    = string
  default = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
}

variable "grafana_version" {
  type        = string
  default     = "11.6.3"
  description = "Grafana OSS version (11.x LTS). apt.grafana.com `stable` channel; pinned so the bake is reproducible."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type        = number
  default     = 3072
  description = "Build-time RAM. 3 GB per vms.yaml (Grafana 11.x heap + alerting + datasource caches)."
}

variable "disk_gb" {
  type    = number
  default = 40
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
}

variable "boot_wait" {
  type    = string
  default = "20s"
}

variable "ssh_timeout" {
  type    = string
  default = "45m"
}
