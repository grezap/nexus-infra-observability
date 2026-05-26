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
