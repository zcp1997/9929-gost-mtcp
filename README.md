# 9929-gost-mtcp

基于 GOST MTCP 的 ECMP 低延迟路径优选与故障自愈方案。

> **唯一安装入口是项目根目录的 `install.sh`。**
>
> 同一份完整项目分别放到 CN 和 Remote 服务器，先执行 `bash install.sh remote`，再执行 `bash install.sh cn`。不要进入 `cn/` 或 `remote/` 寻找安装脚本。

## 一、先看懂两台服务器的角色

| 角色 | 部署位置 | 作用 | 安装命令 |
| --- | --- | --- | --- |
| **Remote** | 韩国、美国等境外服务器 | 监听 MTCP，接收 CN 连接并访问最终后端 | `bash install.sh remote` |
| **CN** | 中国大陆服务器 | 接收业务连接、连接 Remote、优选低延迟路径 | `bash install.sh cn` |

正确安装顺序：

```text
1. 安装 Remote
2. 记录 Remote 的公网 IPv4 和 MTCP 端口
3. 安装 CN
4. 在 CN 配置最终业务后端
5. 启动 CN 主服务和 Watchdog
```

数据链路：

```text
业务客户端
    │
    ▼
CN 业务端口（默认 :12000）
    │
    ▼
唯一一条经过优选的 MTCP outer TCP
    │
    ▼
Remote MTCP 端口（默认 :6600）
    │
    ▼
最终 TCP 后端（模板默认 127.0.0.1:2345）
```

## 二、安装前准备

### 1. 系统要求

- Linux，且使用 systemd；
- root 权限；
- CN 能访问 `ghfast.top`，Remote 能访问 GitHub Release；
- 当前只支持填写 Remote 的 **IPv4 地址**，不支持域名或 IPv6；
- Remote 防火墙或安全组能按来源 IP 放行 MTCP 端口。

安装器只检查依赖，不会自动安装系统软件包。

两端通用命令：

```text
bash curl tar awk grep install mktemp systemctl
sha256sum 或 shasum
```

CN 额外需要：

```text
ss       # Debian/Ubuntu 通常由 iproute2 提供
flock    # 通常由 util-linux 提供
timeout  # 通常由 coreutils 提供
```

Remote 额外需要：

```text
socat
```

Debian/Ubuntu 可以按角色准备依赖：

```bash
# 两端通用
apt-get update
apt-get install -y git bash curl tar coreutils grep gawk

# 只在 CN 安装
apt-get install -y iproute2 util-linux

# 只在 Remote 安装
apt-get install -y socat
```

### 2. 在两台服务器上下载完整项目

#### CN：中国大陆服务器通过 ghfast.top

```bash
sudo -i
cd /root
git clone https://ghfast.top/https://github.com/zcp1997/9929-gost-mtcp.git
cd /root/9929-gost-mtcp
```

CN 更新项目：

```bash
cd /root/9929-gost-mtcp
git pull --ff-only
```

克隆后的 `origin` 已经是 ghfast 地址，因此后续 `git pull` 也会继续走镜像。

> ghfast 的正确格式是 `https://ghfast.top/https://github.com/...`。
>
> `https://ghfast.top/http://github.com/...` 当前会返回 `403`，不要使用少一个 `s` 的写法。

#### Remote：境外服务器直连 GitHub

```bash
sudo -i
cd /root
git clone https://github.com/zcp1997/9929-gost-mtcp.git
cd /root/9929-gost-mtcp
```

Remote 更新项目同样执行：

```bash
cd /root/9929-gost-mtcp
git pull --ff-only
```

安装器会根据项目当前的绝对路径生成 systemd unit，因此：

- 项目不强制放在 `/root/9929-gost-mtcp`，但推荐使用该路径；
- **安装后不要移动、重命名或删除项目目录**，否则 systemd 中的路径会失效；
- 两台服务器都要保留完整项目，不要只复制某个角色目录。

## 三、第一步：安装 Remote

在境外 Remote 服务器执行：

```bash
cd /root/9929-gost-mtcp
bash install.sh remote
```

安装器只询问一个值：

```text
请输入 Remote 端 MTCP 监听端口 [6600]:
```

- 直接回车：使用 `6600/tcp`；
- 输入其他端口：使用自定义端口；
- `12346` 不可使用，它固定留给本机 Anchor endpoint；
- 记住最终端口，安装 CN 时需要填写。

Remote 安装器会自动完成：

1. 检查依赖；
2. 更新 `remote/remote.yaml` 中的监听端口；
3. 从 GOST 官方 GitHub Release 下载默认版本 `v3.2.6`；
4. 根据官方 `checksums.txt` 校验二进制；
5. 将 systemd unit 写入 `/etc/systemd/system/`；
6. enable 并 restart 以下服务：

