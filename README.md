# 9929-gost-mtcp

基于 GOST MTCP 的 ECMP 低延迟路径优选与故障自愈方案。已实测覆盖 Remote
整体不可达、outer 消失，以及 TCP 保持 `ESTAB` 但 MTCP 数据面失效的恢复路径。

## 架构

```text
+----------------+           +------------------------------------+    selected MTCP outer    +--------------------------------+
| Business       |    TCP    | CN GOST                            | ========================> | Remote GOST                    |
| clients        | --------> | business :12000 + relays           |                           | MTCP listener :6600            |
|                |           | anchor/probe 127.0.0.1:12001       |                           | per-stream TCP relay           |
|                |           | shared chain-mtcp / connector      |                           |                                |
+----------------+           +------------------+-----------------+                           +----------------+---------------+
                                                ^                                                              |
                                                | manages / observes                                           v
                             +------------------------------------+                           +--------------------------------+
                             | CN recovery control                |                           | requested stream targets       |
                             | Prewarm : draw ECMP by minrtt      |                           | business :2345/:2347/...       |
                             | Anchor  : hold logical stream      |                           | probe echo :12346              |
                             | Watchdog: PID/outer/RTT/Remote     |
                             | Probe   : 1-byte payload echo      |
                             +------------------------------------+
```

跨境链路存在 ECMP，不同新建 TCP 可能落到约 32-34 ms 的快路，也可能落到约
50-52 ms 的慢路。系统通过以下组件把业务稳定复用到一条选中的 outer：

- **业务入口**：`:12000` 及 Relay 管理器增加的端口都使用 `chain-mtcp`，共享同一个
  MTCP connector 和唯一 outer；每个 logical stream 携带各自的 Remote backend 目标。
- **Prewarm**：由 Anchor 建立候选 outer，读取 TCP `minrtt`；达到阈值则保留，慢路则
  停止 Anchor、移除当前 outer，并重新抽取下一条 ECMP session；抽取额度耗尽时保留
  最后一条可用路径，优先保证业务可连接。
- **Anchor**：持续占用一个轻量 logical stream，锁定选中的 outer；本机入口是
  `127.0.0.1:12001`，Remote 目标是 echo endpoint `127.0.0.1:12346`。
- **Watchdog**：监控 GOST PID、outer 数量、TCP RTT、Anchor、Remote TCP 和实际数据面，
  写入状态/事件文件，并对 Remote 真断、outer 消失及 stale outer 分别进入恢复路径。
- **Data Plane Probe**：同样经过 `12001 -> chain-mtcp -> selected outer -> 12346`，每
  15 秒默认执行一次 1 Byte payload echo，识别“TCP 仍为 `ESTAB`、但 MTCP 数据面已死”。
- **Remote Relay**：在 `:6600` 接收共享 outer 内的 logical streams，再按 stream 目标
  转发到 `127.0.0.1:2345`、`:2347` 等业务后端或 `127.0.0.1:12346` 探测 endpoint。

## 快速安装

**推荐：单文件安装器（无需克隆项目）**

```bash
# 1. 先安装 Remote（境外服务器）
curl -fsSL https://raw.githubusercontent.com/zcp1997/9929-gost-mtcp/main/standalone-install.sh | bash -s remote

# 2. 记录 Remote 的公网 IPv4 和 MTCP 端口（默认 6600）

# 3. 再安装 CN（中国大陆服务器）
curl -fsSL https://ghfast.top/raw.githubusercontent.com/zcp1997/9929-gost-mtcp/main/standalone-install.sh | bash -s cn
# 按提示输入 Remote IP、端口和 RTT 阈值（默认 40ms）
```

管道安装会从当前终端读取交互输入，因此请直接在 SSH/终端中执行，不要再给命令重定向 stdin。
`GOST_VERSION=v3.2.6` 中的 `v` 只用于 Release tag，安装器会自动使用不带 `v` 的资产文件名。

**传统方式（开发/调试）**

