# nexus-infra-observability — operator handbook

The from-absolute-zero rebuild guide for the observability tier (foundation
extension `01-foundation`), Phase 0.I. Canon, not informal. An operator (or
future-Greg after a break) can rebuild this tier with no external knowledge
from this document.

> Coverage: **Phase 0.I scaffolded 2026-05-26 (ADR-0038).** Sub-phases 0.I.1–
> 0.I.7 unlock §1.x walkthroughs as they land. The bootstrap §0 prerequisites
> apply to every sub-phase.

---

## §0 Prerequisites

**Build host:** Windows 11 + VMware Workstation Pro 17.5+ (`10.0.70.101`),
pwsh, Packer ≥ 1.11, Terraform ≥ 1.9, `ssh`/`scp` on PATH, the
`nexus_gateway_ed25519` key configured for bare `ssh nexusadmin@<ip>` (see
`nexus-infra-vmware` handbook §0.4).

**Other tiers that MUST already be alive** (the always-on 6-VM foundation):

| VM | IP | Verify |
|---|---|---|
| `nexus-gateway` | `192.168.70.1` | `ssh nexusadmin@192.168.70.1 'echo ok'` — dnsmasq (DHCP/DNS), nftables egress |
| `dc-nexus` | `192.168.70.10` | AD/DNS for `nexus.lab` |
| `vault-1/2/3` | `.121`–`.123` | `vault status` leader elected; PKI `pki_int/` live |
| `vault-transit` | `.124` | auto-unseal custodian |

**The 4 MinIO VMs (0.L.1) MUST also be running** before sub-phases 0.I.2 (Loki)
and 0.I.3 (Tempo) — both use MinIO as durable object storage.

```powershell
# Power on the lakehouse minio cluster if it's stopped
H:\VMS\NexusPlatform\08-spark\minio-1\minio-1.vmx; vmrun start <vmx> nogui
# (repeat for minio-2/3/4)
# verify
ssh nexusadmin@192.168.70.141 'curl -fk https://localhost:9000/minio/health/live'
```

**Cross-repo state this tier reads (provisioned by `nexus-infra-vmware`):**

- **foundation env** — dhcp-host reservations for the 14 obs MACs
  (`:B2`–`:BF` → `.170`–`.183`) + round-robin DNS:
  - `prometheus.nexus.lab` → `.170`/`.171`
  - `loki.nexus.lab` → `.172`–`.174`
  - `tempo.nexus.lab` → `.175`–`.177`
  - `otel.nexus.lab` → `.182`/`.183`
  + VRRP VIP A-records:
  - `grafana.nexus.lab` → `.184` (no MAC; keepalived floats)
  - `grafana-db.nexus.lab` → `.185` (no MAC; keepalived floats)
  Provisioned by `role-overlay-gateway-observability-{reservations,dns}.tf`.

- **security env** — `observability-server` PKI role + 14 per-host AppRole
  sidecars at `$HOME/.nexus/vault-agent-observability-<service>-<n>.json` + KV
  sticky-seeds at `nexus/observability/{grafana,grafana-pg,loki,tempo,
  prometheus,otel-collector}/*` (passwords field `password`, S3 keys field
  `value`). Provisioned by `role-overlay-vault-pki-observability.tf`,
  `role-overlay-vault-agent-observability-{policies,approles}.tf`,
  `role-overlay-vault-observability-creds-seed.tf`.

**Cross-repo state this tier reads (provisioned by `nexus-infra-lakehouse`):**

- **lakehouse-minio env** — `nexus-loki-app` + `nexus-tempo-app` MinIO service
  accounts + scoped `loki-tenant` + `tempo-tenant` policies + buckets `loki` +
  `tempo`. Provisioned by `role-overlay-minio-observability-tenants.tf`. The
  access/secret keys are mirrored into Vault KV at
  `nexus/observability/loki/s3-{access,secret}-key` and
  `nexus/observability/tempo/s3-{access,secret}-key`.

