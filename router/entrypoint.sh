#!/usr/bin/env bash
set -euo pipefail

TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_HOSTNAME="${TS_HOSTNAME:-bypass-router}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
TS_ROUTES="${TS_ROUTES:-}"

# 时区
if [[ -n "${TZ:-}" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
    echo "${TZ}" > /etc/timezone 2>/dev/null || true
fi

mkdir -p "${TS_STATE_DIR}" /var/run/tailscale

echo "[init] checking sysctl values"
echo -n "net.ipv4.ip_forward="
cat /proc/sys/net/ipv4/ip_forward || true

echo -n "net.ipv4.ip_nonlocal_bind="
cat /proc/sys/net/ipv4/ip_nonlocal_bind || true

echo -n "net.ipv4.tcp_fwmark_accept="
cat /proc/sys/net/ipv4/tcp_fwmark_accept || true

echo -n "net.ipv4.conf.all.rp_filter="
cat /proc/sys/net/ipv4/conf/all/rp_filter || true

echo -n "net.ipv4.conf.default.rp_filter="
cat /proc/sys/net/ipv4/conf/default/rp_filter || true

echo -n "net.ipv4.conf.all.src_valid_mark="
cat /proc/sys/net/ipv4/conf/all/src_valid_mark || true

echo -n "net.ipv6.conf.all.disable_ipv6="
cat /proc/sys/net/ipv6/conf/all/disable_ipv6 || true

echo "[init] installing IPv4 policy routing for TProxy mark 0x1"
ip rule add fwmark 0x1 table 100 2>/dev/null || true
ip route replace local 0.0.0.0/0 dev lo table 100

echo "[init] loading nftables rules"
nft -f /etc/nftables/bypass.nft

echo "[init] using mihomo DNS as local resolver before tailscaled starts"
rm -f /etc/resolv.pre-tailscale-backup.conf 2>/dev/null || true
cat >/etc/resolv.conf <<'RESOLVEOF'
nameserver 127.0.0.1
options timeout:1 attempts:2
RESOLVEOF

echo "[init] starting tailscaled"
tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=tailscale0 &

TAILSCALED_PID=$!

echo "[init] waiting for tailscaled"
for i in $(seq 1 30); do
  if tailscale status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "[init] waiting for mihomo controller on 127.0.0.1:9090"
for i in $(seq 1 30); do
  if curl -fsS --max-time 1 http://127.0.0.1:9090/configs >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

UP_ARGS=()
UP_ARGS+=(--hostname="${TS_HOSTNAME}")

if [[ -n "${TS_ROUTES}" ]]; then
  UP_ARGS+=(--advertise-routes="${TS_ROUTES}")
fi

# shellcheck disable=SC2206
EXTRA_ARGS_ARRAY=(${TS_EXTRA_ARGS})

if [[ -n "${TS_AUTHKEY:-}" ]]; then
  echo "[init] using TS_AUTHKEY login"
  UP_ARGS+=(--auth-key="${TS_AUTHKEY}")
else
  echo "[init] TS_AUTHKEY is empty."
  echo "[init] If this is the first run, copy the Tailscale login URL below and sign in with Google."
fi

echo "[init] running tailscale up"
tailscale up "${UP_ARGS[@]}" "${EXTRA_ARGS_ARRAY[@]}"

tailscale set --auto-update || true

echo "[init] tailscale status:"
tailscale status || true

echo "[init] router namespace ready"
wait "${TAILSCALED_PID}"