```bash
# CN 服务器
git clone https://ghfast.top/https://github.com/zcp1997/9929-gost-mtcp.git
cd 9929-gost-mtcp
bash install.sh cn

# Remote 服务器
git clone https://github.com/zcp1997/9929-gost-mtcp.git
cd 9929-gost-mtcp
bash install.sh remote
```

## 系统要求

| 组件 | 要求 |
|------|------|
| **OS** | Linux + systemd |
| **权限** | root |
| **通用依赖** | bash, curl, tar, awk, grep, systemctl, sha256sum/shasum |
| **CN 额外** | ss (iproute2), flock (util-linux), timeout (coreutils) |
| **Remote 额外** | socat |

Debian/Ubuntu 安装依赖：

```bash
# 通用
apt-get install -y curl tar coreutils grep gawk systemd

# CN 端
apt-get install -y iproute2 util-linux

# Remote 端  
apt-get install -y socat
```

## 安装后验证

### Remote

```bash
systemctl status gost-mtcp-remote.service
ss -lntp | grep ':6600'
```

### CN（假设线路别名为 jp）

```bash
systemctl status gost-mtcp-jp.service
systemctl status gost-mtcp-jp-watchdog.service

# 查看状态
cat /opt/gost-mtcp/cn/state/status.json

# 查看事件日志
tail -f /opt/gost-mtcp/cn/state/events.jsonl

# 查看 outer 连接（替换实际 IP 和端口）
ss -tin state established 'dst <REMOTE_IP> dport = :6600'
```

正常状态：
- `state: FAST` - 路径满足阈值
- `outer_count: 1` - 唯一 outer TCP
- `minrtt_ms < 40` - 快路
- `data_plane_reachable: yes` - 当前 MTCP 数据面能完成真实 payload 往返
- `data_probe_failures: 0` - 连续数据面探测失败次数
- `anchor_state: up` - Anchor 正常

## 常见配置

### 修改 CN 后端地址

CN 的 `forwarder.nodes[0].addr` 指向 Remote 要连接的最终 TCP 目标。

```bash
# 单文件安装器默认路径
nano /opt/gost-mtcp/cn/cn.yaml

# 或传统方式路径
nano /root/9929-gost-mtcp/cn/cn.yaml

# 修改后端地址
forwarder:
  nodes:
  - name: backend
    addr: 127.0.0.1:8080  # 改为实际地址

# 重启服务
systemctl restart gost-mtcp-jp.service
```

### 修改 RTT 阈值

```bash
nano /opt/gost-mtcp/cn/mtcp.conf

# 修改阈值
ACCEPT_RTT_MS=35

# 重启 Watchdog
systemctl restart gost-mtcp-jp-watchdog.service
```

### 数据面探测与 stale outer 恢复

Watchdog 默认每 15 秒经本地 Anchor 入口发送并收回 1 Byte。连续失败 3 次后，
会额外建立一条独立 TCP 连接探测 Remote MTCP 端口：

- Remote TCP 不可达：进入 `DOWN/REMOTE` 安静等待，不循环重启 GOST，也不循环 Prewarm。
- Remote TCP 可达：确认当前连接是 stale outer，限频重启 GOST，再由 Prewarm 自动重新选路。

```bash
# mtcp.conf 默认值
DATA_PROBE_ENABLED=yes
DATA_PROBE_INTERVAL_SEC=15
DATA_PROBE_TIMEOUT_SEC=3
DATA_PROBE_FAIL_THRESHOLD=3
```

将 `DATA_PROBE_ENABLED` 改为 `no` 可以恢复旧版只观察 outer TCP 的行为。

### 故障恢复路径（均已实测）

#### Remote 整体不可达

通过在 JP 端对 MTCP 端口执行 nftables `DROP` 验证：

