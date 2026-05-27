# Changelog

All notable changes to `nexus-infra-observability` are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
versions per NexusPlatform sub-phase tags.

## [Unreleased] — Phase 0.I (observability tier)

> **Phase 0.I scaffolded 2026-05-26 (ADR-0038).** Sub-phases 0.I.1–0.I.7 in
> flight. Supersedes the original singleton `obs-{metrics,tracing,logging}`
> reservation in `nexus-platform-plan/docs/infra/vms.yaml`.

### Added — repo bootstrap (2026-05-26)

- New repo / tier: foundation-tier extension `01-foundation`. 14 VMs + 2 VRRP
  VIPs spanning the **Grafana LGTM stack** (Prometheus + Grafana + Loki + Tempo
  + Alertmanager + OTel Collector). MinIO S3 (the 0.L.1 lakehouse object store)
  is the durable backend for Loki + Tempo via dedicated `nexus-loki-app` and
  `nexus-tempo-app` service accounts.
- Repo skeleton: README, LICENSE (MIT), .gitignore, ansible.cfg,
  `.github/workflows/packer-validate.yml` (per-engine Packer + per-cluster TF
  matrices + ansible-lint + ShellCheck + PSScriptAnalyzer + gitleaks),
  `scripts/observability.ps1` operator wrapper stub, `docs/handbook.md` stub.
- Per-engine Packer template scaffold + per-cluster Terraform env scaffold for
  each of 0.I.1 (Prom HA) · 0.I.2 (Loki SSD) · 0.I.3 (Tempo scalable) ·
  0.I.4 (Grafana HA + Grafana PG HA + 2 VRRP VIPs) · 0.I.5 (OTel Collector
  pair).

### Sealed — 0.I.1 + 0.I.2 + 0.I.3 (2026-05-27)

- **0.I.1 Prometheus HA + Alertmanager mesh** — live-ratified +
  cold-rebuild-proven (`smoke-0.I.1` 33/33 GREEN; 8 transients fixed in
  source, handbook §3.A T1-T8).
- **0.I.2 Loki simple-scalable on MinIO** — live-ratified +
  cold-rebuild-proven (`smoke-0.I.2` ~25/25 GREEN; 6 transients fixed,
  handbook §3.B T9-T14; obs-tenants overlay in `nexus-infra-lakehouse`
  provisions `nexus-loki-app` + bucket `loki`).
- **0.I.3 Tempo scalable on MinIO** — live-ratified +
  cold-rebuild-proven (`smoke-0.I.3` ~24/24 GREEN; 5 transients fixed,
  handbook §3.C T15-T19; needs `-target=scalable-single-binary` flag +
  `instance_interface_names=["nic1"]`).

### Sealed — 0.I.5 (2026-05-27)

- **0.I.5 OTel Collector pair SEALED** -- 2 nodes (otel-collector-1/2 at
  .182/.183) active-active fronted by round-robin DNS `otel.nexus.lab` (no VIP
  per ADR-0031). OTLP gRPC :4317 + HTTP :4318 receivers; routes traces ->
  `tempo.nexus.lab:4317`, metrics -> `prometheus.nexus.lab:9090/api/v1/write`
  (basic auth from KV), logs -> `loki.nexus.lab:3100/otlp` (Loki 3.x native
  OTLP receiver). mTLS via observability-server PKI. 4 transients permanently
  fixed in source (handbook §3.E T30-T33: otelcol->otel rename / overlay
  hardcoded-user / PowerShell scope-qualifier / Terraform `$$` heredoc escape).
  Live-ratified + cold-rebuild-proven; `smoke-0.I.5` ALL CHECKS GREEN both
  passes. Fleet 107 VMs + 5 VIPs cold-rebuild-proven.

### Sealed — 0.I.4 (2026-05-27)

- **0.I.4 Grafana HA + Grafana PG HA + 2 VRRP VIPs SEALED** -- live-ratified
  + cold-rebuild-proven (`smoke-0.I.4` ALL CHECKS GREEN default mode; PG VIP
  failover opt-in via `-Strict`); 10 apply-time transients permanently fixed
  in source (handbook §3.D T20-T29). 12 obs VMs + 2 VIPs through 0.I.4. Cold
  rebuild: `terraform destroy` -> `terraform apply` (from-zero) -> smoke ALL
  GREEN (vmrun "Unknown error" transient documented as 1-line retry).
  - `packer/obs-grafana-pg-node/` (PG17 + keepalived) -- comments cleaned
    from sed-rename artifacts; `packer init` + `packer validate` GREEN.
  - `packer/obs-grafana-node/` (Grafana OSS 11.6.3 + keepalived) -- new
    per-engine template; `packer init` + `packer validate` GREEN.
  - `terraform/envs/obs-grafana/` -- new per-cluster TF env with 7
    overlays: nftables (per-role rulesets) + vault-agents (×4) + tls
    (×4 with VIP IP-SAN per role) + pg-replication (PG17 + keepalived
    VIP `.185`) + grafana-config (grafana.ini + datasource provisioning
    for Prom/Loki/Tempo + keepalived VIP `.184`) + bootstrap (exit
    gate). `terraform init` + `terraform validate` + `terraform fmt`
    GREEN.
  - `scripts/smoke-0.I.4.ps1` -- ~50 checks across 14 sections; includes
    ADR-0025 VIP failover sequence on BOTH `.184` + `.185`.
  - Security env (`nexus-infra-vmware`) `obs-creds-seed` bumped to v3:
    seeds 5 new sticky-hex KV passwords at
    `nexus/observability/{grafana,grafana-pg}/*` (admin / session-key /
    grafana-db / superuser / replication).
  - Live-ratify + cold-rebuild proof in progress.
