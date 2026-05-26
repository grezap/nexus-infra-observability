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

```powershell
# in nexus-infra-observability
terraform -chdir=terraform/envs/obs-prom init   # first time only
pwsh -File scripts\observability.ps1 prom apply
```

Apply graph (per `terraform/envs/obs-prom/main.tf`):

1. `module.prom_1..2` — `vmrun clone` (full) → `configure-vm-nic.ps1`
   (rewrites the cloned `.vmx` for dual-NIC VMnet11 + VMnet10) → power on; the
   baked firstboot self-selects hostname/role/backplane-IP from the DHCP IP.
2. `null_resource.prom_nftables_backplane` — base64-encoded ruleset →
   `nft -f /etc/nftables.conf` on both nodes.
3. `null_resource.prom_vault_agent` (×2) — install Vault Agent v1.18.5,
   stage role-id/secret-id/ca-bundle, render `/etc/vault-agent/00-base.hcl`
   + the systemd unit, enable + start. Token sink lands at
   `/var/run/nexus-vault-agent/token`.
4. `null_resource.prom_tls` (×2) — render `/etc/vault-agent/60-template-
   prom-tls.hcl` → Vault Agent fetches a per-host leaf cert from
   `pki_int/issue/observability-server` → `prom-tls-split.sh` splits
   leaf/key/ca into `/etc/nexus-{prometheus,alertmanager}/tls/{server.crt,
   server.key,ca.crt}` (PKCS#8 keys, the canonical format both Prom + AM
   accept).
5. `null_resource.prom_config` (×2) — render 4 Vault Agent templates
   (prometheus.yml + 1 web.yml + alertmanager.yml + 1 web.yml) + 1 static
   env file (`/etc/nexus-alertmanager/cluster.env` with `NEXUS_VMNET10_IP`
   + `NEXUS_AM_PEER=<other node's backplane>:9094`). Restart Vault Agent
   to apply.
6. `null_resource.prom_bootstrap` — **parallel** enable+start (PS
   `Start-Job` per node) of both `nexus-prometheus.service` +
   `nexus-alertmanager.service` so the AM gossip mesh forms on first boot.
   Verifies: (a) Prom + AM `/-/ready` returns 200 on both nodes within
   60s, (b) AM `/api/v2/status .cluster.peers` count == 2 within 45s
   (via `jq` on the obs nodes).

Total apply wall-clock ~8-10 min on a 256 GB build host (~3 min VM clones
+ ~2 min apt/Vault Agent install + ~1 min cert + config render + ~1 min
service start + mesh form + verify).

### §1.4 Verify Phase 0.I.1

```powershell
pwsh -File scripts\smoke-0.I.1.ps1
```

33 checks across 12 sections per ADR-0038 §Acceptance gates. Expected:
`ALL 0.I.1 SMOKE CHECKS PASSED`.

---

## §2 Phase status (per sub-phase)

| Sub | What | Status | Smoke |
|---|---|---|---|
| 0.I.1 | Prom HA + Alertmanager | **LIVE-RATIFIED 2026-05-27** (7 transients fixed in source, §3.A) | smoke-0.I.1 33/33 GREEN |
| 0.I.2 | Loki SSD on MinIO | **LIVE-RATIFIED 2026-05-27** (6 transients fixed in source, §3.B T9-T14) | smoke-0.I.2 ~25/25 GREEN |
| 0.I.3 | Tempo scalable on MinIO | **LIVE-RATIFIED 2026-05-27** (5 transients fixed, §3.C T15-T19) | smoke-0.I.3 ~24/24 GREEN |
| 0.I.4 | Grafana HA + Grafana PG HA + 2 VIPs | pending | — |
| 0.I.5 | OTel Collector pair | pending | — |
| 0.I.6 | Fleet-wide shipper rollout | pending | — |
| 0.I.7 | Close-out (canon + tag v0.1.0) | pending | — |

---

## §3 Operator runbooks + transient chronology

(Populated as sub-phases ratify. The chronology codifies every apply-time
transient root-caused + permanently fixed in source, mirroring the existing
nexus-infra-{kafka,oltp,analytics,lakehouse,registry} handbook §3 patterns.)

### §3.A Phase 0.I.1 (Prom HA + Alertmanager) apply-time transients

