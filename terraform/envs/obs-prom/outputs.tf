output "prom_1_vmnet11_ip" {
  value       = var.prom_1_vmnet11_ip
  description = "prom-1 management/scrape-target IP (VMnet11)."
}

output "prom_2_vmnet11_ip" {
  value       = var.prom_2_vmnet11_ip
  description = "prom-2 management/scrape-target IP (VMnet11)."
}

output "prom_dns_name" {
  value       = var.prom_dns_name
  description = "Round-robin DNS name resolving to both Proms (ADR-0031; clients retry, no VIP for write paths)."
}

output "alertmanager_dns_name" {
  value       = var.alertmanager_dns_name
  description = "Round-robin DNS name resolving to both Alertmanagers (mesh dedupes cluster-wide)."
}
