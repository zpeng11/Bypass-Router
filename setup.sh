#!/usr/bin/env bash
# ============================================================
# setup.sh — 旁路由一键安装向导
#
# 自动检测 LAN 网络环境，生成配置，引导代理节点配置。
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- 颜色与输出函数 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}[$1]${NC} $2"; }
inc()   { (( $1++ )) || true; }

# --- IP 冲突检测工具函数 ---

# ip_to_int IPADDR
# 将 IPv4 点分十进制转为 32 位整数
ip_to_int() {
    local IFS='.'
    # shellcheck disable=SC2206
    local parts=($1)
    echo "$(( (parts[0] << 24) + (parts[1] << 16) + (parts[2] << 8) + parts[3] ))"
}

# int_to_ip INT
# 将 32 位整数转为 IPv4 点分十进制
int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# is_ip_in_use IPADDR
# 检测 IP 是否已被 LAN 中设备使用。返回 0=占用, 1=空闲。
is_ip_in_use() {
    local ip="$1"

    # 排除宿主机自身 IP（find_free_ip 已单独跳过，此处防御外部直接调用）
    if ip -4 addr show 2>/dev/null | grep -qP "inet ${ip}/"; then
        return 0
    fi

    # 第一优先: arping (ARP 层探测，最可靠)
    if command -v arping >/dev/null 2>&1; then
        if arping -c 2 -w 1 -I "${IFACE}" "$ip" >/dev/null 2>&1; then
            return 0
        fi
        # arping 无响应 → ARP 层确认空闲，不再回退
        return 1
    fi

    # 回退: ping (arping 不可用时)
    if ping -c 1 -W 1 -n "$ip" >/dev/null 2>&1; then
        return 0
    fi

    # 补充: ARP 缓存检查
    local neigh_state
    neigh_state=$(ip neigh show "$ip" dev "${IFACE}" 2>/dev/null \
        | awk '{print $NF}' | head -1)
    if [[ -n "$neigh_state" \
          && "$neigh_state" != "FAILED" \
          && "$neigh_state" != "INCOMPLETE" ]]; then
        return 0
    fi

    return 1
}

# find_free_ip START_IP SUBNET GATEWAY [MAX_SCAN]
# 从 START_IP 开始扫描空闲 IP，输出第一个可用 IP，失败则无输出。
find_free_ip() {
    local start_ip="$1"
    local subnet="$2"
    local gateway="$3"
    local max_scan="${4:-50}"

    # 解析子网
    local net_addr prefix
    net_addr="${subnet%%/*}"
    prefix="${subnet##*/}"

    local net_int first_host last_host
    net_int=$(ip_to_int "$net_addr")
    first_host=$(( net_int + 1 ))
    last_host=$(( net_int + (1 << (32 - prefix)) - 2 ))  # 减去网络地址和广播

    # 收集宿主机所有 IPv4 地址
    local -a own_ips=()
    mapfile -t own_ips < <(
        ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | cut -d'/' -f1
    )

    # 从建议 IP 开始扫描
    local current
    current=$(ip_to_int "$start_ip")
    # 限制在有效主机范围内
    (( current < first_host )) && current=$first_host
    (( current > last_host ))  && current=$first_host

    local start_int=$current scanned=0

    while (( scanned < max_scan )); do
        (( current > last_host )) && current=$first_host
        # 扫描回起点，说明已遍历整个范围
        (( current == start_int && scanned > 0 )) && break

        local candidate
        candidate=$(int_to_ip "$current")

        # 跳过网关
        if [[ "$candidate" == "$gateway" ]]; then
            inc current; inc scanned
            continue
        fi

        # 跳过宿主机自身 IP
        local skip=0
        for own in "${own_ips[@]+"${own_ips[@]}"}"; do
            if [[ "$candidate" == "$own" ]]; then
                skip=1; break
            fi
        done
        if (( skip )); then
            inc current; inc scanned
            continue
        fi

        # 检测 IP 是否空闲
        if ! is_ip_in_use "$candidate"; then
            echo "$candidate"
            return 0
        fi

        warn "  IP ${candidate} 已被占用，继续搜索..."
        inc current; inc scanned
    done

    return 1
}