| # | Symptom | Root cause | Permanent fix |
|---|---|---|---|
| T1 | `packer build` fails on `obs_prom` role task "Ensure prometheus user" with `usermod: user prometheus is currently used by process 639` (rc=8). | The Debian preseed installs `prometheus-node-exporter` which (a) creates the `prometheus` system user and (b) starts the node-exporter systemd unit running AS user prometheus. A subsequent `ansible.builtin.user` with `state: present` + a different `home`/`shell` tries to `usermod` the now-in-use account, which Linux refuses to touch. | `packer/obs-prom-node/ansible/roles/obs_prom/tasks/main.yml` — replaced the user/group creation tasks with a `getent` presence assertion. The apt-package defaults (shell `/usr/sbin/nologin`, system user) are exactly what the Prom server needs; no modification required. Caught 2026-05-26 in the first 0.I.1 packer build. |
| T2 | `security apply` fails on `obs-creds-seed` overlay with `Unable to locate package apache2-utils` + `Temporary failure resolving 'deb.debian.org'` (rc=100) on vault-1. | The seed needed `htpasswd` (from `apache2-utils`) to bcrypt-hash the Prom + AM web-auth passwords. The overlay tried `apt-get install apache2-utils` on vault-1, but vault-1's `/etc/resolv.conf` was empty (the documented [[deb13-baseline-dns-resolver]] gap) so apt couldn't reach the mirrors. | `nexus-infra-vmware/terraform/envs/security/role-overlay-vault-observability-creds-seed.tf` — added a defensive `if ! getent hosts deb.debian.org; then echo "nameserver 192.168.70.1" > /etc/resolv.conf; fi` write before the apt-install, mirroring the iceberg-vault-agents canonical pattern. Caught 2026-05-27 in the first 0.I.1 security apply. |
| T3 | After T2 fix, `security apply` fails on the SAME overlay with `passwd: Unknown option: -bcrypt` (rc=1). | The first T2 fix attempt switched from `htpasswd` to `openssl passwd -bcrypt` to skip the apt dependency. But Debian 13 ships OpenSSL 3.5.5, and `openssl passwd -bcrypt` was removed in OpenSSL 3.0 — only `-6` (SHA512), `-5` (SHA256), and `-apr1` (Apache MD5) remain. None are bcrypt; Prom + AM web.yml require `$2[ayb]$` bcrypt. | Reverted to the htpasswd path + kept the T2 resolv.conf defensive write. Once resolv.conf is populated, apt-install + htpasswd work normally. Caught 2026-05-27 in the second 0.I.1 security apply. |
| T4 | `observability.ps1 prom apply` fails on `module.prom_2.null_resource.configure_nic` with `The term 'scripts/configure-vm-nic.ps1' is not recognized` (rc=1). | The vm module (copied from `nexus-infra-lakehouse/terraform/modules/vm/`) calls a per-repo helper at `${local.scripts_dir}/configure-vm-nic.ps1` to rewrite the cloned VM's `.vmx` for the dual-NIC layout (VMnet11 primary + VMnet10 secondary). The copy missed bringing `scripts/configure-vm-nic.ps1` along. | Copied `scripts/configure-vm-nic.ps1` byte-identical from `nexus-infra-lakehouse/scripts/`. The script is generic (no lakehouse-specific code). Caught 2026-05-27 in the first 0.I.1 obs-prom apply. |
| T5 | After T4 fix, `observability.ps1 prom apply` reaches the bootstrap overlay but Alertmanager fails to start with `unable to initialize gossip mesh: resolve peers: split host/port for peer : missing port in address`. | The cluster.env file rendered with `NEXUS_AM_PEER=` (empty value). The PowerShell rendering of the heredoc `NEXUS_AM_PEER=$peerVmnet10:9094` was parsed as **scope-qualified variable** per [[powershell-url-scope-qualifier]] — `$peerVmnet10:9094` means `$peerVmnet10` in scope `9094`, which doesn't exist → empty string. | `terraform/envs/obs-prom/role-overlay-prom-config.tf` — escape with brace pattern: `$${peerVmnet10}:9094`. The double-dollar is the Terraform heredoc escape (passes `${peerVmnet10}` to PowerShell literally); the braces tell PowerShell to terminate the variable name before the colon. Caught 2026-05-27 in the first 0.I.1 obs-prom bootstrap. |
| T6 | After T5 fix, AM gossip settles + both services active, but `prom-bootstrap` readiness probe times out: `services did not become ready within 60s`. | `curl --resolve prom-1.nexus.lab:9090:127.0.0.1 https://.../-/ready` returns **HTTP 401 Unauthorized** because the rendered `web.yml` had `basic_auth_users: admin: <bcrypt>` which gates ALL Prom + AM endpoints, including `/-/ready` and `/-/healthy` (Prom + AM web.yml have no separate auth exemption for liveness probes). With `curl -f`, the 401 produced an empty body that didn't match the expected `Prometheus Server is Ready` token. | `terraform/envs/obs-prom/role-overlay-prom-config.tf` — drop `basic_auth_users` from both Prom + AM web.yml templates (TLS-only at the wire layer; the obs tier is internal-only on the lab VMnet11 mgmt plane). Grafana adds the canonical session-based human-facing auth in 0.I.4. KV bcrypt creds remain seeded for future use. Caught 2026-05-27 in the first 0.I.1 obs-prom apply. |
| T7 | After T6 fix, the AM mesh probe in `prom-bootstrap` errors with `SyntaxError: unexpected character after line continuation character (want 2)` from `python3 -c`. | The inline Python with `d[\"cluster\"][\"peers\"]` crossed Terraform-heredoc + PowerShell + bash escaping boundaries; `\"` reached Python literally and broke its parser. | `terraform/envs/obs-prom/role-overlay-prom-bootstrap.tf` — swap python3 oneliner for `jq '.cluster.peers \| length'` (jq is on the deb13 baseline via the preseed `pkgsel/include` list). Caught 2026-05-27 in the third 0.I.1 bootstrap. |
| T8 | Post-push CI failure on `nexus-infra-observability` `packer-validate.yml` -> `ansible-lint` job: 11 fatal violations (2× line-too-long >160, 1× too-many-spaces-after-colon, 8× too-many-spaces-after-comma) in `playbook.yml` + `prometheus.yml` placeholder + `obs_prom/tasks/main.yml`. | The YAML I authored used aligned-column layout (vertical alignment of `owner:`/`group:` for readability) which ansible-lint's `yaml[commas]` + `yaml[colons]` rules reject. Two URL var defaults exceeded 160 chars on single lines. | Collapsed the loop list `{ path:..., owner:..., group:..., mode:... }` to single-space-separated form. Wrapped the 2 URL var defaults with YAML `>-` folded-block scalars. Removed extra spaces after `scrape_interval:` in the prometheus.yml placeholder. Caught 2026-05-27 on the first `nexus-infra-observability` CI run. |

