# nexus-infra-observability / terraform / envs / obs-grafana / outputs.tf

output "grafana_endpoints" {
  description = "Grafana HA front-door endpoints (HTTPS :3000)."
  value = {
    vip       = "https://${var.grafana_dns_name}:3000"
    grafana_1 = "https://grafana-1.nexus.lab:3000"
    grafana_2 = "https://grafana-2.nexus.lab:3000"
  }
}

output "grafana_db_endpoints" {
  description = "Grafana state-DB endpoints (Postgres :5432)."
  value = {
    vip          = "${var.grafana_db_dns_name}:5432"
    grafana_pg_1 = "grafana-pg-1.nexus.lab:5432"
    grafana_pg_2 = "grafana-pg-2.nexus.lab:5432"
  }
}

output "grafana_vips" {
  description = "VRRP-floated VIPs provisioned by this env."
  value = {
    grafana    = var.grafana_vip
    grafana_db = var.grafana_db_vip
  }
}
