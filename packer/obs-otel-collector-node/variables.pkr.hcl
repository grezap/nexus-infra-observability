/*
 * obs-otel-collector-node -- Packer template variables (Phase 0.I.5, ADR-0038)
 *
 * Per-engine template: OTel Collector Contrib (upstream Go binary tarball).
 * Two-node active-active pair fronted by round-robin DNS otel.nexus.lab.
 */

variable "vm_name" {
  type        = string
  default     = "obs-otel-collector-node"
  description = "VM display name + output .vmx basename. Per-clone names (otel-collector-1/2) set by terraform/envs/obs-otel/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/obs-otel-collector-node"
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

variable "otel_version" {
  type        = string
  default     = "0.117.0"
  description = "OpenTelemetry Collector Contrib version. Pinned for reproducible bakes."
}

variable "otel_download_url" {
  type        = string
  default     = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.117.0/otelcol-contrib_0.117.0_linux_amd64.tar.gz"
  description = "OTel Collector Contrib release tarball. MUST match otel_version."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (2 GB). Collector is lightweight; memory_limiter processor caps actual heap."
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