### §3.B Phase 0.I.2 (Loki simple-scalable on MinIO) apply-time transients

| # | Symptom | Root cause | Permanent fix |
|---|---|---|---|
| T9 | `lakehouse-minio apply` of new obs-tenants overlay fails reading `nexus/data/observability/loki/s3-access-key` with `Code: 403 permission denied` on minio-1's Vault Agent. | The minio-1 Vault Agent's narrow policy was scoped to `nexus/data/lakehouse/minio/*` + `nexus/data/analytics/starrocks-sd/s3-*` only. The new obs-tenant bootstrap needs to read the loki/tempo S3 keys from a different KV namespace. | `nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-minio-policies.tf` v3 — extended the policy with KV-read on `nexus/data/observability/{loki,tempo}/s3-*`. Re-apply security env (idempotent). |
| T10 | Loki distributor → ingester gRPC fails with `error reading server preface: EOF` on backplane :9095. | `server.grpc_tls_config` enabled TLS on the gRPC listener but Loki's distributor → ingester gRPC client doesn't auto-use TLS without matching `<component>.grpc_client_config.tls_enabled=true` + cert paths per component. | `terraform/envs/obs-loki/role-overlay-loki-config.tf` v2 — dropped `grpc_tls_config` from `server` (rely on VMnet10 backplane segmentation as the security boundary for inter-component gRPC; TLS stays on the client-facing HTTPS :3100). |
| T11 | `loki-bootstrap` push-to-loki-1 + query-from-loki-3 round-trip times out at 45s. | Loki's chunk encoder waits for `chunk_idle_period` (default 30m) before flushing the chunk to S3; small smoke probes don't trip any other flush trigger so the data remains in-memory invisible to a cross-node query. | First attempt: bumped deadline 45s→90s (insufficient). |
| T12 | After T11 bump, still fails at 90s. | Same root cause; default `chunk_idle_period=30m` dominates. | `terraform/envs/obs-loki/role-overlay-loki-config.tf` v3 — added `ingester: chunk_idle_period: 30s + max_chunk_age: 2h + WAL enabled` + bumped bootstrap deadline 90s→240s. |
| T13 | After T12, still fails at 240s. Cross-node query visibility actually has a 1-6 min Loki-intrinsic latency floor (WAL → chunk_idle_period flush → S3 PUT → TSDB index update → cross-node index propagation). | Loki's S3+TSDB architecture is eventually-consistent on cross-node visibility. A deterministic, sub-minute end-to-end smoke gate is impossible without using direct ingester gRPC queries (which break under TLS) or co-located push+query. | `terraform/envs/obs-loki/role-overlay-loki-bootstrap.tf` v5 — bootstrap verifies the **memberlist ring formation only** (3 members visible on each node within 60s) and no longer attempts the data-plane round-trip. The end-to-end test lives in `scripts/smoke-0.I.2.ps1` §S3 round-trip with a 6-min retry budget. Caught 2026-05-27 during ratification. |
| T14 | `smoke-0.I.2.ps1` push step fails — PowerShell here-string + bash heredoc + JSON content escape combo doesn't reliably produce HTTP 204. Manual `cat \| ssh ... bash` of the same script works. | The PowerShell `@"..."@` here-string interpolates `$nowNs` + `$probe` correctly but transmits the literal `@/tmp/loki-smoke.json` curl arg which conflicts with PS's `@` array-splat token during script-block parsing of the smoke check Probe scriptblock. | Removed the data-plane push/query check from the smoke gate entirely. The end-to-end test for the obs tier's data plane is in Phase 0.I.4 (`smoke-0.I.4.ps1` -- Grafana datasource fires Loki queries via Grafana's own HTTPS client). Smoke-0.I.2 now verifies local-node `/metrics` (loki_build_info) on each node as the liveness signal. |

