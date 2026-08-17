# Watchdog 重启熔断与多业务端口统计方案

## 1. 背景与结论

当前版本已经实测覆盖两条恢复路径：

1. Remote 整体不可达：`OUTER_DISAPPEARED -> REMOTE_TCP_DOWN -> DOWN/REMOTE`，
   Remote 恢复后自动 `RECOVERY_SELECT -> PREWARM_SUCCESS -> FAST`。
2. TCP outer 仍为 `ESTAB`、但 MTCP 数据面失效：Data Probe 连续失败且
   Remote 新 TCP 可达时，确认 stale outer，重启 GOST 并重新 Prewarm。

下一阶段优先解决两个问题：

- P0：Data Probe 基础设施故障可能导致 `DATA_PLANE_STALE_OUTER` 周期性重启。
- P1：Watchdog 只统计 `BUSINESS_PORT`，无法正确识别其他 Relay 端口上的业务连接。

## 2. 现状评估

### 2.1 Data Probe 重启只有冷却，没有熔断

`restart_gost_rate_limited` 使用 `RESTART_COOLDOWN_SEC` 限制两次重启之间的时间，
但不限制长期累计次数。Remote echo endpoint 配置错误时，每条健康 outer 都会无法
完成 payload echo；Remote MTCP 端口又仍可建立新 TCP，于是会反复进入 stale outer
恢复路径。

此外，完整项目与 standalone 模板的默认值不一致：

- `cn/mtcp.conf`：`RESTART_COOLDOWN_SEC=300`
- standalone 内嵌配置：`RESTART_COOLDOWN_SEC=60`

### 2.2 多业务端口统计不完整

`get_business_conn_count()` 当前只执行：

```bash
ss -ntpH "sport = :${BUSINESS_PORT}"
```

当 12000 空闲而 12002 存在业务连接时，Watchdog 仍会得到
`business_connections=0`。这个值主要影响：

- `status.json` 的业务连接统计。
- 慢路径上的 `DEGRADED_IDLE_RETRY` 决策。

它不会直接触发 stale outer 重启，但可能在次要业务端口仍活跃时误判空闲并重新
Prewarm，导致现有连接中断。

### 2.3 其他边界

- Data Probe 是 transport probe，不检查实际业务 backend；backend 故障时保持
  `FAST/data_plane=yes` 是符合当前职责边界的。
- `remote_tcp=up` 只证明 Remote MTCP 端口接受 TCP，不证明 Remote GOST 的 MTCP
  协议和 echo endpoint 都健康。
- current RTT 长期升高只告警、不主动替换 outer，是保护存量连接的保守策略。
- hard failure 后旧 logical stream 无法无损迁移，Watchdog 恢复的是后续新连接。
- 一次 `ss` 空闲快照与后续 Prewarm 之间仍有新业务连接进入的竞争窗口。
- standalone 内嵌脚本与 `cn/` 源文件存在双份实现，修改时必须做一致性检查。

## 3. P0：DATA_PLANE_STALE_OUTER 重启风暴熔断

### 3.1 配置

新增：

```bash
DATA_PROBE_RESTART_WINDOW_SEC=600
DATA_PROBE_RESTART_MAX=3
DATA_PROBE_BREAKER_OPEN_SEC=600
```

建议统一完整项目与 standalone 的 `RESTART_COOLDOWN_SEC`。默认采用 60 秒，快速
处理单次真实 stale outer；累计风险由 10 分钟/3 次熔断器控制。

### 3.2 运行状态

写入 `runtime.state`，保证 Watchdog 自身重启后不丢失：

```text
DATA_PROBE_RESTART_EPOCHS
DATA_PROBE_BREAKER_STATE
DATA_PROBE_BREAKER_UNTIL
DATA_PROBE_BREAKER_SUPPRESS_LOGGED
```

`DATA_PROBE_RESTART_EPOCHS` 保存最近的 stale restart 时间，判断前删除窗口以外的
记录。系统 reboot 仍沿用现有语义，因 boot ID 变化而重置运行状态。

### 3.3 状态机

```text
STALE_OUTER_CONFIRMED + remote_tcp=up
                    |
                    v
       prune restart timestamps
                    |
          +---------+---------+
          |                   |
          v                   v
   breaker closed        breaker open
          |                   |
          v                   v
 generic cooldown       suppress restart
          |             FAULT/DATA_PROBE_BREAKER
          v                   |
   restart GOST               | keep low-rate probes
   record epoch               v
          |             probe success -> close/reset
          v
 count reaches max -> open breaker
```

具体规则：

1. 熔断只作用于 `DATA_PLANE_STALE_OUTER`；其他明确故障仍可使用通用重启逻辑。
2. 允许前三次符合条件的 stale restart，第三次后打开熔断器。
3. 熔断期间不停止 GOST、不停止 Anchor、不运行 Prewarm。
4. 熔断期间继续 Data Probe 与 Remote TCP Probe，以便自动识别恢复。
5. Data Probe 成功后立即关闭熔断器并清空重启历史。
6. `DATA_PROBE_BREAKER_OPEN_SEC` 到期后进入 half-open，只允许一次试探性重启。
7. half-open 后 Data Probe 再次失败时立即重新熔断，不连续重启。
8. Remote TCP 不可达时仍优先进入 `DOWN/REMOTE`，不累计 stale restart。
9. `DATA_PROBE_ENABLED=no` 时清理熔断运行状态。
10. `RESTART_SKIPPED_COOLDOWN` 不计入 restart 次数。

