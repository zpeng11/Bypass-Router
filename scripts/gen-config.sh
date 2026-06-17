#!/usr/bin/env bash
# ============================================================
# gen-config.sh — 合并系统模板 + 用户代理配置 → mihomo/config.yaml
#
# 系统配置（端口、DNS、规则）由本项目锁定，用户只需编辑
# mihomo/user.yaml 提供代理节点和策略组。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MIHOMO_DIR="${PROJECT_DIR}/mihomo"
USER_FILE="${MIHOMO_DIR}/user.yaml"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"

# --- 校验 user.yaml ---
if [[ ! -f "$USER_FILE" ]]; then
    echo "[gen-config] ERROR: mihomo/user.yaml not found" >&2
    echo "[gen-config] Run setup.sh first, or copy mihomo/user.yaml.example to mihomo/user.yaml" >&2
    exit 1
fi

# 校验 user.yaml 只允许的顶层键
if grep -qP '^(?!proxies:|proxy-groups:|proxy-providers:|#|---|\s*$)[a-z]' "$USER_FILE" 2>/dev/null; then
    echo "[gen-config] ERROR: user.yaml 只能包含 'proxies'、'proxy-groups'、'proxy-providers' 顶层配置项" >&2
    echo "[gen-config] 端口、DNS、规则等系统配置由本项目自动管理。" >&2
    exit 1
fi

# 校验 user.yaml 包含必要的策略组
if ! grep -q 'name: PROXY' "$USER_FILE"; then
    echo "[gen-config] ERROR: user.yaml 必须包含名为 'PROXY' 的策略组" >&2
    exit 1
fi
if ! grep -q 'name: FINAL' "$USER_FILE"; then
    echo "[gen-config] ERROR: user.yaml 必须包含名为 'FINAL' 的策略组" >&2
    exit 1
fi

# --- 生成 config.yaml ---

mkdir -p "${MIHOMO_DIR}/rule-set"

cat > "$CONFIG_FILE" <<SYSTEMEOF
# ===========================================================
# 此文件由 scripts/gen-config.sh 自动生成，请勿手动编辑。
# 如需修改代理节点，请编辑 mihomo/user.yaml 后重新运行:
#   bash scripts/gen-config.sh && docker compose restart mihomo
# ===========================================================

# ===== 基础设置 =====

mixed-port: 7890
tproxy-port: 7894
allow-lan: true

mode: rule
log-level: info
ipv6: false

external-controller: 0.0.0.0:9090

find-process-mode: off
unified-delay: true
tcp-concurrent: true

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports:
        - 80
        - 8080-8880
    TLS:
      ports:
        - 443
        - 8443


# ===== DNS =====

dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  respect-rules: true

  enhanced-mode: redir-host

  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29

  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query

  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query

  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

  proxy-server-nameserver:
    - 223.5.5.5
    - 119.29.29.29


# ===== 出站节点 (from user.yaml) =====

SYSTEMEOF

# 注入用户的代理节点和策略组
cat "$USER_FILE" >> "$CONFIG_FILE"

# 注入规则集和规则
cat >> "$CONFIG_FILE" <<RULESEOF


# ===== 规则集来源 (MetaCubeX 社区维护，每日更新) =====

rule-providers:
  reject:
    type: http
    behavior: domain
    format: yaml
    path: ./rule-set/reject.yaml
    url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ads-all.yaml"
    interval: 86400
    proxy: DIRECT

  cn-domain:
    type: http
    behavior: domain
    format: yaml
    path: ./rule-set/cn-domain.yaml
    url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.yaml"
    interval: 86400
    proxy: DIRECT

  cn-ip:
    type: http
    behavior: ipcidr
    format: yaml
    path: ./rule-set/cn-ip.yaml
    url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.yaml"
    interval: 86400
    proxy: DIRECT

  geolocation-!cn:
    type: http
    behavior: domain
    format: yaml
    path: ./rule-set/geolocation-!cn.yaml
    url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/geolocation-!cn.yaml"
    interval: 86400
    proxy: DIRECT

  telegram:
    type: http
    behavior: ipcidr
    format: yaml
    path: ./rule-set/telegram.yaml
    url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/telegram.yaml"
    interval: 86400
    proxy: DIRECT


# ===== 规则 =====

rules:
  # 私有地址直连
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - IP-CIDR6,ff00::/8,DIRECT,no-resolve

  # 广告拦截
  - RULE-SET,reject,REJECT

  # 中国域名 & IP → 直连
  - RULE-SET,cn-domain,DIRECT
  - RULE-SET,cn-ip,DIRECT

  # 海外域名 → 代理
  - RULE-SET,geolocation-!cn,PROXY

  # Telegram → 代理
  - RULE-SET,telegram,PROXY

  # 兜底
  - MATCH,FINAL
RULESEOF

echo "[gen-config] mihomo/config.yaml generated successfully"
