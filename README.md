# Bypass Router

基于 Tailscale + mihomo 的旁路由网关，开箱即用。

将你的代理节点配置进去，LAN 设备和 Tailscale 远端设备即可自动分流——国内直连，海外走代理。

## 特性

- **透明代理** — LAN 设备只需改网关/DNS，无需安装任何软件
- **Tailscale 集成** — 远端设备使用 Exit Node 即可获得相同分流能力
- **自动分流** — 国内流量直连，海外流量走代理，广告拦截
- **Fake-IP DNS** — 防止 DNS 泄露，减少代理延迟
- **一键部署** — `setup.sh` 自动检测网络环境

## 架构

```
  ┌─────────────────────────────────────────────┐
  │            Bypass Router 容器                │
  │                                             │
  │  ┌───────────┐      ┌──────────────────┐    │
  │  │ Tailscale │      │     mihomo       │    │
  │  │(exit node)│      │ tproxy :7894     │    │
  │  │           │      │ DNS    :53       │    │
  │  └─────┬─────┘      │ mixed  :7890     │    │
  │        │            └────────┬─────────┘    │
  │  ┌─────┴─────────────────────┴─────────┐    │
  │  │  共享网络命名空间 (network namespace) │   │
  │  │  eth0 (ipvlan → 物理网卡 eno1)       │   │
  │  │  tailscale0 (WireGuard 隧道)         │   │
  │  └─────────────────────────────────────┘    │
  │  nftables: TProxy + DNS 劫持 + NAT         │
  └─────────────────────────────────────────────┘

```

两个容器共享网络命名空间，nftables 同时拦截 LAN 和 Tailscale 流量，统一交给 mihomo 处理。

## 快速开始

### 前提条件