```text
9929-gost-mtcp-remote.service
9929-gost-mtcp-remote-anchor-endpoint.service
```

安装后检查：

```bash
systemctl status 9929-gost-mtcp-remote.service --no-pager
systemctl status 9929-gost-mtcp-remote-anchor-endpoint.service --no-pager
ss -lntp | grep -E ':6600|:12346'
```

使用自定义 MTCP 端口时，把检查命令中的 `6600` 换成实际端口。正常情况下：

- MTCP 端口监听在 `0.0.0.0`/`[::]`；
- Anchor endpoint `12346/tcp` 只监听 `127.0.0.1`。

### Remote 必须设置防火墙

Remote 的 MTCP Relay 没有配置应用层认证。**不要把 MTCP 端口无条件开放给整个互联网**，应在云安全组或主机防火墙中只允许 CN 的公网源 IPv4 访问。

以 UFW 和默认端口为例：

```bash
ufw allow from <CN_PUBLIC_IP> to any port 6600 proto tcp
```

不要对公网开放 `12346/tcp`；它只应在 Remote 本机回环地址使用。

完成后记录：

```text
Remote 公网 IPv4：________________
Remote MTCP 端口：________________
```

## 四、第二步：安装 CN

在中国大陆 CN 服务器执行：

```bash
cd /root/9929-gost-mtcp
bash install.sh cn
```

安装器会依次询问：

| 输入项 | 示例 | 说明 |
| --- | --- | --- |
| Remote 线路别名 | `kr` | 推荐填写；用于区分多条线路 |
| Remote IPv4 | `203.0.113.10` | 填写真实 Remote 公网 IPv4 |
| Remote MTCP 端口 | `6600` | 必须和 Remote 安装时一致 |
| CN 业务监听端口 | `12000` | 业务客户端连接 CN 的端口 |
| CN Anchor 监听端口 | `12001` | 只监听 `127.0.0.1`，每条线路必须不同 |

`203.0.113.10` 是文档示例地址，部署时不能照抄。

### 线路别名怎么填

即使只有一条线路，也推荐填写简单别名，例如 `kr`、`us` 或 `remote1`：

```text
请输入 Remote 节点别名（如 kr、us，直接回车使用默认线路）: kr
```

使用别名的优点：

- 配置、状态和 systemd unit 都按线路隔离；
- 后续可以继续添加其他 Remote；
- 真实 Remote IP 会写入已被 `.gitignore` 排除的 `cn/instances/`，降低误提交生产地址的风险。

别名只能使用字母、数字、下划线和连字符，最长 32 个字符，且不能使用 Anchor/Watchdog 的保留后缀。

#### 填写别名，例如 `kr`

会生成：

```text
配置：cn/instances/kr/cn.yaml
参数：cn/instances/kr/mtcp.conf
状态：cn/instances/kr/state/

服务：9929-gost-mtcp-kr.service
Anchor：9929-gost-mtcp-kr-anchor.service
Watchdog：9929-gost-mtcp-kr-watchdog.service
```

#### 别名直接回车

会使用默认线路：

```text
配置：cn/cn.yaml
参数：cn/mtcp.conf
状态：cn/state/

服务：9929-gost-mtcp.service
Anchor：9929-gost-mtcp-anchor.service
Watchdog：9929-gost-mtcp-watchdog.service
```

默认线路会直接改写 Git 已跟踪的 `cn/cn.yaml` 和 `cn/mtcp.conf`。不要把其中的真实服务器地址误提交到公开仓库。

### CN 安装器具体做什么

CN 安装器会：

1. 检查输入格式及已配置线路的端口冲突；
2. 写入 Remote IPv4、Remote 端口、业务端口和 Anchor 端口；
3. 默认通过 `ghfast.top` 下载并校验 GOST；
4. 为当前线路生成独立的 systemd unit；
5. 执行 `systemctl daemon-reload`；
6. 打印当前线路准确的启动命令。

**CN 安装完成后不会自动启动服务。** 这是故意的，因为启动前还必须确认最终业务后端和 RTT 阈值。

## 五、第三步：启动 CN 前配置业务后端

安装器不会询问最终后端地址，模板默认值为：

```yaml
forwarder:
  nodes:
  - name: backend
    addr: 127.0.0.1:2345
```

这个地址表示：**由 Remote 去连接的最终 TCP 目标**。

- 后端就在 Remote 本机：可以填写 `127.0.0.1:<PORT>`；
- 后端在 Remote 能访问的其他机器：填写该机器的 IP 和端口；
- 它不是 CN 本机的后端地址。

如果线路别名是 `kr`：

```bash
nano /root/9929-gost-mtcp/cn/instances/kr/cn.yaml
```