```text
+----------------------------------------------+
| OUTER_DISAPPEARED                            |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| REMOTE_TCP_DOWN                              |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| DOWN / REMOTE                                |
+----------------------------------------------+
                        |  quiet wait; Remote TCP restored
                        v
+----------------------------------------------+
| REMOTE_TCP_UP                                |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| RECOVERY_SELECT                              |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| PREWARM_SUCCESS (~33.5 ms)                   |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| ANCHOR_BOUND                                 |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| FAST                                         |
+----------------------------------------------+
```

Remote 持续不可达期间不会循环重启 GOST、循环 Prewarm 或高频刷恢复日志；解除
`DROP` 后可自动重新选路并恢复到约 33.5 ms 的 `FAST` 状态。

#### TCP ESTAB 但 MTCP 数据面失效

通过只丢弃当前 outer 四元组、同时保留 Remote 新 TCP 可达性验证：

```text
+----------------------------------------------+
| outer_count=1; TCP=ESTAB; MTCP payload=FAIL  |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| DATA_PROBE_FAILED 1/3 -> 2/3 -> 3/3          |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| STALE_OUTER_CONFIRMED; remote_tcp=up         |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| RESTART_GOST                                 |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| PID_CHANGED                                  |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| PREWARM_SUCCESS (33.319 ms)                  |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| ANCHOR_BOUND                                 |
+----------------------------------------------+
                        |
                        v
+----------------------------------------------+
| FAST; data_plane_reachable=yes; failures=0   |
+----------------------------------------------+
```

实测旧 PID `40229`、outer sport `21764` 在内核仍显示 `ESTAB` 时连续探测失败；
Watchdog 确认 stale outer 后自动重启 GOST，新 PID `46156` 建立 sport `24570`，
以 `minrtt=33.319 ms` 恢复 `FAST`。最终 `data_plane_reachable=yes`、
`data_probe_failures=0`、`anchor_state=up`。

两类恢复路径合起来覆盖了：Remote 真断、outer 消失，以及 outer 仍为 `ESTAB`
但 MTCP mux/数据面已经失效的场景。hard failure 后已有业务 TCP 仍无法迁移，恢复
目标是尽快让后续新连接重新可用。

### 多线路部署

同一台 CN 可以连接多个 Remote，每次执行 `standalone-install.sh cn` 并输入不同的线路别名：

```bash
# 第一条线路
bash standalone-install.sh cn
# 别名: jp, 业务端口: 12000, Anchor: 12001

# 第二条线路
bash standalone-install.sh cn
# 别名: us, 业务端口: 12002, Anchor: 12003
```

### 管理 CN 额外端口 Relay

standalone 安装器可以在不手工编辑 YAML 的情况下列出、增加和删除额外业务入口。
新增 Relay 会和主业务入口共用现有 `chain-mtcp` 及唯一 MTCP outer。

```bash
# 交互管理
bash standalone-install.sh relay

# 分项命令
bash standalone-install.sh relay list
bash standalone-install.sh relay add
bash standalone-install.sh relay remove relay-12002
```

例如执行 `relay add` 后输入：

```text
新增 CN 监听端口: 12002
Remote 后端地址: 127.0.0.1:2347
Relay 服务名: relay-12002
```

会生成 `:12002 → chain-mtcp → 127.0.0.1:2347`。修改前会备份 `cn.yaml`；
脚本随后重启对应 GOST unit，如果服务未恢复 active 会自动回滚。主业务端口和
Anchor 端口不能通过 Relay 管理器删除或覆盖。

如安装目录不是默认的 `/opt/gost-mtcp`，管理时传入相同环境变量：

```bash
INSTALL_BASE=/root/mtcpjpv22 bash standalone-install.sh relay
```

管理器会自动识别 `$INSTALL_BASE/cn/cn.yaml` 和类似你当前
`$INSTALL_BASE/cn.yaml` 的平铺布局；也可以用 `CN_YAML_PATH`、
`CN_MTCP_CONFIG_PATH` 显式指定两个配置文件。

## 重要注意事项

⚠️ **Remote 防火墙必须配置**

