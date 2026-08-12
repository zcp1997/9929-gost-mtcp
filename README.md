# 9929-gost-mtcp

GOST MTCP ECMP 低延迟路径优选与故障自愈方案，当前版本为 **v1**。

核心目标：

- 启动时从 ECMP 路径中优选低延迟 outer TCP；
- 通过 Anchor 保持唯一的 MTCP outer 长期存活；
- 通过 Watchdog 监控 GOST、outer、Anchor 和远端状态；
- 发生明确故障后重新选路，不因为瞬时 RTT 波动盲目踢掉当前连接。

## 工作原理

```text
业务客户端
    │
    ▼
CN GOST :12000
    │
    ├── 业务 logical streams
    └── Anchor logical stream :12001
            │
            ▼
     唯一 MTCP outer TCP
            │
            ▼
JP GOST :11000
            │
            ▼
       后端 TCP 服务
```

三个组件分工：

- **Prewarm**：建立候选 outer，读取 `minrtt`，淘汰慢路；
- **Anchor**：保持一个轻量 logical stream，锁住已经优选的 outer；
- **Watchdog**：监控状态，在 outer 消失、GOST PID 变化或远端恢复后触发重新优选。

## 目录结构

项目只分为 CN 和 JP 两个部署目录：

```text
9929-gost-mtcp/
├── README.md
├── README-quickstart.txt
├── DESIGN-archive.md
├── cn/
│   ├── cn.yaml
│   ├── mtcp.conf
│   ├── mtcp-lib.sh
│   ├── mtcp-prewarm.sh
│   ├── mtcp-watchdog.sh
│   ├── cleanup-old-versions.sh
│   ├── install.sh
│   ├── 9929-gost-mtcp.service
│   ├── 9929-gost-mtcp-anchor.service
│   ├── 9929-gost-mtcp-watchdog.service
│   └── state/
└── jp/
    ├── jp.yaml
    ├── install.sh
    ├── 9929-gost-mtcp-jp.service
    └── 9929-gost-mtcp-anchor-endpoint.service
```

- `cn/`：CN 端 GOST、ECMP 优选、Anchor、Watchdog 及其配置；
- `jp/`：JP 端 GOST MTCP Relay、Anchor endpoint 及其配置；
- `cn/state/`：运行时状态目录，不提交状态文件和日志；
- `DESIGN-archive.md`：原始方案讨论归档，当前部署以本 README 和代码为准。

## 部署前提

- CN、JP 均为 Linux + systemd；
- 安装脚本可访问 GitHub，并具备 `curl`、`tar` 和 SHA-256 校验命令；
- JP 端安装 `socat`；
- CN 端能够访问 JP 的 MTCP 监听端口；
- 将整个项目部署到两台机器的同一路径：

```text
/root/9929-gost-mtcp/
```

安装脚本会从 GOST 官方 GitHub Release 下载对应 Linux 架构的二进制，校验 `checksums.txt` 后安装到对应部署目录。默认固定使用已验证的 `v3.2.6`；也可以显式指定其他 Release：

```bash
GOST_VERSION=v3.2.6 bash install.sh
```

CN、JP 端分别执行各自目录下的 `install.sh` 即可，不再依赖机器上已有的手工 GOST 文件。每次运行安装脚本都会从 GitHub 下载并校验目标版本，然后覆盖对应部署目录中的 `gost`。

## CN 端配置与安装

安装前准备：

```text
cn/cn.yaml
cn/mtcp.conf
```

执行 `cn/install.sh` 时，脚本会交互引导输入 JP 端远端 IPv4 地址和 MTCP 端口。端口直接回车时默认使用 `11000`；输入完成后，脚本会同步更新 `cn/cn.yaml` 和 `cn/mtcp.conf`。

安装前仍需确认：

- 业务入口端口；
- 本机 Anchor 入口 `127.0.0.1:12001`；
- 本机能够访问 JP 的 MTCP 地址和端口；
- 后端 TCP 服务地址；
- `ACCEPT_RTT_MS` 等优选和恢复参数。

安装并启动：

```bash
cd /root/9929-gost-mtcp/cn
bash install.sh
systemctl enable --now 9929-gost-mtcp.service
systemctl enable --now 9929-gost-mtcp-watchdog.service
```

**不要手动 enable `9929-gost-mtcp-anchor.service`。**

Anchor 必须由 Prewarm/Watchdog 控制，否则可能在完成 ECMP 优选前抢先建立 outer，把慢路固定下来。

## JP 端配置与安装

先修改：

```text
jp/jp.yaml
```

JP GOST 默认只监听 MTCP Relay；Anchor endpoint 只绑定本机回环地址。

安装并启动：

```bash
cd /root/9929-gost-mtcp/jp
bash install.sh
```

检查 JP 端：

```bash
systemctl status 9929-gost-mtcp-jp.service --no-pager
systemctl status 9929-gost-mtcp-anchor-endpoint.service --no-pager
ss -lntp | grep -E ':11000|:12346'
```

## 运行状态

正常状态应接近：

```text
state=FAST
outer_count=1
minrtt < ACCEPT_RTT_MS
anchor_state=up
anchor_connections=1
```

查看状态和事件：

```bash
python3 -m json.tool < /root/9929-gost-mtcp/cn/state/status.json
tail -f /root/9929-gost-mtcp/cn/state/events.jsonl
ss -tin state established "dst <JP_IP> dport = :11000"
```

主要状态：

- `FAST`：唯一 outer、Anchor 正常、路径满足准入阈值；
- `DEGRADED`：仍尽量保留现有连接，等待线路稳定；
- `DOWN`：outer 消失或远端不可达，等待远端恢复；
- `FAULT`：outer 数量异常，说明单 outer 模型被破坏，需要进一步检查。

## 关键原则

- 新 outer 用 `minrtt` 判断是否为快路；
- 运行期间的 current RTT 只用于健康度告警；
- 瞬时拥塞不会直接触发 `ss -K`；
- JP 不可达时不循环重启、不疯狂抽卡，恢复后再重新优选；
- outer 真正断开后，当前业务 TCP 无法无缝迁移，只能等待客户端重连；
- Anchor endpoint 不承载业务，只负责维持 MTCP session。

## 校验

本机只做静态校验，不在 macOS 上执行 systemd 安装流程：

```bash
bash -n cn/*.sh
bash -n jp/install.sh
```

远端部署后建议分别检查：

```bash
systemctl status 9929-gost-mtcp.service --no-pager
systemctl status 9929-gost-mtcp-watchdog.service --no-pager
systemctl status 9929-gost-mtcp-jp.service --no-pager
```
