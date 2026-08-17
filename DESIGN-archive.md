# gost-ecmp-pathlock：原始方案讨论归档

v1 主要解决的是一个问题：

> GOST MTCP 启动时如果碰到 ECMP，让脚本不断重建 outer TCP，直到抽到低延迟路径，然后后续业务长期复用这一条连接。

v1 实际跑下来效果很好，但它本质上还是“**启动预热**”。继续折腾了一轮后，我把几个实际运行问题补齐了：

- 没业务时，MTCP outer 可能因为没有 logical stream 而消失；
- outer 被 RST / `ss -K` / TCP 超时弄掉后，希望自动重新优选；
- GOST 自己 crash / restart 后，希望自动重新优选；
- 日本机器或 `:6600` 黑洞一段时间后，希望不要疯狂 restart，恢复后再重新优选；
- 当前 RTT 因拥塞、DDoS、排队临时飙高时，不希望 watchdog 误杀一条本来就在快路上的连接；
- 运行态应该始终尽量保持 **唯一一条 MTCP outer TCP**。

最后整理成现在这个 **v2.2：Prewarm + Anchor + Watchdog**。

---

## 0. 实测结果

这条线路 TCP ECMP 依然很明显：

```text
快路：约 32~34ms
慢路：约 50~52ms
```

准入阈值继续设：

```text
ACCEPT_RTT_MS=40
```

实测几次故障恢复：

```text
outer 被强制 kill：
51.546ms → reject
33.286ms → accept

GOST kill -9 后：
51.305ms → reject
33.147ms → accept

Remote :6600 临时 DROP，恢复后：
33.525ms → accept
```

正常运行时：

```text
outer_count = 1
sport 长期不变
minrtt ≈ 33ms
```

也就是说，v2 的目标不是“让所有 TCP 都变成 33ms”，而是：

> **选出一条 33ms 的 outer TCP，然后让所有业务长期复用它；这条 outer 真没了，再自动重新抽。**

---

## 1. 问题背景

这个问题和 v1 一样。

部分跨境 / 跨运营商线路存在明显 ECMP：ICMP `ping` 看着很稳定，但不同 TCP 五元组可能被 hash 到不同路径。

例如：

```text
TCP A → 33ms
TCP B → 51ms
TCP C → 33ms
TCP D → 51ms
```

普通 TCP 转发下，每个业务连接都会重新参与一次 ECMP：

```text
业务 TCP 1 → 跨境 TCP 1 → 抽一次
业务 TCP 2 → 跨境 TCP 2 → 再抽一次
业务 TCP 3 → 跨境 TCP 3 → 再抽一次
```

GOST MTCP 则可以变成：

```text
业务 TCP 1 ┐
业务 TCP 2 ├── logical streams ──→ 单条 MTCP outer TCP → Remote
业务 TCP 3 ┘
```

所以 ECMP 从：

```text
每个业务 TCP 都抽一次
```

收敛成：

```text
MTCP outer 建立时抽一次
```

这也是为什么我一直坚持 **单 MTCP session / 单 outer TCP**，而不是运行期间同时维护很多条 session 去竞速。

---

## 2. v2.2 的整体思路

v2.2 拆成三块：

```text
Prewarm   负责选路
Anchor    负责锁路
Watchdog  负责监控和自愈
```

整体链路：

```text
任意 TCP 客户端
      ↓
CN GOST :12000
      ↓
多个 logical stream
      ↓
唯一 MTCP outer TCP
      ↓
Remote GOST :6600
      ↓
目标 TCP 服务
```

同时额外有一条很轻的 Anchor logical stream：

```text
CN 127.0.0.1:12001
      ↓
同一个 MTCP session
      ↓
Remote 127.0.0.1:12346
```

最终就是：

```text
业务 stream  ┐
业务 stream  ├─→ 同一个 MTCP outer TCP
Anchor stream┘
```

Anchor 不承载实际业务，它只是故意让 MTCP session 里永远至少有一个 stream 活着。

---

## 3. 为什么 v2 要增加 Anchor

v1 有个隐藏问题：

