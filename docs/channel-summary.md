# basagent ↔ bashub 通信备忘

> 速查页；字段与边界条件的权威定义见 [channel-protocol.md](channel-protocol.md)。
> 本文只回答三件事：**传什么、什么格式、多久一次**。

## 1. 连接

| 项 | 取值 |
|---|---|
| 传输 | WebSocket（生产 `wss`，回环才允许明文 `ws`） |
| 端点 | `{remote.url}/api/bashub/monitor/agents/{profile}/channel` |
| 方向 | **basagent 主动出站**拨号，bashub 只应答；不在生产机开入站口 |
| 鉴权 | 握手头 `Authorization: Bearer <profile>:<Profile.key>`，key 来自 `conf/basctl.conf` 的 `[remote] token` |
| 身份 | 握手头 `ip: <addr>[,<addr>…]`；hub 只保留与 Profile/Host 配置匹配的那个地址 |
| 连接粒度 | 一个 profile 的每台机器一条；同一 IP 重连会顶掉旧连接，不同 IP 互不影响 |
| 能力协商 | agent 在 `hello.supports[]` 里声明自己支持的原语，hub 只下发交集 |

## 2. 信封

所有消息都是同一个 JSON 对象：

```json
{
  "type": "report:health",
  "id": "可选，请求号",
  "at": "2026-10-23T17:30:00+08:00",
  "body": {}
}
```

| 字段 | 说明 |
|---|---|
| `type` | 封闭名单，见下两节；认不出就拒绝/忽略，不做通用命令下发 |
| `id` | **有 = 请求**，接收方必须回一条 `result`；无 = 通知，不回执。≤64 字符，字母/数字/`-_.:` |
| `at` | 发送方本机时刻，`yyyy-MM-ddTHH:mm:ss±HH:MM`；`service:*` 只接受 10 分钟内的时刻 |
| `body` | 原语负载，没有负载就是 `{}` |

应答统一为 `result`：

```json
{"type":"result","id":"<请求的 id>","at":"...","body":{"ok":true,"data":{},"error":""}}
```

失败时 `ok=false`，`error` 是稳定错误码（如 `start-failed`、`pull-failed`），排错信息放在 `data.detail` / `data.logTail`。

## 3. agent → hub

| 原语 | body | 说明 |
|---|---|---|
| `hello` | `{host, basctl, basHome, bas, supports[]}` | 连接后的第一条；版本与能力自述 |
| `report:os` | `{os:{name,kernel,arch}, cpu:{cores,load1,load5,load15}, mem:{total,available}, disk:[{mount,total,available}]}` | 主机家底 + 水位；字节为单位 |
| `report:bas` | `{instances:[...], declared:[...]}` | 实例完整快照；`instances` 是运行中的实例，`declared` 是 `server.xml` 声明的可操作实例 |
| `report:health` | `{servers:[{id,state}]}` | 轻量状态，`state` 为 `running` / `stopped` / `error`；响应 hub 的请求 |
| `pong` | `{}` | 保活应答 |
| `result` | `{ok, data?, error?}` | 对带 `id` 请求的应答 |

`report:bas` 的实例字段：

- `instances[]`：`id`、`pid`、`engine`、`httpPort`、`started`、`webapps[]`
- `declared[]`：`id`、`engine`、`httpPort?`、`webapps[]`
- `webapps[]`：`id?`、`uri`、`context`、`urls[]`（`declared` 的项没有 `id`）

## 4. hub → agent

| 原语 | body | 说明 |
|---|---|---|
| `ping` | `{}` | 保活；agent 回 `pong` |
| `report:now` | `{}` | 立刻补一份 `report:os` + `report:bas`；无 `id`，报告本身即回执 |
| `report:health` | `{}` | 立刻补一份轻量状态；无 `id` |
| `log:read` | `{instance, from, to, tail?}` | 读实例 `console.out` 的行窗口；应答 `result.data={total,from,to,lines,truncated?}` |
| `agent:log` | `{from, to, tail?}` | 读 basagent 自身日志，窗口语义同上 |
| `service:start` / `service:stop` / `service:restart` | `{instance}` | 启停实例；成功 `data={state,pid?}` |

说明：

- `service:start` / `service:restart` 执行前先拉取 `server.xml`，拉取失败回 `pull-failed`；`stop` 不拉取。
- 动作完成后 agent 会主动补一份完整快照（`report:os` + `report:bas`），控制台不用等下一轮采样。
- 请求带 `id`；agent 记住最近若干个 `id` 的结果，重复下发只回放、不重复执行。
- `log:read` 单行最多 4 KiB、整个窗口约 200 KiB，超出截断并置 `truncated=true`。
- WebSocket 单帧上限 256 KiB，超过由连接层拒绝。

## 5. 配置拉取（HTTP，非 WebSocket）