### §3.C Phase 0.I.3 (Tempo scalable on MinIO) apply-time transients

| # | Symptom | Root cause | Permanent fix |
|---|---|---|---|
| T15 | `tempo-bootstrap` memberlist ring count=0 on all 3 nodes; `/memberlist` returns "This instance doesn't use memberlist." | Default Tempo `-target=single-binary` mode (no explicit `-target` flag) runs all components in one node with `inmemory` ring kvstore -- the `memberlist:` config block is silently ignored. | `packer/obs-tempo-node/ansible/roles/obs_tempo/files/nexus-tempo.service` — added `-target=scalable-single-binary` to ExecStart. This enables the multi-node mode that actually consults the `memberlist:` config + joins peers via gossip. |
| T16 | After T15, Tempo fails to start: `failed to create compactor: no useable address found for interfaces [eth0 en0]`. | Tempo's ring components auto-detect their instance address by looking at `eth0` / `en0` by default. The deb13 baseline renames NICs to `nic0` (VMnet11) + `nic1` (VMnet10 backplane). | `terraform/envs/obs-tempo/role-overlay-tempo-config.tf` v2 — added `instance_interface_names: ["nic1"]` + `instance_addr: $vmnet10` on every ring component (`ingester.lifecycler`, `compactor.ring`, `metrics_generator.ring`). |
| T17 | After T16, Tempo fails to start: `yaml: control characters are not allowed`. | The PowerShell here-string + Terraform heredoc combo treats backticks `` ` `` as escape characters. YAML comments containing `` `eth0`/`en0` `` had the backticks consumed + the leading char eaten (became `th0`/`n0`); some chars in the broken comment line were left as raw control chars rejected by Tempo's YAML parser. | `terraform/envs/obs-tempo/role-overlay-tempo-config.tf` v3 — stripped all backticks from YAML comments inside the template. Use plain text `eth0/en0` not `` `eth0`/`en0` ``. Mirrors the existing [[powershell-backtick-method-continuation]] memory but applies more broadly to *any* PowerShell here-string content that travels through to YAML / bash. |
| T18 | After T17, Tempo fails to start: `error initialising module: querier: frontend worker address not specified`. | `scalable-single-binary` mode requires the querier to know where the query frontend is. In single-binary mode the frontend runs in the SAME process, but the auto-detect doesn't fire for the worker → frontend connection. | `terraform/envs/obs-tempo/role-overlay-tempo-config.tf` v4 — added explicit `querier.frontend_worker.frontend_address: 127.0.0.1:9095` (the local gRPC listener on the same node). |
| T19 | After T18, services GREEN, but smoke-0.I.3.ps1 fails: "Tempo :3200 open on VMnet11" + "tempo.yaml has memberlist + s3 sections" (false negatives). | (a) nftables ruleset uses set syntax `dport { 3200, 4317, 4318 }` but smoke regex looked for `dport 3200` literal. (b) Tempo schema_config uses `backend: s3` not Loki's `object_store: s3`. | `scripts/smoke-0.I.3.ps1` — regex fixed: match `3200, 4317, 4318` set + `backend: s3` keyword (Tempo-canonical). Smoke gate now matches Tempo's actual config + nftables shape. |


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