启动预热虽然能抽到快路，但如果一段时间完全没有业务 logical stream，GOST MTCP 的 outer 不一定会永久存在。

如果 outer 空闲后消失，下次真实业务到来：

```text
重新建立 outer
    ↓
重新参与 ECMP
    ↓
又可能抽到 51ms
```

于是 v2 增加一个 **Anchor Stream（锚定连接）**。

它的作用不是测速，也不是转发实际业务，而是：

> **维持一个长期存在的 logical stream，把已经优选好的 outer TCP 锚住。**

CN 增加一个只监听本机的入口：

```yaml
- name: mtcp-anchor
  addr: 127.0.0.1:12001
  handler:
    type: tcp
    chain: chain-mtcp
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: anchor
      addr: 127.0.0.1:12346
```

Remote 提供一个简单的 TCP endpoint：

```bash
socat -d -d \
  TCP-LISTEN:12346,bind=127.0.0.1,reuseaddr,fork \
  EXEC:/bin/cat
```

### 一个踩坑：不要为了 Anchor 改 Relay 的全局行为

我中间试过给共享 Relay connector 开 `nodelay`，Anchor 的确容易保持了，但真实业务反而出现 TCP 已连接、HTTP 一直等不到响应的情况。

最后的处理方式是：

> **业务数据面保持原来的 Relay 配置不动，让 Anchor 自己主动发送 1 Byte 触发首包。**

Anchor service 的核心实际就是：

```bash
exec 3<>/dev/tcp/127.0.0.1/12001
printf "A" >&3
exec cat <&3 >/dev/null
```

这样既能触发 Relay 建立远端目标，又不会改变正常业务链路的行为。

---

## 4. GOST MTCP 参数

MTCP 缓冲区继续沿用 v1 调过的参数：

```yaml
mux.version: 2
mux.keepaliveDisabled: false
mux.keepaliveInterval: 10s
mux.keepaliveTimeout: 30s
mux.maxFrameSize: 32768
mux.maxReceiveBuffer: 33554432
mux.maxStreamBuffer: 4194304
```

对应：

```text
Frame Size      32 KiB
Receive Buffer  32 MiB
Stream Buffer    4 MiB
```

之前单 stream 缓冲区小的时候，MTCP 吞吐会明显被卡住；4 MiB 对我这个约 33ms、几百 Mbps 的链路比较合适。

---

## 5. CN 端 GOST 配置

示例公网地址继续用文档地址：

```text
Remote：example.invalid:6600
业务入口：:12000
Anchor：127.0.0.1:12001
后端 TCP：127.0.0.1:2345
```

配置：

```yaml
services:
- name: tcp-entry
  addr: :12000
  handler:
    type: tcp
    chain: chain-mtcp
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: backend
      addr: 127.0.0.1:2345

- name: mtcp-anchor
  addr: 127.0.0.1:12001
  handler:
    type: tcp
    chain: chain-mtcp
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: anchor
      addr: 127.0.0.1:12346

chains:
- name: chain-mtcp
  hops:
  - name: remote
    nodes:
    - name: remote-mtcp
      addr: example.invalid:6600
      connector:
        type: relay
      dialer:
        type: mtcp
        metadata:
          mux.version: 2
          mux.keepaliveDisabled: false
          mux.keepaliveInterval: 10s
          mux.keepaliveTimeout: 30s
          mux.maxFrameSize: 32768
          mux.maxReceiveBuffer: 33554432
          mux.maxStreamBuffer: 4194304
```

注意这里两个 service 引用的是同一个 `chain-mtcp`。

实际验证时：

```bash
ss -ntH "dst example.invalid:6600" | grep -c '^ESTAB'
```

正常始终应该是：

```text
1
```

---

## 6. Prewarm v2：Anchor 本身就是候选连接

v1 的方式大概是：

```text
短连接触发 outer
  ↓
检测
  ↓
成功
  ↓
短连接关闭
```

然后再想办法让最终业务接上去。

v2.2 改成：

```text
启动 Anchor
  ↓
Anchor 直接创建候选 outer
  ↓
检测 minrtt
  ├─ 快：Anchor 原地留下
  └─ 慢：stop Anchor → kill outer → 重新 start Anchor
```