### 3.4 状态与事件

`status.json` 新增：

```json
{
  "data_probe_breaker": "open",
  "data_probe_restart_count": 3,
  "data_probe_breaker_until": 1786939000
}
```

新增事件：

```text
DATA_PROBE_RESTART_RECORDED
DATA_PROBE_BREAKER_OPEN
DATA_PROBE_RESTART_SUPPRESSED
DATA_PROBE_BREAKER_HALF_OPEN
DATA_PROBE_BREAKER_CLOSED
```

`DATA_PROBE_RESTART_SUPPRESSED` 只在熔断状态首次命中时记录，避免每轮刷日志。

## 4. P1：BUSINESS_PORTS 多业务连接统计

### 4.1 兼容配置模型

保留 `BUSINESS_PORT` 作为主入口和 Relay 保护依据，新增全部业务入口列表：

```bash
BUSINESS_PORT="12000"
BUSINESS_PORTS="12000 12002 12003"
```

兼容规则：

1. 旧配置只有 `BUSINESS_PORT` 时，自动得到
   `BUSINESS_PORTS="$BUSINESS_PORT"`。
2. 新配置必须验证每个端口在 1-65535 范围内。
3. 去除重复端口，并要求列表包含 `BUSINESS_PORT`。
4. `ANCHOR_PORT` 不得出现在 `BUSINESS_PORTS` 中。
5. `BUSINESS_PORT` 暂不删除，避免破坏旧配置与主入口保护语义。

### 4.2 连接统计

只执行一次 `ss -ntpH state established`，在同一个 awk 中：

- 匹配当前 GOST PID。
- 从本地地址提取端口，兼容 IPv4 与 IPv6 输出。
- 仅统计端口位于 `BUSINESS_PORTS` 集合中的连接。

`status.json` 保留聚合字段并增加配置可见性：

```json
{
  "business_ports": "12000 12002 12003",
  "business_connections": 1
}
```

### 4.3 Relay 管理同步

只修改 `cn.yaml` 不足以消除盲区。standalone Relay 管理器执行 add/remove 时必须：

1. 从候选 `cn.yaml` 提取所有使用 `chain-mtcp` 的业务监听端口。
2. 生成候选 `mtcp.conf`，更新 `BUSINESS_PORTS`。
3. 同时备份 `cn.yaml` 和 `mtcp.conf`。
4. 同时替换两个文件后重启 GOST。
5. unit 重启失败时同时回滚两个文件。
6. 老配置首次通过 Relay 管理器修改时自动补写 `BUSINESS_PORTS`。

手工编辑 `cn.yaml` 时仍需同步维护 `BUSINESS_PORTS`，并在 README 中明确说明。

### 4.4 空闲确认

建议同时增加：

```bash
BUSINESS_IDLE_HOLD_SEC=15
```

只有全部业务端口连续空闲达到该时间，才允许 `DEGRADED_IDLE_RETRY`，避免单次
`ss` 快照后新连接刚好进入的竞争窗口。任一业务端口出现连接立即清零空闲计时。

## 5. 影响文件

- `cn/mtcp.conf`
- `cn/mtcp-lib.sh`
- `cn/mtcp-watchdog.sh`
- `install.sh`
- `standalone-install.sh`
  - `CN_MTCP_CONF`
  - `CN_LIB`
  - `CN_WATCHDOG`
  - Relay add/remove 的配置事务
- `README.md`

## 6. 验收标准

### 6.1 熔断器

1. 单次真实 stale outer 正常重启并恢复 `FAST`。
2. Remote echo endpoint 配错时，10 分钟内最多执行 3 次 stale restart。
3. 达到阈值后稳定保持 `FAULT/DATA_PROBE_BREAKER`，不循环重启或 Prewarm。
4. 熔断期间修复 endpoint 后能够自动关闭熔断。
5. half-open 只执行一次试探性重启。
6. Remote 整体黑洞不增加 stale restart 计数。
7. Watchdog 重启后熔断状态和计数保持。
8. 其他重启原因不被 stale breaker 错误阻止。

### 6.2 多业务端口

1. 只有 12002 存在连接时，`business_connections > 0`。
2. 12002 活跃时 `DEGRADED_IDLE_RETRY` 必须推迟。
3. 所有配置端口空闲达到 hold 时间后才允许重试。
4. Relay add/remove 自动同步 `BUSINESS_PORTS`。
5. YAML 或配置替换、unit 重启任一步失败时完整回滚。
6. 旧版只有 `BUSINESS_PORT` 的配置无需人工迁移。
7. IPv4、IPv6、本进程和其他进程混合的 `ss` 输出统计正确。

## 7. 实施顺序

1. 增加配置兼容与校验。
2. 实现并测试 stale restart breaker 的纯状态函数。
3. 接入 Watchdog 两处 stale outer 分支和成功探测分支。
4. 扩展状态文件、状态 JSON 和事件日志。
5. 实现 `BUSINESS_PORTS` 聚合统计和空闲 hold。
6. 扩展 Relay 管理器的 YAML + mtcp.conf 原子事务。
7. 同步 standalone 内嵌文件并做源文件一致性检查。
8. 更新 README，执行 shell 语法、模拟状态机和故障注入回归测试。