# check_docker_network_overlap SUBNET
# 检测已有 Docker 网络是否与目标子网冲突。
# 如有冲突，提示用户并尝试清理。返回 0=无冲突/已解决, 1=未解决。
check_docker_network_overlap() {
    local target_subnet="$1"

    local target_net="${target_subnet%%/*}"
    local target_prefix="${target_subnet##*/}"
    local target_int
    target_int=$(ip_to_int "$target_net")

    # 当前 compose 项目名（目录名小写）
    local current_project
    current_project=$(basename "${PROJECT_DIR}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')

    # 扫描所有用户创建的 Docker 网络
    local -a conflict_names=()
    local -a conflict_subnets=()

    while IFS= read -r net_name; do
        [[ -z "$net_name" ]] && continue

        # 跳过当前 compose 项目自身的网络（compose up 会自动处理）
        local proj
        proj=$(docker network inspect "$net_name" \
            --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null || true)
        if [[ "$proj" == "$current_project" ]]; then
            continue
        fi

        # 提取该网络的所有 IPv4 子网
        local subnets
        subnets=$(docker network inspect "$net_name" \
            --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)

        for s in $subnets; do
            # 跳过 IPv6
            [[ "$s" == *:* ]] && continue
            # 跳过无效格式
            [[ "$s" != */* ]] && continue

            local s_net="${s%%/*}"
            local s_prefix="${s##*/}"
            local s_int
            s_int=$(ip_to_int "$s_net")

            # CIDR 重叠判定：取较短前缀的掩码，看网络地址是否相同
            local min_p=$(( target_prefix < s_prefix ? target_prefix : s_prefix ))
            local mask=$(( (0xFFFFFFFF << (32 - min_p)) & 0xFFFFFFFF ))

            if (( (target_int & mask) == (s_int & mask) )); then
                conflict_names+=("$net_name")
                conflict_subnets+=("$s")
            fi
        done
    done < <(docker network ls --filter type=custom --format '{{.Name}}' 2>/dev/null)

    if (( ${#conflict_names[@]} == 0 )); then
        return 0
    fi

    # ---- 报告冲突 ----
    warn "检测到 Docker 网络子网与 ${target_subnet} 冲突："
    echo ""
    for i in "${!conflict_names[@]}"; do
        echo -e "  ${RED}✘${NC} ${conflict_names[$i]} (${conflict_subnets[$i]})"
    done
    echo ""

    read -rp "  是否移除冲突的网络? [Y/n]: " cleanup
    cleanup="${cleanup:-Y}"

    if [[ "${cleanup,,}" != "y" ]]; then
        error "存在未解决的网络冲突，无法继续启动。请手动移除冲突网络后重试。"
    fi

    local had_error=0
    for name in "${conflict_names[@]}"; do
        if docker network rm "$name" >/dev/null 2>&1; then
            info "已移除网络: ${name}"
        else
            warn "无法移除网络 ${name}（可能存在活动容器）"
            warn "  提示: 先停止使用该网络的容器，例如 docker compose -f <路径> down"
            had_error=1
        fi
    done

    if (( had_error )); then
        error "部分网络无法移除，请先停止相关容器后重试。"
    fi

    info "网络冲突已解决"
    return 0
}

# resolve_ip IP
# 检查 IP 冲突，冲突时提示用户或自动找空闲 IP，输出最终 IP。
resolve_ip() {
    local ip="$1"
    if is_ip_in_use "$ip"; then
        warn "警告: IP ${ip} 似乎已被使用！这可能导致网络冲突。"
        read -rp "  仍然使用此 IP? [y/N]: " force_ip
        if [[ "${force_ip,,}" != "y" ]]; then
            local free
            free=$(find_free_ip "$ip" "$SUBNET" "$GATEWAY" 50)
            if [[ -n "$free" ]]; then
                echo "$free"
            else
                error "无法找到空闲 IP，请手动确认后重新运行"
            fi
        else
            echo "$ip"
        fi
    else
        echo "$ip"
    fi
}

# --- 前置检查 ---
step "1/5" "环境检查"

if [[ "$(uname -s)" != "Linux" ]]; then
    error "此脚本仅支持 Linux 环境"
fi

command -v ip >/dev/null 2>&1 || error "ip 命令未找到，请安装 iproute2"
command -v docker >/dev/null 2>&1 || error "docker 未安装"
docker compose version >/dev/null 2>&1 || error "docker compose 未安装（需要 Compose V2）"

info "环境检查通过"

# --- 网络自动检测 ---
step "2/5" "自动检测网络环境"

# 默认出口网卡与网关（一次解析）
read -r _ _ GATEWAY _ IFACE _ < <(ip -4 route show default 2>/dev/null)
[[ -z "$IFACE" ]] && error "无法检测默认网卡。请确认网络连接正常。"
[[ -z "$GATEWAY" ]] && error "无法检测默认网关。"

# 子网（从接口的连接路由获取）
SUBNET=$(ip -4 route show dev "$IFACE" 2>/dev/null | grep -v default | grep -oP '^[\d.]+/\d+' | head -1)
[[ -z "$SUBNET" ]] && error "无法检测 $IFACE 的子网。"

# 建议旁路由 IP
NETWORK_PREFIX=$(echo "$GATEWAY" | cut -d. -f1-3)
SUGGESTED_IP="${NETWORK_PREFIX}.100"
if [[ "$SUGGESTED_IP" == "$GATEWAY" ]]; then
    SUGGESTED_IP="${NETWORK_PREFIX}.101"
fi

# 检测 arping 可用性
if command -v arping >/dev/null 2>&1; then
    info "检测到 arping，将使用 ARP 探测检测 IP 冲突"
else
    warn "未检测到 arping，将使用 ping 检测 IP 冲突（不如 ARP 探测可靠）"
    warn "建议安装: apt install iputils-arping / apk add iputils"
fi

# 自动扫描空闲 IP
info "正在扫描空闲 IP (从 ${SUGGESTED_IP} 开始)..."
FREE_IP=$(find_free_ip "$SUGGESTED_IP" "$SUBNET" "$GATEWAY" 50)

if [[ -n "$FREE_IP" ]]; then
    if [[ "$FREE_IP" != "$SUGGESTED_IP" ]]; then
        info "IP ${SUGGESTED_IP} 已被占用，已自动找到空闲 IP: ${FREE_IP}"
    else
        info "IP ${SUGGESTED_IP} 可用（未检测到冲突）"
    fi
    SUGGESTED_IP="$FREE_IP"
else
    warn "在子网 ${SUBNET} 中未找到空闲 IP（已扫描 50 个地址）"
    warn "你仍可手动指定 IP，但请确保该 IP 未被其他设备使用"
fi

# 显示检测结果
echo ""
echo -e "  ${BLUE}网卡:${NC}       ${IFACE}"
echo -e "  ${BLUE}子网:${NC}      ${SUBNET}"
echo -e "  ${BLUE}网关:${NC}      ${GATEWAY}"
echo -e "  ${BLUE}旁路由 IP:${NC}  ${SUGGESTED_IP} (建议)"
echo ""

read -rp "  以上信息是否正确? [Y/n]: " confirm
confirm="${confirm:-Y}"

if [[ "${confirm,,}" != "y" ]]; then
    echo ""
    read -rp "  网卡 (如 eno1, eth0): " IFACE
    read -rp "  子网 (如 192.168.1.0/24): " SUBNET
    read -rp "  网关 (如 192.168.1.1): " GATEWAY
    read -rp "  旁路由 IP: " BYPASS_IP
    BYPASS_IP=$(resolve_ip "$BYPASS_IP")
else
    read -rp "  旁路由 IP [${SUGGESTED_IP}]: " BYPASS_IP
    BYPASS_IP="${BYPASS_IP:-$SUGGESTED_IP}"
    # 用户覆盖了建议值时也检查
    if [[ "$BYPASS_IP" != "$SUGGESTED_IP" ]]; then
        BYPASS_IP=$(resolve_ip "$BYPASS_IP")
    fi
fi

# --- Tailscale 配置 ---
step "3/5" "Tailscale 配置"

read -rp "  设备名称 [bypass-router]: " TS_HOSTNAME
TS_HOSTNAME="${TS_HOSTNAME:-bypass-router}"

echo ""
echo "  Tailscale Auth Key 用于免交互登录。"
echo "  留空则首次启动时需要手动打开链接登录。"
echo "  生成地址: https://login.tailscale.com/admin/settings/keys"
read -rp "  TS_AUTHKEY (留空跳过): " TS_AUTHKEY

echo ""
echo "  是否允许 Tailscale 远端设备通过此旁路由访问你的 LAN?"
read -rp "  广播 LAN 路由 (${SUBNET})? [y/N]: " ts_routes_confirm
if [[ "${ts_routes_confirm,,}" == "y" ]]; then
    TS_ROUTES="$SUBNET"
else
    TS_ROUTES=""
fi

# --- 写入 .env ---
cat > "${PROJECT_DIR}/.env" <<EOF
# ===== LAN 参数 (auto-detected) =====
LAN_PARENT=${IFACE}
LAN_SUBNET=${SUBNET}
LAN_GATEWAY=${GATEWAY}
BYPASS_IP=${BYPASS_IP}

# ===== Tailscale 参数 =====
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${TS_HOSTNAME}
TS_ROUTES=${TS_ROUTES}
TS_EXTRA_ARGS=--advertise-exit-node --accept-dns=false  --stateful-filtering=false

# ===== 其他 =====
TZ=Asia/Shanghai
EOF

info ".env 已生成"

# --- 代理节点配置 ---
step "4/5" "代理节点配置"

USER_FILE="${PROJECT_DIR}/mihomo/user.yaml"
EXAMPLE_FILE="${PROJECT_DIR}/mihomo/user.yaml.example"

if [[ ! -f "$USER_FILE" ]]; then
    cp "$EXAMPLE_FILE" "$USER_FILE"
    warn "已创建 mihomo/user.yaml 模板"
fi

# 检测是否还是模板内容
if grep -q "your-uuid-here\|example\.com" "$USER_FILE" 2>/dev/null; then
    echo ""
    warn "mihomo/user.yaml 仍为模板内容，请填入你的代理节点。"
    echo ""
    echo -e "  ${BOLD}模板示例:${NC}"
    echo "  ─────────────────────────────────"
    grep -v '^#' "$EXAMPLE_FILE" | grep -v '^$' | sed 's/^/  /' || true
    echo "  ─────────────────────────────────"
    echo ""
    read -rp "  现在编辑代理配置? [Y/n]: " edit_confirm
    edit_confirm="${edit_confirm:-Y}"

    if [[ "${edit_confirm,,}" == "y" ]]; then
        ${EDITOR:-vi} "$USER_FILE"
    else
        warn "请稍后手动编辑 mihomo/user.yaml，然后运行:"
        echo "  bash setup.sh"
        exit 0
    fi
fi

# --- 生成 mihomo config.yaml ---
step "5/5" "生成配置并启动"

info "正在生成 mihomo/config.yaml ..."
bash "${PROJECT_DIR}/scripts/gen-config.sh"

# --- 启动 ---
info "正在检查 Docker 网络冲突..."
check_docker_network_overlap "${SUBNET}"

info "正在启动 bypass-router ..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d

echo ""
sleep 3

# 检查 Tailscale 登录状态
LOGIN_URL=$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" logs bypass-netns 2>&1 \
    | grep -oP 'https://login\.tailscale\.com/[a-f0-9]+' | tail -1 || true)

# --- 完成 ---
echo ""
bar="${GREEN}$(printf '━%.0s' {1..52})${NC}"
echo -e "$bar"
echo -e "${GREEN}  Bypass Router 设置完成！${NC}"
echo -e "$bar"
echo ""
echo -e "  ${BOLD}LAN 客户端:${NC}"
echo "    将设备的网关和 DNS 设置为: ${BYPASS_IP}"
echo ""
echo -e "  ${BOLD}Tailscale:${NC}"
if [[ -n "$LOGIN_URL" ]]; then
    echo "    首次使用，请打开以下链接登录:"
    echo "    ${LOGIN_URL}"
else
    echo "    在 Tailscale 客户端中使用此设备作为 Exit Node"
fi
echo ""
echo -e "  ${BOLD}管理面板:${NC}"
echo "    http://${BYPASS_IP}:9090"
echo ""
echo -e "  ${BOLD}常用命令:${NC}"
echo "    查看日志:   docker compose logs -f"
echo "    停止:       docker compose down"
echo "    更新代理:   编辑 mihomo/user.yaml 后运行:"
echo "                bash scripts/gen-config.sh && docker compose restart mihomo"
echo ""