如果使用默认线路：

```bash
nano /root/9929-gost-mtcp/cn/cn.yaml
```

找到 `name: backend`，将 `addr` 改成实际目标，例如：

```yaml
- name: backend
  addr: 127.0.0.1:8080
```

还应检查 Watchdog 的快路准入阈值：

```bash
# 别名线路
nano /root/9929-gost-mtcp/cn/instances/kr/mtcp.conf

# 默认线路
nano /root/9929-gost-mtcp/cn/mtcp.conf
```

核心参数：

```bash
ACCEPT_RTT_MS="40"
```

含义是新 MTCP outer 的 `minrtt` 必须小于该值才进入 `FAST`。不同线路的快慢档位不同，应按实际测试调整，不要盲目照抄 `40ms`。

## 六、第四步：启动 CN

安装器结束时会打印当前线路的准确命令，优先复制它打印的内容。

别名为 `kr` 时：

```bash
systemctl enable --now 9929-gost-mtcp-kr.service
systemctl enable --now 9929-gost-mtcp-kr-watchdog.service
```

使用默认线路时：

```bash
systemctl enable --now 9929-gost-mtcp.service
systemctl enable --now 9929-gost-mtcp-watchdog.service
```

> **不要 enable 或手动常驻启动 Anchor unit。**
>
> Anchor 必须由 Prewarm/Watchdog 控制。提前启动可能随机建立并锁住一条未经优选的慢路。

根据业务需要，在 CN 防火墙或安全组中放行业务监听端口（默认 `12000/tcp`）。Anchor 端口默认 `12001/tcp`，只监听 `127.0.0.1`，不需要对外开放。

## 七、验证安装结果

### 1. 检查 Remote

```bash
systemctl is-active 9929-gost-mtcp-remote.service
systemctl is-active 9929-gost-mtcp-remote-anchor-endpoint.service
ss -lntp | grep -E ':6600|:12346'
```

### 2. 检查 CN 别名线路 `kr`

```bash
systemctl status 9929-gost-mtcp-kr.service --no-pager
systemctl status 9929-gost-mtcp-kr-watchdog.service --no-pager
cat /root/9929-gost-mtcp/cn/instances/kr/state/status.json
tail -n 30 /root/9929-gost-mtcp/cn/instances/kr/state/events.jsonl
```

### 3. 检查 CN 默认线路

```bash
systemctl status 9929-gost-mtcp.service --no-pager
systemctl status 9929-gost-mtcp-watchdog.service --no-pager
cat /root/9929-gost-mtcp/cn/state/status.json
tail -n 30 /root/9929-gost-mtcp/cn/state/events.jsonl
```

正常状态应接近：

```text
state = FAST
outer_count = 1
minrtt_ms < ACCEPT_RTT_MS
anchor_state = up
anchor_connections = 1
```

状态含义：

| 状态 | 含义 |
| --- | --- |
| `FAST` | 唯一 outer、Anchor 正常且路径满足准入阈值 |
| `DEGRADED` | 当前连接可用，但路径、Anchor 或 TCP 信息未达到快速状态 |
| `DOWN` | GOST、outer 或 Remote 不可用 |
| `FAULT` | outer 数量异常或优选过程发生明确故障 |

查看 CN 到 Remote 的 outer（替换实际地址和端口）：

```bash
ss -tin state established "dst <REMOTE_IP> dport = :6600"
```

正常模型应只有一条有效的 MTCP outer TCP。

## 八、使用交互角色菜单

不带参数执行也可以：

```bash
bash install.sh
```

菜单会询问“当前这台服务器”承担哪个角色：

```text
1) CN      中国大陆入口端
2) Remote  境外中转端
q) 退出
```

直接指定角色更适合照文档部署：

```bash
bash install.sh remote
bash install.sh cn
```

查看帮助不需要 root：

```bash
bash install.sh --help
```

指定其他 GOST 版本：

```bash
GOST_VERSION=v3.2.6 bash install.sh remote
GOST_VERSION=v3.2.6 bash install.sh cn
```

安装器会按照版本号构造官方 Release 文件名；使用其他版本前请自行确认兼容性。

### GitHub 下载镜像规则

- CN 安装默认使用：

  ```text
  https://ghfast.top/https://github.com/go-gost/gost/releases/...
  ```

- Remote 安装默认直连 GitHub；
- 下载的压缩包仍会和同一来源的 `checksums.txt` 做 SHA-256 校验；
- CN 临时强制直连 GitHub：

  ```bash
  GITHUB_PROXY_PREFIX= bash install.sh cn
  ```

- Remote 也需要通过 ghfast 下载时：

  ```bash
  GITHUB_PROXY_PREFIX=https://ghfast.top/ bash install.sh remote
  ```