这样最大的好处是：

> **抽中的那一条 outer，就是最后真正被 Anchor 保留下来的那一条。**

没有“预热成功后再交接”的空窗。

核心判断：

```text
minrtt < 40ms
    ↓
FAST
    ↓
Anchor 原地保留

minrtt >= 40ms
    ↓
PREWARM_REJECT_SLOW
    ↓
stop Anchor
    ↓
kill 唯一慢 outer
    ↓
Anchor 建下一候选
```

如果抽到：

```text
51ms → reject
51ms → reject
33ms → accept
```

最终只留下 33ms 那条。

---

## 7. 为什么判断用 `minrtt`，运行监控又看 current `rtt`

新连接准入时，我继续用：

```bash
ss -tin "dst example.invalid:6600"
```

重点看：

```text
minrtt:
```

原因和 v1 一样：

- 当前 `rtt` 会受队列、重传、ACK、瞬时拥塞影响；
- `minrtt` 更适合判断这条 TCP 一开始到底 hash 到哪档基础路径。

但是运行期间 current RTT 依然有监控价值。

所以 v2.2 分开处理：

```text
minrtt
→ 新 session 是否允许进入 FAST

current rtt
→ 运行期健康度 / 拥塞告警
```

默认配置例如：

```bash
ACCEPT_RTT_MS="40"

LIVE_RTT_WARN_MS="120"
LIVE_RTT_CRIT_MS="250"
LIVE_RTT_WARN_HOLD_SEC="30"
LIVE_RTT_CRIT_HOLD_SEC="120"
LIVE_RTT_RECOVER_MS="80"
LIVE_RTT_RECOVER_HOLD_SEC="30"
```

这里有一个原则：

> **current RTT 飙高只告警，不因为瞬时高 RTT 主动 kill 当前 outer。**

比如原本：

```text
sport 没变
minrtt 还是 33ms
current rtt 临时变成 100~200ms
```

更可能是拥塞 / 丢包 / 排队问题，而不是 ECMP hash 突然变化。

如果这时候 watchdog 主动 `ss -K`，反而可能把一条本来不错的快路踢掉，再抽出一条 51ms。

---

## 8. Watchdog 状态机

v2.2 正常有几个状态：

```text
FAST
DEGRADED
DOWN
FAULT
```

### FAST

```text
outer_count = 1
Anchor 正常
minrtt < ACCEPT_RTT_MS
```

这种状态下：

```text
什么都不要碰
```

### DEGRADED

例如：

- Anchor 暂时掉了，但 outer 还在；
- 或线路整体退化，多次重抽都暂时达不到阈值。

此时原则是：

> **能继续用就先继续用，稳定性优先。**

### DOWN

例如：

```text
outer = 0
```

Watchdog 会进一步判断：

```text
Remote :6600 能连？
```

如果远端也挂了：

```text
DOWN / REMOTE
```

然后安静等待，不去疯狂 restart 本地 GOST。

### FAULT

例如：

```text
outer_count > 1
```

这已经不是“抽到慢路”，而是整个单 outer 运行模型被破坏。

Watchdog 会确认多次后再处理，不会随便猜哪一条该杀。

---

## 9. 远端掉线后怎么恢复

这是 v2 相比 v1 最重要的一块。

假设 Remote `:6600` 被 DROP：

```text
原 outer
   ↓
TCP / MTCP 超时
   ↓
OUTER_DISAPPEARED
   ↓
remote probe 失败
   ↓
REMOTE_TCP_DOWN
   ↓
DOWN / REMOTE
```

远端没恢复的时候：

```text
不循环 restart GOST
不循环抽卡
不刷一堆无意义日志
```

等 Remote 恢复：

```text
REMOTE_TCP_UP
    ↓
RECOVERY_SELECT
    ↓
重新启动 Anchor 候选
    ↓
重新检查 minrtt
    ↓
快路留下
    ↓
ANCHOR_BOUND
    ↓
FAST
```

也就是说：

> **远端恢复 ≠ 随便连回来就算了，而是恢复后重新做一次 ECMP 优选。**

