/*
 * obs-prom-node -- Packer template variables (Phase 0.I.1, ADR-0038)
 *
 * Per-engine template: Prometheus + Alertmanager (Go binaries; no JVM).
 * Both Proms in the HA pair scrape every fleet target independently;
 * Grafana datasource dedups on the read side. Alertmanager runs as a
 * 2-node gossip mesh co-resident on the Prom pair.
 */

variable "vm_name" {
  type        = string
  default     = "obs-prom-node"
  description = "VM display name + output .vmx basename. Per-clone names (prom-1/2) set by terraform/envs/obs-prom/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/obs-prom-node"
  description = "Absolute directory for the built template."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
  description = "Debian 13.5.0 netinst ISO. Override via `-var iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso` for the local cache."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "prometheus_version" {
  type        = string
  default     = "2.55.1"
  description = "Prometheus server version. v2.55.x is the long-term-supported 2.x release."
}

variable "prometheus_download_url" {
  type        = string
  default     = "https://github.com/prometheus/prometheus/releases/download/v2.55.1/prometheus-2.55.1.linux-amd64.tar.gz"
  description = "Prometheus release tarball (linux-amd64). MUST match prometheus_version. Cache to H:/VMS/ISO/ for an offline rebuild."
}

variable "alertmanager_version" {
  type        = string
  default     = "0.28.0"
  description = "Alertmanager version. v0.28 is the current LTS line; gossip mesh on :9094."
}

variable "alertmanager_download_url" {
  type        = string
  default     = "https://github.com/prometheus/alertmanager/releases/download/v0.28.0/alertmanager-0.28.0.linux-amd64.tar.gz"
  description = "Alertmanager release tarball (linux-amd64). MUST match alertmanager_version."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the prom node spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "Build-time RAM (MB). Default 4 GB per memory/feedback_prefer_less_memory.md -- both Proms run independently with Alertmanager co-resident; 4 GB headroom for retention + queries at lab scale. Production grade reverts to 8-16 GB."
}

variable "disk_gb" {
  type        = number
  default     = 80
  description = "OS disk in GB. Prom local TSDB retention bounded by this disk (long-term storage = future Mimir on MinIO enhancement)."
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