- 使用其他兼容镜像前缀时：

  ```bash
  GITHUB_PROXY_PREFIX=https://your-mirror.example/ bash install.sh cn
  ```

镜像前缀必须采用“前缀 + 完整上游 HTTPS URL”的形式。

## 九、添加多个 Remote

同一台 CN 可以连接多个 Remote。每增加一条线路，再执行一次：

```bash
bash install.sh cn
```

为每条线路填写不同别名和不同的 CN 本地端口，例如：

| 别名 | Remote | CN 业务端口 | CN Anchor 端口 |
| --- | --- | ---: | ---: |
| `kr` | 韩国 Remote | `12000` | `12001` |
| `us` | 美国 Remote | `12002` | `12003` |

安装器会检查已生成线路之间的业务端口和 Anchor 端口冲突。每条线路都有独立配置、状态、运行锁和三个 systemd unit，但共享 `cn/gost` 二进制。

## 十、重装与升级

### 重装 Remote

重新执行：

```bash
bash install.sh remote
```

安装器会重新下载 GOST、生成 unit，并 restart Remote 服务。现有 MTCP 连接会短暂中断。

### 重装某条 CN 线路

如果线路仍在运行，安装器会拒绝修改配置。先停止该线路的 Watchdog、Anchor 和主服务，再使用同一个别名重装。

以 `kr` 为例：

```bash
systemctl stop \
  9929-gost-mtcp-kr-watchdog.service \
  9929-gost-mtcp-kr-anchor.service \
  9929-gost-mtcp-kr.service

bash install.sh cn
# 再次输入别名 kr
```

安装器会复用已有线路配置，保留未参与交互的后端地址和 RTT 参数。

### 更新项目代码

```bash
cd /root/9929-gost-mtcp
git status
git pull --ff-only
```

如果 CN 最初是从 GitHub 直连地址克隆的，可以将远端改为 ghfast：

```bash
git remote set-url origin https://ghfast.top/https://github.com/zcp1997/9929-gost-mtcp.git
git pull --ff-only
```

先确认没有准备提交的本地生产配置。拉取代码后，对需要更新的角色重新运行根目录 `install.sh`。

## 十一、工作原理

本项目由三个 CN 侧组件配合：

- **Prewarm**：建立候选 outer，读取 TCP `minrtt`，慢路会被淘汰并重抽；
- **Anchor**：在选中路径上保持轻量 logical stream，避免空闲时 outer 消失；
- **Watchdog**：监控 GOST PID、outer 数量、Anchor 和 Remote 可达性，在明确故障恢复后重新优选。

设计原则：

- 新 outer 使用 `minrtt` 判断基础路径；
- 运行中的 current RTT 只用于状态和告警，不因瞬时拥塞直接踢掉当前连接；
- Remote 不可达时安静等待，不循环重启和刷日志；
- 始终尽量维持唯一一条 MTCP outer TCP；
- outer 真正断开、GOST 被强制终止或 Remote 失联时，已有业务 TCP 无法无缝迁移，只能等待客户端重新连接。

MTCP 默认参数位于 `cn/cn.yaml` 和 `remote/remote.yaml`：

```text
mux.version: 2
mux.keepaliveInterval: 10s
mux.keepaliveTimeout: 30s
mux.maxFrameSize: 32768
mux.maxReceiveBuffer: 33554432
mux.maxStreamBuffer: 4194304
```

## 十二、目录结构

```text
9929-gost-mtcp/
├── install.sh                         # 唯一安装入口
├── README.md
├── README-quickstart.txt
├── DESIGN-archive.md                  # 历史设计讨论，不是部署指南
├── cn/
│   ├── cn.yaml                        # CN 默认线路模板/配置
│   ├── mtcp.conf                      # Watchdog 默认参数
│   ├── mtcp-lib.sh
│   ├── mtcp-prewarm.sh
│   ├── mtcp-watchdog.sh
│   ├── 9929-gost-mtcp.service
│   ├── 9929-gost-mtcp-anchor.service
│   ├── 9929-gost-mtcp-watchdog.service
│   ├── instances/                     # 别名线路安装后自动生成
│   │   └── <alias>/
│   │       ├── cn.yaml
│   │       ├── mtcp.conf
│   │       └── state/
│   └── state/                         # 默认线路状态
└── remote/
    ├── remote.yaml
    ├── 9929-gost-mtcp-remote.service
    └── 9929-gost-mtcp-remote-anchor-endpoint.service
```

本地开发校验：

```bash
bash -n install.sh cn/*.sh
shellcheck -x install.sh cn/*.sh
```

更早期的设计背景和故障测试记录见 `DESIGN-archive.md`；实际安装与运维以本 README 和当前代码为准。