---

## 10. 实际故障测试

这次基本把我能想到的情况都手工打了一遍。

### 10.1 Anchor endpoint 临时中断

Remote `12346` 手工停掉再恢复。

结果：

```text
Anchor logical stream 断
    ↓
Anchor service 重连
    ↓
原 MTCP outer sport 不变
```

说明：

> **Anchor 自己坏一下，不等于 outer 一定要换。**

---

### 10.2 手工 kill 当前 outer

```bash
ss -K dst example.invalid dport = :6600
```

一次测试日志大概是：

```text
OUTER_DISAPPEARED
REMOTE_UP

候选 1：51.546ms
PREWARM_REJECT_SLOW

候选 2：33.286ms
PREWARM_SUCCESS
ANCHOR_BOUND
```

最终：

```text
旧 sport 消失
新 sport 固定
outer_count = 1
```

---

### 10.3 `kill -9` GOST

```bash
PID=$(systemctl show gost-mtcp-remotev22.service -p MainPID --value)
kill -9 "$PID"
```

systemd 自动拉起来后：

```text
GOST_PID_CHANGED

候选 1：51.305ms
reject

候选 2：33.147ms
accept

ANCHOR_BOUND
```

最终恢复 FAST。

---

### 10.4 Remote `:6600` 做黑洞测试

Remote 用 nftables：

```bash
nft add table inet filter
nft add chain inet filter input '{ type filter hook input priority 0; }'
nft insert rule inet filter input tcp dport 6600 drop
```

这和直接 RST 不一样，`drop` 会更接近真实线路黑洞：现有 TCP 不会立即知道自己死了，而是经历重传 / timeout。

Watchdog 最终：

```text
OUTER_DISAPPEARED
REMOTE_TCP_DOWN
DOWN / REMOTE
```

删除规则恢复：

```bash
nft -a list chain inet filter input
nft delete rule inet filter input handle <handle>
```

随后自动：

```text
REMOTE_TCP_UP
RECOVERY_SELECT
PREWARM_SUCCESS 33.525ms
ANCHOR_BOUND
FAST
```

业务恢复正常。

---

## 11. systemd 结构

CN 最终有 3 个 unit：

```text
gost-mtcp-remotev22.service
gost-mtcp-remotev22-anchor.service
gost-mtcp-remotev22-watchdog.service
```

其中：

```text
gost-mtcp-remotev22.service
→ enable

gost-mtcp-remotev22-watchdog.service
→ enable

gost-mtcp-remotev22-anchor.service
→ 不要 enable
```

Anchor 故意只允许 Prewarm / Watchdog 控制。

否则如果 Anchor 在开机时抢先启动：

```text
还没优选
  ↓
先随机建立一个 outer
  ↓
刚好 51ms
  ↓
直接把慢路锚住
```

这就和设计目标相反了。

Remote 的 Anchor endpoint 建议也做成 systemd，不要靠一个 SSH 窗口里 `nohup socat`：

```ini
[Unit]
Description=GOST MTCP Anchor Endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:12346,bind=127.0.0.1,reuseaddr,fork EXEC:/bin/cat
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

---

## 12. 配置参数

核心配置全部单独放到：

```text
/root/mtcpremotev22/mtcp-remote.conf
```

Watchdog 每轮重新 `source`，所以很多阈值改完不需要重启 watchdog。

例如：

```bash
# 新 session 准入
ACCEPT_RTT_MS="40"

# 启动抽卡
PREWARM_MAX_DRAWS="12"

# outer / 远端故障恢复抽卡
RECOVERY_PREWARM_DRAWS="8"

# 线路整体退化时的维护重试
DEGRADED_RETRY_DRAWS="4"
DEGRADED_RETRY_SEC="900"

# watchdog
WATCH_INTERVAL_SEC="5"
REMOTE_PROBE_INTERVAL_SEC="15"
DOWN_RETRY_SEC="15"

