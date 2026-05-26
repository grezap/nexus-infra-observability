/*
 * obs-loki-node -- Packer template variables (Phase 0.I.2, ADR-0038)
 *
 * Per-engine template: Loki 3.x single-binary simple-scalable mode. Each
 * node runs ALL components (read + write + backend); memberlist gossip ring
 * coordinates; MinIO S3 backend holds durable index + chunks.
 */

variable "vm_name" {
  type        = string
  default     = "obs-loki-node"
  description = "VM display name + output .vmx basename. Per-clone names (loki-1/2/3) set by terraform/envs/obs-loki/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/obs-loki-node"
  description = "Absolute directory for the built template."
}

variable "iso_url" {
  type    = string
  default = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
}

variable "loki_version" {
  type        = string
  default     = "3.5.1"
  description = "Grafana Loki version (3.5.x; supports memberlist + S3 backend; TSDB v13 schema)."
}

variable "loki_download_url" {
  type        = string
  default     = "https://github.com/grafana/loki/releases/download/v3.5.1/loki-linux-amd64.zip"
  description = "Loki release zip. MUST match loki_version. Cache to H:/VMS/ISO/ for an offline rebuild."
}

variable "logcli_download_url" {
  type        = string
  default     = "https://github.com/grafana/loki/releases/download/v3.5.1/logcli-linux-amd64.zip"
  description = "logcli (Loki CLI) for smoke probes + operator runbooks."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "Build-time RAM. Default 4 GB per memory/feedback_prefer_less_memory.md (Loki simple-scalable at lab scale)."
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