Remote 的 MTCP Relay 没有应用层认证，**不要对全网开放**。在防火墙中只允许 CN 的公网 IP 访问 MTCP 端口：

```bash
# UFW 示例
ufw allow from <CN_IP> to any port 6600 proto tcp
```

⚠️ **不要 enable CN 的 Anchor unit**

Anchor 必须由 Prewarm/Watchdog 控制，不要手动启动或 enable：

```bash
# ❌ 错误
systemctl enable gost-mtcp-jp-anchor.service

# ✓ 正确（安装器已自动配置）
systemctl enable gost-mtcp-jp.service
systemctl enable gost-mtcp-jp-watchdog.service
```

⚠️ **hard failure 无法无缝续传**

如果 outer TCP 真正断开、GOST 被 kill 或 Remote 失联，已有业务 TCP 无法迁移到新 outer，只能等客户端重连。Watchdog 保证的是快速恢复新连接。

⚠️ **单文件安装器 vs 传统方式**

| 方案 | 优势 | 适用场景 |
|------|------|----------|
| **单文件安装器** | 下载快、无需 Git、一行命令 | 生产部署、批量安装 |
| **传统方式** | 可查看完整文档和设计 | 开发调试、学习研究 |

## 状态说明

| 状态 | 含义 |
|------|------|
| `FAST` | 唯一 outer、Anchor 正常、路径满足阈值 |
| `DEGRADED` | 连接可用但未达最佳（路径慢、Anchor 异常、数据面探测暂时失败等） |
| `DOWN` | GOST/outer/Remote 不可用 |
| `FAULT` | outer 数量异常、stale outer 或优选过程故障 |

## 故障排查

```bash
# 查看服务日志
journalctl -u gost-mtcp-jp.service -n 100
journalctl -u gost-mtcp-jp-watchdog.service -n 100

# 查看状态
cat /opt/gost-mtcp/cn/state/status.json | jq

# 查看事件历史
tail -n 50 /opt/gost-mtcp/cn/state/events.jsonl

# 检查 Remote 连通性
timeout 2 bash -c "exec 3<>/dev/tcp/<REMOTE_IP>/6600" && echo "OK" || echo "FAIL"

# 检查当前 MTCP 数据面（替换实际 Anchor 端口）
timeout 3 bash -c '
exec 3<>/dev/tcp/127.0.0.1/12001 || exit 1
printf P >&3
IFS= read -r -n 1 reply <&3 || exit 1
[[ "$reply" == P ]]
' && echo "MTCP DATA OK" || echo "MTCP DATA FAIL"
```

## 工作原理

v2.2 采用 **Prewarm + Anchor + Watchdog** 三层架构：

- **Prewarm** - 启动时建立候选 outer，读取 TCP `minrtt`，慢路淘汰并重抽直到抽中快路
- **Anchor** - 在选中路径上保持轻量 logical stream，避免空闲时 outer 消失
- **Watchdog** - 监控 GOST PID、outer 数量、Anchor、Remote 可达性和实际数据面，明确故障后自动重新优选

设计原则：
- 新 outer 用 `minrtt` 判断基础路径
- 运行中的 current RTT 只用于状态和告警，不因瞬时拥塞直接踢掉当前连接
- Remote 不可达时安静等待，不循环重启
- TCP `ESTAB` 不等于数据面健康，实际 payload echo 才是 MTCP 可用性的判据
- 始终维持唯一一条 MTCP outer TCP

详细设计背景见 `DESIGN-archive.md`。

## 目录结构

```
9929-gost-mtcp/
├── standalone-install.sh      # 单文件自包含安装器
├── install.sh                  # 传统安装器（需要完整项目）
├── cn/                         # CN 端配置和脚本
│   ├── cn.yaml
│   ├── mtcp.conf
│   ├── mtcp-lib.sh
│   ├── mtcp-prewarm.sh
│   ├── mtcp-watchdog.sh
│   └── *.service
└── remote/                     # Remote 端配置
    ├── remote.yaml
    └── *.service
```

## 许可证

MIT