# 日志保留 1 天
RETENTION_SEC="86400"
```

我不建议根据最近 RTT 自动学习并修改 `ACCEPT_RTT_MS`。

如果当天刚好 DDoS / 拥塞，自动学习很容易把事故状态学成“正常”。

阈值还是人工按线路的快慢档位设更稳。

---

## 13. 日志与状态

v2.2 会维护：

```text
state/status-v22.json
state/events-v22.jsonl
state/runtime-v22.state
```

查看状态：

```bash
cat /root/mtcpremotev22/state/status-v22.json | python3 -m json.tool
```

正常类似：

```json
{
  "state": "FAST",
  "reason": "PATH",
  "outer_count": 1,
  "sport": "65492",
  "minrtt_ms": "33.525",
  "remote_reachable": "yes",
  "anchor_state": "up",
  "anchor_connections": 1
}
```

查看事件：

```bash
tail -f /root/mtcpremotev22/state/events-v22.jsonl
```

事件只保留一天，并且最终版修了几个日志细节：

- REMOTE 已确认后，不再 `NO_OUTER ↔ REMOTE` 每轮来回刷；
- GOST PID 变化会保留真实 `old_pid`；
- Anchor restart 周期放宽，避免异常时疯狂刷日志。

---

## 14. 常用验证命令

看有效 outer：

```bash
ss -ntp "dst example.invalid:6600"
```

看 TCP 信息：

```bash
ss -tin "dst example.invalid:6600"
```

如果远端黑洞后旧连接还残留在：

```text
FIN-WAIT-1
```

不要把它当成有效 outer。

更准确可以只看：

```bash
ss -tin state established \
  "dst example.invalid dport = :6600"
```

正常模型永远是：

```text
ESTAB = 1
```

---

## 15. 一个必须接受的事实：hard failure 不可能让原 TCP 无缝续传

这里也说清楚一个边界。

如果：

```text
outer TCP 真死了
GOST 被 kill -9
远端机器真断了
```

那么当前正在承载的业务 TCP stream 不可能凭 watchdog “迁移”到新 outer 上继续原来的字节流。

Watchdog 能做到的是：

```text
尽快恢复新的 MTCP session
    ↓
重新优选快路
    ↓
重新 Anchor
    ↓
客户端下一次重连恢复
```

所以这套方案追求的是：

> **正常时期尽量不折腾；真正故障后快速、自动、按快路标准恢复。**

不是魔法意义上的 TCP 无损迁移。

---

## 16. 最终目录

```text
/root/mtcpremotev22/
├── cn.yaml
├── mtcp-remote.conf
├── mtcp-lib-v22.sh
├── mtcp-prewarm-v22.sh
├── mtcp-watchdog-v22.sh
├── gost-mtcp-remotev22.service
├── gost-mtcp-remotev22-anchor.service
├── gost-mtcp-remotev22-watchdog.service
├── install-v22-cn.sh
├── remote/
│   └── gost-mtcp-remotev22-anchor-endpoint.service
└── state/
    ├── runtime-v22.state
    ├── status-v22.json
    └── events-v22.jsonl
```

完整源码另外打包，不在帖子里再塞几百行 shell 了。

---

## 17. 总结

v1 的原则是：

> **启动阶段抽到一条快路，然后不要碰它。**

v2.2 在这个原则上继续补齐了生命周期管理：

```text
Prewarm：负责选路
Anchor：负责锁路
Watchdog：负责自愈
```

正常运行时：

```text
唯一 outer
sport 不变
minrtt 保持快路档位
```

真正故障时：

```text
检测故障
  ↓
判断远端
  ↓
远端没恢复就等待
  ↓
远端恢复后重新抽 ECMP
  ↓
慢路淘汰
  ↓
快路 Anchor
  ↓
恢复 FAST
```

我自己这边把：

- Anchor 中断；
- outer RST / `ss -K`；
- GOST `kill -9`；
- Remote `:6600` TCP 黑洞；
- 恢复后重新选路；
- RTT 临时波动；

基本都手工测过一遍了。

到 v2.2，我觉得这套方案可以先收工了。

本质仍然就是一句话：

> **用一条经过 ECMP 优选的长期 MTCP outer TCP 承载所有业务；正常时不打扰它，真正断了以后再自动重新抽一条快的。**
