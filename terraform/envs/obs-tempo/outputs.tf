output "tempo_1_vmnet11_ip" { value = "192.168.70.175" }
output "tempo_2_vmnet11_ip" { value = "192.168.70.176" }
output "tempo_3_vmnet11_ip" { value = "192.168.70.177" }
output "tempo_dns_name" {
  value       = var.tempo_dns_name
  description = "Round-robin DNS resolving to all 3 Tempo nodes (ADR-0031 for write paths)."
}
