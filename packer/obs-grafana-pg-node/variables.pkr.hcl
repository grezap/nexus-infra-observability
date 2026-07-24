/*
 * obs-grafana-pg-node -- Packer template variables (Phase 0.I.4, ADR-0038)
 *
 * Per-engine template: PostgreSQL 17 (PGDG) + keepalived. The dedicated,
 * master-replica HA Postgres state store backing Grafana HA.
 */

variable "vm_name" {
  type        = string
  default     = "obs-grafana-pg-node"
  description = "VM display name + output .vmx basename. Per-clone names (grafana-pg-1/2) set by terraform/envs/obs-grafana/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/obs-grafana-pg-node"
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
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "pg_version" {
  type        = number
  default     = 17
  description = "PostgreSQL major version (PGDG). 17 for the Grafana state store (matches the oltp Patroni + iceberg-pg + registry-pg PG major)."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the grafana-pg spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md (Grafana state-DB is light)."
}

variable "disk_gb" {
  type        = number
  default     = 60
  description = "OS + PG data disk in GB (Grafana state is small; single disk). Growable VMDK only consumes what it writes."
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