| 项 | 取值 |
|---|---|
| 端点 | `GET {remote.url}/api/bashub/config/{profile}/server` |
| 鉴权 | 同一个 Bearer：`<profile>:<Profile.key>` |
| 返回 | `application/xml`，即最终下发的 `server.xml`（≤4 MiB，`Cache-Control: no-store`） |
| 写入 | `basagent pull` 校验后原子替换 `<BAS_HOME>/conf/server.xml` |
| 时机 | 手工 `bin/bas.sh pull`；`service:start` / `service:restart` 执行前自动拉一次；`stop` 不拉 |

拉取失败时 `basagent pull` 非 0 退出；`service:start/restart` 返回 `pull-failed`，不执行动作。

## 6. 频率与超时

| 时机 | 内容 | 触发方 | 缺省 |
|---|---|---|---|
| 连接/重连成功 | `hello` + `report:os` + `report:bas` | agent | 每次连接一次 |
| 保活 | `ping` → `pong` | hub | 每 60s |
| 轻量状态采样 | hub 请求 `report:health`，agent 回 `report:health` | hub | 每 300s，仅在 07:00–22:00（hub 本地时区） |
| 强制刷新 | `report:now` → `report:os` + `report:bas` | hub | 手工触发（监控页“刷新”按钮，或 `POST .../report`） |
| 实例动作完成 | 补完整快照（`report:os` + `report:bas`） | agent | 每次 `service:*` 后 |
| 日志 | `log:read` / `agent:log` | hub | 按需，不轮询 |
| 配置拉取 | `GET .../config/{profile}/server` | agent | 手工 `pull`，或 `service:start/restart` 前 |
| 断线重连 | 重新拨号 | agent | 10s 后 |
| agent 沉默超时 | 收不到 hub 任何消息就重连 | agent | 150s |
| 拨号超时 | 建连超时 | agent | 20s |

一次常驻连接大致是：

```text
agent → hello / report:os / report:bas
hub   → ping                （每 60s）
agent → pong
hub   → report:health       （每 interval，窗口内）
agent → report:health
hub   → report:now          （手工刷新）
agent → report:os / report:bas
hub   → service:start       （带 id）
agent → result + report:os / report:bas
```

- **完整快照不是周期上报**：只有连接、`report:now`、实例动作后才会发；日常只有轻量 health。
- 轻量采样由 hub 控节拍，agent 本地不保存 interval/窗口；关闭采样时 hub 不再下发 `report:health`。
- 采样配置在 bashub 的 `hub.xml`：

  ```xml
  <app>
    <agent health-interval="300" health-start="07:00" health-end="22:00"/>
  </app>
  ```

  `health-interval` 为秒，0 关闭；窗口含 start、不含 end，可跨午夜；也兼容旧的
  `<app agent-health-interval=...>` 属性。改完重启 bashub 生效。
- 监控页的 30 秒自动刷新只重读 `/agents/status`（hub 缓存），**不会**打扰 agent；点“刷新”才发
  `report:now`。

### 为什么有了 `report:health` 还需要 `ping` / `pong`

- **health 是采样，不是保活**：它默认 300s 一次、只在 07:00–22:00 窗口内、可以配置为 0 关闭；
  窗口外或关闭时没有任何流量，agent 的 150s 沉默超时会让连接反复重连。
- **health 的节拍由 hub 的采样策略决定**：把连接存活绑在 `health-interval` 上，改采样频率就会
  改变保活行为；`ping` 固定 60s，与采样配置无关。
- **health 有采集成本**：agent 收到请求要重读 `server.xml` 并采集实例状态；`ping` 只是空消息，
  适合高频保活。
- **NAT / 防火墙**：60s 一次的双向小消息能维持映射，避免中间设备静默回收空闲连接。
- **半开连接检测**：hub 60s 发 `ping`、agent 回 `pong`；agent 150s 收不到任何 hub 消息就重连，
  hub 也能从 socket 读失败尽快摘除会话。health 的 300s 间隔太慢，等它发现已经晚了。

## 7. 语义与排错

- `report:os` / `report:bas` / `report:health` 都是**整份替换**：重复发、乱序发都安全。
- `declared` 与 `instances` 分开：停止的实例只出现在 `declared`，控制台按 `id` 合并；标题由 hub 按
  profile 的 webapp 配置反查后补 `title`。
- 遇到不认识的消息：有 `id` 回 `unsupported:<type>`，无 `id` 忽略并记一行日志；任何解析失败都不许
  让 agent/hub 退出。
- 常见问题：
  - 没有数据：先看 `[remote]` 三项是否齐全、hub 侧 Profile.key 是否被重置、握手 `ip` 是否命中配置。
  - 没有运行历史：看 `health-interval` 是否为 0、当前是否在 `health-start/end` 窗口内（hub 时区）。
  - 启停无反应：看 `hello.supports` 是否包含对应 `service:*`；老 agent 不申报时 hub 不下发。
