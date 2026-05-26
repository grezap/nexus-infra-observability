#!/bin/bash
# observability-node-firstboot.sh -- runs once at first boot per observability-node clone.
#
# Linear port of lakehouse-node-firstboot.sh (nexus-infra-lakehouse), scaled to
# the foundation-tier obs extension. Same NIC discrimination by MAC OUI byte 5
# (0x00 primary VMnet11, 0x01 secondary VMnet10), same /etc/hosts pattern, same
# hostname renaming, same VMnet10 backplane .link MAC-match.
#
# IP-to-role map covers ALL Phase 0.I observability tier nodes (ADR-0038):
#   - Prom HA pair:       prom-1/2          (.170/.171)   Prom + Alertmanager mesh
#   - Loki SSD:           loki-1/2/3        (.172-.174)   read+write+backend per node
#   - Tempo scalable:     tempo-1/2/3       (.175-.177)   distributor+ingester+querier+...
#   - Grafana HA:         grafana-1/2       (.178/.179)   active-active -> VIP .184
#   - Grafana PG HA:      grafana-pg-1/2    (.180/.181)   streaming repl -> VIP .185
#   - OTel Collector:     otel-collector-1/2 (.182/.183)  OTLP receivers, RR DNS
# A clone landing on an unmapped IP fails fast with a clear error.
#
# This script does NOT enable any role service. The Terraform role-overlays
# render per-host config (Prom scrape, Alertmanager mesh peers, Loki/Tempo
# memberlist seeds, Grafana datasources + keepalived VIP, PG streaming
# replication + keepalived VIP) and enable exactly one role service per node
# post-apply.
#
# For grafana-pg-1/2 it additionally parses primary/replica from the hostname
# (grafana-pg-1 = primary, grafana-pg-2 = replica) and emits NEXUS_PG_ROLE.
# For grafana-1/2 + grafana-pg-1/2 it emits NEXUS_KEEPALIVED_PRIORITY (110 for
# the -1 MASTER, 100 for the -2 BACKUP) so the keepalived overlay can render
# without per-node config.
#
# Idempotent: marker at /var/lib/observability-node-firstboot-done short-
# circuits re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/observability-node-firstboot-done
LOG_PREFIX="[observability-node-firstboot]"
IDENTITY_DIR=""
IDENTITY_FILE=""

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- obs tier requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# ─── 2. Ensure nic0 == primary, nic1 == secondary ──────────────────────────
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 DHCP ─────────────────────────────────────────────────
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map IP -> hostname + VMnet10 IP + role + cluster ─────────────────
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: observability).
# Convention: VMnet10 fourth octet matches VMnet11 (obs tier shares the .17x/.18x
# decade on VMnet11 and the 10.90.x decade on VMnet10).
HOSTNAME=""; VMNET10_IP=""; ROLE=""; CLUSTER=""
case "$VMNET11_IP" in
  # ─── 0.I.1 -- Prom HA pair + Alertmanager mesh ─────────────────────────
  192.168.70.170) HOSTNAME=prom-1;            VMNET10_IP=192.168.10.170; ROLE=prom;            CLUSTER=observability ;;
  192.168.70.171) HOSTNAME=prom-2;            VMNET10_IP=192.168.10.171; ROLE=prom;            CLUSTER=observability ;;

  # ─── 0.I.2 -- Loki simple-scalable (3 nodes, memberlist ring) ──────────
  192.168.70.172) HOSTNAME=loki-1;            VMNET10_IP=192.168.10.172; ROLE=loki;            CLUSTER=observability ;;
  192.168.70.173) HOSTNAME=loki-2;            VMNET10_IP=192.168.10.173; ROLE=loki;            CLUSTER=observability ;;
  192.168.70.174) HOSTNAME=loki-3;            VMNET10_IP=192.168.10.174; ROLE=loki;            CLUSTER=observability ;;

  # ─── 0.I.3 -- Tempo scalable (3 nodes, memberlist ring) ────────────────
  192.168.70.175) HOSTNAME=tempo-1;           VMNET10_IP=192.168.10.175; ROLE=tempo;           CLUSTER=observability ;;
  192.168.70.176) HOSTNAME=tempo-2;           VMNET10_IP=192.168.10.176; ROLE=tempo;           CLUSTER=observability ;;
  192.168.70.177) HOSTNAME=tempo-3;           VMNET10_IP=192.168.10.177; ROLE=tempo;           CLUSTER=observability ;;

  # ─── 0.I.4 -- Grafana HA pair -> VRRP VIP .184 ─────────────────────────
  192.168.70.178) HOSTNAME=grafana-1;         VMNET10_IP=192.168.10.178; ROLE=grafana;         CLUSTER=observability ;;
  192.168.70.179) HOSTNAME=grafana-2;         VMNET10_IP=192.168.10.179; ROLE=grafana;         CLUSTER=observability ;;

  # ─── 0.I.4 -- Grafana Postgres HA pair -> VRRP VIP .185 ────────────────
  192.168.70.180) HOSTNAME=grafana-pg-1;      VMNET10_IP=192.168.10.180; ROLE=grafana-pg;      CLUSTER=observability ;;
  192.168.70.181) HOSTNAME=grafana-pg-2;      VMNET10_IP=192.168.10.181; ROLE=grafana-pg;      CLUSTER=observability ;;

  # ─── 0.I.5 -- OTel Collector pair -> RR DNS otel.nexus.lab (no VIP) ────
  192.168.70.182) HOSTNAME=otel-collector-1;  VMNET10_IP=192.168.10.182; ROLE=otel-collector;  CLUSTER=observability ;;
  192.168.70.183) HOSTNAME=otel-collector-2;  VMNET10_IP=192.168.10.183; ROLE=otel-collector;  CLUSTER=observability ;;

  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' -- not a Phase 0.I observability tier IP" >&2
    echo "$LOG_PREFIX recognised IPs: prom-1/2 (.170/.171); loki-1/2/3 (.172-.174); tempo-1/2/3 (.175-.177); grafana-1/2 (.178/.179); grafana-pg-1/2 (.180/.181); otel-collector-1/2 (.182/.183)." >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE cluster=$CLUSTER VMnet10=$VMNET10_IP/24"

