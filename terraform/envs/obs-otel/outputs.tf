# nexus-infra-observability / terraform / envs / obs-otel / outputs.tf

output "otel_endpoints" {
  description = "OTel Collector OTLP endpoints (gRPC :4317 + HTTP :4318); round-robin DNS."
  value = {
    otlp_grpc        = "${var.otel_dns_name}:4317"
    otlp_http        = "https://${var.otel_dns_name}:4318"
    otel_collector_1 = "otel-collector-1.nexus.lab"
    otel_collector_2 = "otel-collector-2.nexus.lab"
  }
}