- Linux 主机（NAS、树莓派、小主机等）
- [Docker](https://docs.docker.com/engine/install/) + [Compose V2](https://docs.docker.com/compose/install/)
- 内核支持 `ipvlan`（大部分现代发行版已支持）
- 至少一个可用的代理节点

### 安装

```bash
git clone https://github.com/yourname/bypass-router.git
cd bypass-router
bash setup.sh
```

`setup.sh` 会自动检测你的网络环境，引导你配置代理节点和 Tailscale，然后启动服务。

### 使用

#### LAN 设备

将设备的**网关**和 **DNS** 都设置为旁路由 IP（安装时显示的地址）。

#### Tailscale 远端设备

1. 在 [Tailscale 管理面板](https://login.tailscale.com/admin/machines) 找到旁路由设备
2. 点击 `...` → `Use as exit node`
3. 此设备的所有流量将自动经过旁路由分流

#### 管理面板

访问 `http://<旁路由IP>:9090` 可查看 mihomo 的实时状态。

推荐面板：[yacd](http://yacd.haishan.me) 或 [metacubexd](https://d.metacubex.one)

> **注意：** 管理面板未设置认证（`secret`），这是有意为之的设计——旁路由部署在内网可信环境中，局域网内设备可直接访问，降低使用门槛。如果你的网络环境不可信，请在 `mihomo/config.yaml` 中添加 `secret` 字段，或通过防火墙限制 9090 端口的访问范围。

## 配置

项目只有两个需要用户关注的配置：

### `.env` — 网络与 Tailscale

由 `setup.sh` 自动生成，通常不需要手动编辑。

```bash
LAN_PARENT=eno1              # 物理网卡
LAN_SUBNET=192.168.1.0/24    # LAN 子网
LAN_GATEWAY=192.168.1.1      # LAN 网关
BYPASS_IP=192.168.1.100      # 旁路由 IP
TS_HOSTNAME=bypass-router    # Tailscale 设备名
```

### `mihomo/user.yaml` — 代理节点

唯一需要手动编辑的文件。只包含你的代理节点/订阅节点和策略组：

```yaml
proxies:
  - name: my-node
    type: vmess
    server: example.com
    port: 443
    uuid: your-uuid-here
    alterId: 0
    cipher: auto

  - name: my-trojan
    type: trojan
    server: another.com
    port: 443
    password: your-password

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - my-node
      - my-trojan
      - DIRECT

  - name: FINAL
    type: select
    proxies:
      - PROXY
      - DIRECT
```

**策略组必须包含 `PROXY` 和 `FINAL` 两个策略组。**

修改后重新生成配置并重启：

```bash
bash scripts/gen-config.sh && docker compose restart mihomo
```

## 常用命令

```bash
# 查看日志
docker compose logs -f

# 查看旁路由日志
docker compose logs -f bypass-netns

# 查看 mihomo 日志
docker compose logs -f mihomo

# 停止
docker compose down

# 重启
docker compose restart

# 更新代理后重启
bash scripts/gen-config.sh && docker compose restart mihomo
```

## 工作原理

1. Docker 使用 `ipvlan` L2 模式将容器直接接入 LAN，拥有独立 IP
2. `nftables` 拦截所有来自 LAN 和 Tailscale 的流量
3. DNS 查询被劫持到 mihomo 的 Fake-IP DNS（端口 53）
4. 其他流量通过 TProxy 透明代理到 mihomo（端口 7894）
5. mihomo 根据规则决定直连或走代理
6. 策略路由（fwmark + table 100）确保 TProxy 正确工作

## 注意事项

### ipvlan 宿主机互访限制

本项目使用 Docker `ipvlan` L2 网络驱动，容器直接接入物理 LAN 并拥有独立 IP。**这是 ipvlan 的已知限制：宿主机与容器之间无法互相通信。**

具体影响：

- 宿主机**不能**将旁路由设为自己的网关/DNS
- 宿主机**不能**直接访问旁路由 IP（包括管理面板 `:9090`）
- LAN 内**其他设备**一切正常，不受影响

如果需要从宿主机访问管理面板，可通过 LAN 内其他设备（如手机、笔记本）打开，或在宿主机上添加临时路由（macvlan 同理，需 `ip link` 创建 vlan 接口），一般无需额外处理。

### 国内部署


| 步骤 | 需要访问 | 国内直连 |
|------|----------|----------|
| 拉取 Tailscale 镜像 | `swr.cn-north-4.myhuaweicloud.com` | ✅ |
| 拉取 mihomo 镜像 | `swr.cn-north-4.myhuaweicloud.com` | ✅ |
| 构建 router 镜像 (apk) | Alpine 仓库 | ✅ |
| Tailscale 登录 | `controlplane.tailscale.com` | ⚠️ 官方服务很慢但可达 |
| GH CDN下载分流规则 | `testingcf.jsdelivr.net` | ✅ |
| DNS 解析 | 国内外 DoH | ✅ |

## 文件结构

```
bypass-router/
├── .env                         # 网络参数（setup.sh 自动生成）
├── .env.example                 # 配置模板
├── setup.sh                     # 一键安装向导
├── docker-compose.yml           # 容器编排
├── resolv.conf                  # 容器上游 DNS
├── router/
│   ├── Dockerfile               # Tailscale 路由器镜像
│   └── entrypoint.sh            # 启动脚本
├── mihomo/
│   ├── user.yaml.example        # 代理配置模板
│   ├── user.yaml                # 你的代理配置（手动创建或自动生成）
│   └── config.yaml              # 完整配置（自动生成，勿手动编辑）
├── nft/
│   └── bypass.nft               # nftables 防火墙规则
├── scripts/
│   └── gen-config.sh            # 配置合并脚本
└── tailscale-state/             # Tailscale 持久化状态
```

## 故障排除

### Tailscale 首次登录

首次启动时需要手动认证。查看日志获取登录链接：

```bash
docker compose logs bypass-netns | grep login.tailscale.com
```

### 设备无法上网

1. 确认设备的网关和 DNS 都指向旁路由 IP
2. 确认旁路由 IP 可以 ping 通
3. 查看 mihomo 日志是否有错误：`docker compose logs mihomo`
4. 确认代理节点配置正确

### mihomo 配置错误

如果修改 `user.yaml` 后 mihomo 无法启动，可以检查生成的配置：

```bash
# 重新生成
bash scripts/gen-config.sh

# 查看完整配置
cat mihomo/config.yaml
```

### 更换代理节点

编辑 `mihomo/user.yaml`，然后：

```bash
bash scripts/gen-config.sh && docker compose restart mihomo
```

## 许可证

MIT
