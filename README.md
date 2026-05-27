# nexus-infra-observability

NexusPlatform **observability tier** (foundation-tier extension `01-foundation`) —
Phase 0.I. The **Grafana LGTM stack** with full HA across the LB tier per
ADR-0025: Prometheus HA pair (each scrapes every fleet target; Grafana datasource
dedupes) + Alertmanager mesh + Loki simple-scalable on MinIO + Tempo scalable on
MinIO + Grafana HA pair behind a VRRP VIP + dedicated Grafana Postgres HA pair
behind a second VRRP VIP + OTel Collector pair. Part of the
[NexusPlatform](https://github.com/grezap) portfolio; built on the per-cluster
Terraform state + per-engine Packer template canon
([nexus-platform-plan ADR-0038](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0038-observability-tier-grafana-stack-ha.md)).

> Status (2026-05-28): **Phase 0.I CLOSE-OUT COMPLETE -- `v0.1.0` tagged.**
> All 7 sub-phases SEALED + live-ratified + cold-rebuild-proven. Prom HA +
> Alertmanager mesh (0.I.1), Loki SSD on MinIO (0.I.2), Tempo scalable on
> MinIO (0.I.3), Grafana HA + Grafana PG HA + 2 VRRP VIPs `.184`+`.185`
> (0.I.4), OTel Collector pair behind RR DNS `otel.nexus.lab` (0.I.5),
> Vector log shipper fleet-wide via `nexus_observability` shared role +
> `fleet-vector-rollout.ps1` (0.I.6), close-out canon sweep + tag (0.I.7).
> 14 obs VMs + 2 VRRP VIPs. **39 apply-time transients permanently fixed
> in source** (handbook §3.A T1-T8 / §3.B T9-T14 / §3.C T15-T19 / §3.D T20-T29 /
> §3.E T30-T33 / §3.F T34-T37). Smoke gates: 33/33 + ~25/25 + ~24/24 + ALL
> GREEN + ALL GREEN + ALL GREEN respectively.
> Supersedes the original singleton `obs-{metrics,tracing,logging}` reservation
> in `nexus-platform-plan/docs/infra/vms.yaml` (ADR-0038 §Context).

## Topology (ADR-0038)

**14 VMs + 2 VRRP VIPs** in the `192.168.70.170–.185` VMnet11 range + the
`192.168.10.170–.183` VMnet10 backplane (`10.90.x` is the canonical obs/platform
decade per `vms.yaml` line 46).

| Cluster | Nodes | VMnet11 | VMnet10 backplane | RAM | Role |
|---|---|---|---|---|---|
| **Prom HA + Alertmanager** (0.I.1) | prom-1 / prom-2 | .170 / .171 | 10.90.170 / .171 | 4 GB ea | Both Proms scrape every target; Alertmanager mesh co-resident |
| **Loki simple-scalable** (0.I.2) | loki-1 / loki-2 / loki-3 | .172–.174 | 10.90.172–.174 | 4 GB ea | All-components per node; MinIO bucket `loki` via `nexus-loki-app` tenant |
| **Tempo scalable** (0.I.3) | tempo-1 / tempo-2 / tempo-3 | .175–.177 | 10.90.175–.177 | 4 GB ea | All-components per node; MinIO bucket `tempo` via `nexus-tempo-app` tenant; OTLP :4317/:4318 |
| **Grafana HA** (0.I.4) | grafana-1 / grafana-2 | .178 / .179 | 10.90.178 / .179 | 3 GB ea | Active-active over shared PG; **VRRP VIP `grafana.nexus.lab .184`** |
| **Grafana PG HA** (0.I.4) | grafana-pg-1 / grafana-pg-2 | .180 / .181 | 10.90.180 / .181 | 2 GB ea | PG 17 streaming repl; **VRRP VIP `grafana-db.nexus.lab .185`** |
| **OTel Collector** (0.I.5) | otel-collector-1 / otel-collector-2 | .182 / .183 | 10.90.182 / .183 | 2 GB ea | OTLP receivers; round-robin DNS `otel.nexus.lab` |

### HA promise covers the LB tier (ADR-0025)

- **Grafana single URL** (`https://grafana.nexus.lab/`) is **NOT a SPOF.** Both
  Grafana nodes are active-active over shared PG state; keepalived floats the
  VRRP VIP `.184` to the current MASTER; cert IP-SAN on both nodes includes the
  VIP so `verify-full` validates regardless of which holds it. Same proven shape
  as 0.G.3 proxysql, 0.G.4 haproxy-pg, 0.L.2 iceberg-db, 0.L.4 registry-db.
- **Machine write endpoints** (Prom remote-write, Loki push, Tempo OTLP ingest,
  OTel Collector intake) use **round-robin DNS per ADR-0031** — clients retry on
  connection failure; no VIP needed because there is no fixed-endpoint SPOF in
  the write path.
- **Prometheus HA** = both Proms scrape every target independently; Grafana's
  Prometheus datasource dedupes on the read side. Either Prom can be lost
  without metric loss.
- **Loki + Tempo** use memberlist gossip rings × 3 nodes each — tolerates a
  single-node loss without write/read interruption.

### Shipper model — hybrid

- **Metrics pull (Prom scrape):** `prometheus-node-exporter` on every Linux VM
  (port `:9100`, already baked into the `nexus_observability` shared role at
  Phase 0.B.3) + `windows_exporter` on each ws2025 desktop (`:9182`, retro-added
  at 0.I.6) + engine-specific exporters where canonical (kafka-exporter,
  postgres-exporter, redis-exporter, mongodb-exporter, mysqld-exporter, etc.).
- **Logs push (Vector):** `vector` baked into the deb13 baseline + every
  per-engine template at 0.I.6; default config tails journald + `/var/log/*` +
  engine logs; pushes to `https://loki.nexus.lab:3100/loki/api/v1/push`.
- **Traces push (app SDKs):** apps emit OTLP/gRPC to `https://otel.nexus.lab:4317`
  (or HTTP `:4318`); collector pair fans out to Tempo/Prom/Loki.

### MinIO tenants (provisioned in `nexus-infra-lakehouse`)

The Loki and Tempo durable backends are MinIO S3 buckets with dedicated service
accounts, mirroring the 0.L.5 SR-shared-data pattern. Provisioned via a new
overlay in `nexus-infra-lakehouse/terraform/envs/lakehouse-minio`:

- `bucket=loki` + `nexus-loki-app` service account + scoped `loki-tenant` policy
- `bucket=tempo` + `nexus-tempo-app` service account + scoped `tempo-tenant` policy

Cross-bucket-deny proven in each sub-phase's smoke gate.

## Cross-tier prerequisites (run in `nexus-infra-vmware` FIRST)

1. **foundation** env apply — dhcp-host reservations for the 14 obs MACs
   (`:B2`–`:BF` → `.170`–`.183`) + round-robin DNS entries
   (`prometheus.nexus.lab` → `.170`/`.171`, `loki.nexus.lab` → `.172`–`.174`,
   `tempo.nexus.lab` → `.175`–`.177`, `otel.nexus.lab` → `.182`/`.183`) +
   VRRP VIP reservations (`grafana.nexus.lab` → `.184`, `grafana-db.nexus.lab`
   → `.185`).
2. **security** env apply — `observability-server` PKI role + 14 per-host AppRole
   sidecars at `$HOME/.nexus/vault-agent-observability-<svc>-<n>.json` + KV
   sticky-seeds at `nexus/observability/{grafana,grafana-pg,loki,tempo,prometheus,otel-collector}/*`.
3. **lakehouse-minio** env apply (in `nexus-infra-lakehouse`) — adds the
   `nexus-loki-app` + `nexus-tempo-app` MinIO tenants + `loki` and `tempo`
   buckets.

The 6 foundation VMs (`nexus-gateway`, `dc-nexus`, `vault-1/2/3`,
`vault-transit`) **and the 4 MinIO VMs (0.L.1)** must be running.

## Quick start

```powershell
# 1. cross-tier prereqs (in nexus-infra-vmware + nexus-infra-lakehouse)
pwsh -File scripts\foundation.ps1       apply         # nexus-infra-vmware
pwsh -File scripts\security.ps1         apply         # nexus-infra-vmware
pwsh -File scripts\lakehouse-minio.ps1  apply -Vars "enable_obs_tenants=true"  # nexus-infra-lakehouse

# 2. build per-engine templates (sub-phase by sub-phase)
cd packer\obs-prom-node;            packer init .; packer build .   # 0.I.1
cd ..\obs-loki-node;                packer init .; packer build .   # 0.I.2
cd ..\obs-tempo-node;               packer init .; packer build .   # 0.I.3
cd ..\obs-grafana-node;             packer init .; packer build .   # 0.I.4
cd ..\obs-grafana-pg-node;          packer init .; packer build .   # 0.I.4
cd ..\obs-otel-collector-node;      packer init .; packer build .   # 0.I.5

# 3. apply sub-phase by sub-phase; each one ratifies + cold-rebuild-proves before next
pwsh -File scripts\observability.ps1 prom        apply ; pwsh -File scripts\smoke-0.I.1.ps1
pwsh -File scripts\observability.ps1 loki        apply ; pwsh -File scripts\smoke-0.I.2.ps1
pwsh -File scripts\observability.ps1 tempo       apply ; pwsh -File scripts\smoke-0.I.3.ps1
pwsh -File scripts\observability.ps1 grafana     apply ; pwsh -File scripts\smoke-0.I.4.ps1
pwsh -File scripts\observability.ps1 otel        apply ; pwsh -File scripts\smoke-0.I.5.ps1
# 0.I.6 fleet rollout = retrofit Vector + windows_exporter into other tier templates (cross-repo)
# 0.I.7 close-out = canon sweep + tag v0.1.0
```

Selective ops: every node + overlay has an `enable_*` toggle (see
`docs/handbook.md` §1.5). Sub-phases can be applied independently and
re-applied idempotently.

## Repo layout

```
packer/_shared/ansible/roles/      shared roles (incl. observability_firstboot)
packer/obs-prom-node/              Prom + Alertmanager per-engine template (Phase 0.I.1)
packer/obs-loki-node/              Loki simple-scalable per-engine template (Phase 0.I.2)
packer/obs-tempo-node/             Tempo scalable per-engine template (Phase 0.I.3)
packer/obs-grafana-node/           Grafana HA per-engine template (Phase 0.I.4)
packer/obs-grafana-pg-node/        Grafana Postgres HA per-engine template (Phase 0.I.4)
packer/obs-otel-collector-node/    OTel Collector per-engine template (Phase 0.I.5)
terraform/modules/vm/              reusable vmrun clone driver (mirrors lakehouse)
terraform/envs/obs-prom/           Phase 0.I.1 per-cluster env (2 Prom + Alertmanager VMs)
terraform/envs/obs-loki/           Phase 0.I.2 per-cluster env (3 Loki SSD VMs)
terraform/envs/obs-tempo/          Phase 0.I.3 per-cluster env (3 Tempo scalable VMs)
terraform/envs/obs-grafana/        Phase 0.I.4 per-cluster env (Grafana 2 + Grafana PG 2 + 2 VIPs)
terraform/envs/obs-otel/           Phase 0.I.5 per-cluster env (2 OTel Collector VMs)
scripts/observability.ps1          operator wrapper (verbs: prom · loki · tempo · grafana · otel · all)
scripts/smoke-0.I.{1..7}.ps1       per-sub-phase smoke gates
docs/handbook.md                   from-zero rebuild guide (§0-§3.1) + operator runbooks (§3.x)
docs/adr/                          project-local ADRs (most ADRs live in nexus-platform-plan)
```

## ADRs

Phase 0.I's primary ADR lives in `nexus-platform-plan`:

- [ADR-0038 — Observability tier topology: Grafana LGTM stack on MinIO, 14 VMs HA, Grafana VRRP-VIP front door, hybrid shipper](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0038-observability-tier-grafana-stack-ha.md)
- [ADR-0025 — HA promise covers the LB tier](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0025-ha-promise-covers-lb-tier.md) (gate)
- [ADR-0031 — Analytics client front door: round-robin DNS, no VRRP VIP](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0031-analytics-client-front-door-round-robin-dns.md) (for write paths)
- [ADR-0033 — MinIO distributed erasure-coded object storage](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0033-minio-distributed-erasure-coded-object-storage.md) (the S3 backend)

Project-local ADRs (smaller scope) live under `docs/adr/` here.

## Contact

Operator: Greg Zapantis ([@grezap](https://github.com/grezap)).
