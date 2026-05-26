output "loki_1_vmnet11_ip" { value = "192.168.70.172" }
output "loki_2_vmnet11_ip" { value = "192.168.70.173" }
output "loki_3_vmnet11_ip" { value = "192.168.70.174" }
output "loki_dns_name" {
  value       = var.loki_dns_name
  description = "Round-robin DNS resolving to all 3 Loki nodes (ADR-0031 for write paths)."
}