# Derive per-ROLE identity dir + owning group.
case "$ROLE" in
  prom)            IDENTITY_DIR=/etc/nexus-prometheus;     IDENTITY_GROUP=prometheus     ;;
  loki)            IDENTITY_DIR=/etc/nexus-loki;           IDENTITY_GROUP=loki           ;;
  tempo)           IDENTITY_DIR=/etc/nexus-tempo;          IDENTITY_GROUP=tempo          ;;
  grafana)         IDENTITY_DIR=/etc/nexus-grafana;        IDENTITY_GROUP=grafana        ;;
  grafana-pg)      IDENTITY_DIR=/etc/nexus-grafana-pg;     IDENTITY_GROUP=postgres       ;;
  otel-collector)  IDENTITY_DIR=/etc/nexus-otel-collector; IDENTITY_GROUP=otel           ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown ROLE '$ROLE' -- no identity dir mapping" >&2
    exit 1
    ;;
esac
IDENTITY_FILE="$IDENTITY_DIR/node-identity.env"

# For grafana-pg nodes, parse primary/replica from the hostname so the
# replication overlay can configure each node without per-node SQL.
PG_ROLE=""
if [ "$ROLE" = "grafana-pg" ]; then
  case "$HOSTNAME" in
    grafana-pg-1) PG_ROLE=primary ;;
    grafana-pg-2) PG_ROLE=replica ;;
    *)
      echo "$LOG_PREFIX ERROR: could not derive PG role from hostname '$HOSTNAME'" >&2
      exit 1
      ;;
  esac
  echo "$LOG_PREFIX grafana-pg PG role: $PG_ROLE"
fi

# For VIP-fronted pairs (grafana-1/2, grafana-pg-1/2), derive keepalived
# priority + state. Canon (ADR-0025): -1 = MASTER prio 110, -2 = BACKUP prio 100.
KEEPALIVED_STATE=""
KEEPALIVED_PRIORITY=""
case "$HOSTNAME" in
  grafana-1|grafana-pg-1)
    KEEPALIVED_STATE=MASTER
    KEEPALIVED_PRIORITY=110
    ;;
  grafana-2|grafana-pg-2)
    KEEPALIVED_STATE=BACKUP
    KEEPALIVED_PRIORITY=100
    ;;
esac
if [ -n "$KEEPALIVED_STATE" ]; then
  echo "$LOG_PREFIX keepalived: state=$KEEPALIVED_STATE priority=$KEEPALIVED_PRIORITY"
fi

# ─── 5. Hostname + /etc/hosts ──────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# ─── 6. VMnet10 backplane config (.link MAC-match + .network static) ───────
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# ─── 7. Write the node-identity env file for the Terraform role-overlays ───
mkdir -p "$IDENTITY_DIR"
{
  echo "# Generated by observability-node-firstboot.sh -- do not edit by hand."
  echo "NEXUS_HOSTNAME=$HOSTNAME"
  echo "NEXUS_ROLE=$ROLE"
  echo "NEXUS_CLUSTER=$CLUSTER"
  echo "NEXUS_VMNET11_IP=$VMNET11_IP"
  echo "NEXUS_VMNET10_IP=$VMNET10_IP"
  if [ "$ROLE" = "grafana-pg" ]; then
    echo "NEXUS_PG_ROLE=$PG_ROLE"
  fi
  if [ -n "$KEEPALIVED_STATE" ]; then
    echo "NEXUS_KEEPALIVED_STATE=$KEEPALIVED_STATE"
    echo "NEXUS_KEEPALIVED_PRIORITY=$KEEPALIVED_PRIORITY"
  fi
} > "$IDENTITY_FILE"
chown "root:$IDENTITY_GROUP" "$IDENTITY_FILE"
chmod 640 "$IDENTITY_FILE"
echo "$LOG_PREFIX wrote $IDENTITY_FILE (group=$IDENTITY_GROUP)"

# ─── 8. Mark complete ──────────────────────────────────────────────────────
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role in $CLUSTER cluster on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"