**Build-host cache:** `H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso` (sha256
`95838884…`). Prom/Grafana/Loki/Tempo/Vector binaries pull from upstream
during bake (NAT egress via nexus-gateway).

---

## §1 Phase walkthrough

### §1.1 Build the templates (sub-phase by sub-phase)

```powershell
# 0.I.1 Prometheus HA + Alertmanager
cd packer\obs-prom-node
packer init .
packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# → H:/VMS/NexusPlatform/_templates/obs-prom-node/obs-prom-node.vmx
# bake ~6-8 min. Debian 13 + Prometheus 2.55 + Alertmanager 0.27 +
# alertmanager mesh config; nexus-{prometheus,alertmanager}.service delivered DISABLED.
```

(Sub-phases 0.I.2–0.I.5 templates ship as those sub-phases land.)

### §1.2 Cross-env operator order (run FIRST)

Hard ordering — the cluster apply reads the AppRole sidecars + relies on the
gateway reservations/DNS + Vault PKI/KV + MinIO tenants:

```powershell
# in nexus-infra-vmware
pwsh -File scripts\foundation.ps1 apply   # lands obs reservations + DNS + VIP A-records
pwsh -File scripts\security.ps1   apply   # lands observability-server PKI + 14 AppRole sidecars + KV creds

# in nexus-infra-lakehouse (required for 0.I.2 / 0.I.3 only)
pwsh -File scripts\lakehouse-minio.ps1 apply -Vars "enable_obs_tenants=true"  # nexus-loki-app + nexus-tempo-app + buckets
```

All three are idempotent: re-applying creates only the new obs-tier
`null_resource`s; other tiers' overlays are unchanged no-ops.

### §1.3 Apply Phase 0.I.1 (Prom HA + Alertmanager)

(Sub-phase walkthrough lands when 0.I.1 is sealed.)

---

## §2 Phase status (per sub-phase)

| Sub | What | Status | Smoke |
|---|---|---|---|
| 0.I.1 | Prom HA + Alertmanager | scaffolded 2026-05-26 | — |
| 0.I.2 | Loki SSD on MinIO | pending | — |
| 0.I.3 | Tempo scalable on MinIO | pending | — |
| 0.I.4 | Grafana HA + Grafana PG HA + 2 VIPs | pending | — |
| 0.I.5 | OTel Collector pair | pending | — |
| 0.I.6 | Fleet-wide shipper rollout | pending | — |
| 0.I.7 | Close-out (canon + tag v0.1.0) | pending | — |

---

## §3 Operator runbooks + transient chronology

(Populated as sub-phases ratify. The chronology codifies every apply-time
transient root-caused + permanently fixed in source, mirroring the existing
nexus-infra-{kafka,oltp,analytics,lakehouse,registry} handbook §3 patterns.)

### §3.1 Cold-rebuild canon

The canonical cold-rebuild sequence for the obs tier:

```powershell
# 1. Wipe stale KV obs tokens (per feedback_cold_rebuild_stale_kv_tokens)
vault kv list nexus/observability | ForEach-Object { vault kv delete "nexus/observability/$_" }

# 2. Destroy the obs tier (per-sub-phase, in reverse order)
pwsh -File scripts\observability.ps1 otel    destroy
pwsh -File scripts\observability.ps1 grafana destroy
pwsh -File scripts\observability.ps1 tempo   destroy
pwsh -File scripts\observability.ps1 loki    destroy
pwsh -File scripts\observability.ps1 prom    destroy

# 3. Re-bake every per-engine template (idempotent; ~6-8 min each)
foreach ($t in 'obs-prom-node','obs-loki-node','obs-tempo-node','obs-grafana-node','obs-grafana-pg-node','obs-otel-collector-node') {
    Push-Location "packer\$t"
    packer init .
    packer build -force -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
    Pop-Location
}

# 4. Re-apply each sub-phase in order, smoke-gating between
pwsh -File scripts\observability.ps1 all apply
```

Expected outcome: all 7 sub-phase smoke gates GREEN with no operator hot-state.

(Per-sub-phase runbooks land in §3.x as they seal.)
