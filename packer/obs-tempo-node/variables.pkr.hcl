/*
 * obs-tempo-node -- Packer template variables (Phase 0.I.3, ADR-0038)
 *
 * Per-engine template: Tempo 3.x single-binary simple-scalable mode. Each
 * node runs ALL components (read + write + backend); memberlist gossip ring
 * coordinates; MinIO S3 backend holds durable index + chunks.
 */

variable "vm_name" {
  type        = string
  default     = "obs-tempo-node"
  description = "VM display name + output .vmx basename. Per-clone names (tempo-1/2/3) set by terraform/envs/obs-tempo/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/obs-tempo-node"
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

variable "tempo_version" {
  type        = string
  default     = "2.7.2"
  description = "Grafana Tempo version (2.7.x current; supports memberlist + S3 backend + OTLP receivers + Parquet v3 blocks)."
}

variable "tempo_download_url" {
  type        = string
  default     = "https://github.com/grafana/tempo/releases/download/v2.7.2/tempo_2.7.2_linux_amd64.tar.gz"
  description = "Tempo release tarball. MUST match tempo_version."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "Build-time RAM. Default 4 GB per memory/feedback_prefer_less_memory.md (Tempo simple-scalable at lab scale)."
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
