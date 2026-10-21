# 控制通道协议（草案）

basctl 与 bashub 之间那条 WebSocket 连接上说什么、怎么说。**本文是协议的唯一权威**：两侧各自
实现，改协议先改本文，再同步两侧代码与测试，但读的都是本文这张表。

设计原则一句话：**原语封闭，字段开放。**

- **原语封闭**：`type` 是一个有限的名单，认不出即拒（或忽略）。没有「随便发个命令字符串」这种东西
  ——这是「不做通用命令下发」在协议层的落点。
- **字段开放**：每个原语内部只定义必需字段，加字段不算协议变更，读方忽略不认识的字段。这条沿用
  `server.info` 的老约定（[server-info.md](server-info.md)：「不认识的键与分节保留但不解释」）。

## 端点与鉴权

| 项 | 取值 |
|---|---|
| 路径 | `{remote.url}/api/bashub/monitor/agents/{profile}/channel` |
| `{remote.url}` | `conf/basctl.conf` 的 `[remote] url`，如 `https://hub.example.com` 或 `https://hub.example.com/bas/hub`；连接时把 `http` / `https` 换成 `ws` / `wss` |
| 凭证 | `Authorization: Bearer <profile>:<[remote] token>`（握手头），token 取值是 bashub 的 `Profile.key` |

- **谁拨号**：basctl 主动出站。生产机多在 NAT 后面，开入站口要申请、要另配一套鉴权；出站只要
  机器能访问控制台。启用开关、地址与 token 都来自同目录 `conf/basctl.conf` 的 `[remote]`；
  三项齐全才拨号，没有该文件或字段不完整就不发任何外连，也不读取环境变量。
- **鉴权在握手，不在首帧**：凭证随 `pull` 通道下发，换掉即吊销；未通过鉴权的连接在握手阶段就被
  关掉，连一个字节的协议都拿不到。`Profile.key` 由 bashub 新建时随机生成，可重置（重置即吊销）。
  `pull` 本身也用同一个 `<profile>:<Profile.key>` 做 Bearer 鉴权，不再依赖可伪造的 `ip:` 头。
- **一条连接一个 profile**：同一 profile 再次登录时服务端踢掉旧连接——agent 断线重连常常是「旧的
  还没超时、新的已经进来」，留着旧的会让 hub 往一条死连接发指令。所以路径里不带连接 id。
- **保活**：hub 按期发 `ping`，agent 回 `pong`；agent 那边沉默超时（90s）就重连。不用 WebSocket
  自带的 ping 帧——`vibe` 的客户端没有公开的 ping API，用消息做，协议少一层特例。
- **都不许退出**：任何一条消息、任何一次解析失败都不许让 agent 退出或断连；hub 侧同理（见下面
  「遇到不认识的怎么办」）。

## 信封

所有消息是同一个 JSON 信封，四个字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `type` | 是 | 原语名，`动作:对象` 形状（`report:os`、`service:start`），取本文的名单 |
| `id` | 否 | 请求号。**有 = 需要应答**（收到方必须回一条 `result`），无 = 通知，不等回执 |
| `at` | 是 | 产生时刻，`yyyy-MM-ddTHH:mm:ss±HH:MM`（本机时区，与 `server.info` 的 `started` 同格式） |
| `body` | 是 | 该原语的负载；没有负载就是 `{}` |

`id` 与 `at` 由**发起方**填。应答一律是 `result`，靠 `id` 配对。

## 原语：agent → hub

| 原语 | 类别 | body |
|---|---|---|
| `hello` | 通知 | `{host, basctl, basHome, bas, supports[]}`：连上后的第一条，见下「能力协商」 |
| `report:os` | 通知 | `{os:{name,kernel,arch}, cpu:{cores,load1,load5,load15}, mem:{total,available}, disk:[{mount,total,available}]}` |
| `report:bas` | 通知 | `{instances:[...], declared:[...]}`：`instances` 是活着的实例，每项与 `server.info` 的 `[server]` 同构（`id/pid/engine/http.port/started` + `webapps[]`）；`declared` 是本机 `server.xml` 声明的可操作实例（`id/engine/httpPort?/webapps[]`） |
| `pong` | 通知 | `{}`：保活应答 |
| `result` | 应答 | `{ok:bool, data?, error?}`：对所有带 `id` 请求的应答 |

- 容量与水位同处一个对象（`cpu.cores` 是配置、`cpu.load1` 是水位；`mem.total` 是配置、
  `mem.available` 是水位），控制台一次拿到「家底 + 现状」。
- 字节数一律用字节（不是 MB/G）、行号一律 1 基含两端。
- `declared` 与 `instances` 分开：前者是配置声明（用于停止后仍能启动），后者是运行事实；控制台按
  `id` 合并，未出现在 `instances` 的 `declared` 项按“已停止”渲染。
- **`report:os` 与 `report:bas` 都是整份替换语义**：谁报的就覆盖谁，天然幂等，hub 不必关心顺序；
  也因此两者可以各有节拍——OS 指标按周期（秒级），`report:bas` 按事件（`start` / `stop` 之后）
  加低频兜底——互不牵连，这正是把它们拆成两个原语的理由。
- 缺的字段就是「本机取不到」（比如 Windows 开发机上没有 `/proc`），**不伪造**；控制台按「不可用」
  渲染。

## 原语：hub → agent

| 原语 | 类别 | body | 说明 |
|---|---|---|---|
| `ping` | 通知 | `{}` | 保活 |
| `report:now` | 通知 | `{}` | 请立刻报一次：agent 收到就发 `report:os` + `report:bas`。**不带 `id`**——报告本身就是回执，省一次往返 |
| `log:read` | 请求 | `{instance, from, to, tail?}` | 读 `logs/<farm.server>/console.out` 的第 `from`–`to` 行；`from` / `to` 都省略时，`tail` 指定只取最后 N 行 |
| `service:start` | 请求 | `{instance}` | 起一个实例 |
| `service:stop` | 请求 | `{instance}` | 停一个实例 |
| `service:restart` | 请求 | `{instance}` | 重启一个实例 |

- 动作用**三个原语**而不是一个 `service:control{action}`：白名单落在 `type` 上，信封层就能拒掉不认的
  动作，不必解析 body；将来加动作 = 加一个原语，审计时也一眼看得出干了什么。
- `log:read` 的应答：`result.data = {total, from, to, lines:[...]}`。`total` 是文件总行数，控制台据此
  翻页，不必再要一个「问行数」的原语。区间读，**不流式**（要实时看日志就登录机器）。
- `tail` 只影响首次窗口定位，不改变后续增量读：控制台取尾部后，用 `from = 上次 to + 1` 再读，
  agent 不保存会话状态，也不需要流式连接。
- `service:*` 的应答：`result.data = {state:"running"|"stopped", pid?}`。
- `service:*` 的实例名只能是 `server.xml` 里本机声明的 `farm.server`；动作走 basctl 内部的
  start / stop 分支，不拼 shell 命令。动作完成后 agent 还会重发一次 `report:bas`，控制台不必等
  下一轮周期上报才看到新状态。
- 老 agent 不申报 `service:*` 时，hub 不下发；万一收到，agent 仍按「不认识」回
  `result{ok:false, error:"unsupported:<type>"}`。**改已有原语的语义不允许，改成这一套名字也不行**。

## 能力协商

`hello.supports` 是 agent 唯一的自述：它支持的原语名单（本文两张表里属于它的那些，**包括
`ping` / `report:now` / `log:read` 这些 hub → agent 原语**）。hub 只下发**交集**里的原语——
老 agent 不会收到它不认识的东西。

**不设协议版本号**：能力即版本。多一个 `protocol: 1` 就多一张「版本号 ↔ 有哪些功能」的对应表要维护，
而 `supports` 直接就是那张表。

## 遇到不认识的怎么办

agent 是常驻进程，**任何一条消息都不许让它退出或断连**（这是稳定性条款）：

| 情况 | 有 `id` | 无 `id` |
|---|---|---|
| `type` 不认识（hub 比 agent 新） | 回 `result{ok:false, error:"unsupported:<type>"}` | 忽略，记一行日志 |
| `body` 里有不认识的字段 | 忽略该字段，照常执行 | 同左 |
| 缺必需字段 / 值非法 | 回 `result{ok:false, error:"bad-request"}` | 忽略，记一行日志 |

同一条规则反向成立：bashub 收到不认识的 `report:*` 就忽略——老 hub 不会被新 agent 打崩。

## 幂等

- `report:*` / `hello`：整份替换，重复发没有副作用。
- 请求（`log:read` / `service:*`）：agent 侧记最近若干个 `id` → 结果，重复下发同一个 `id` 只回放上次
  结果、不重复执行（控制台重试、网络抖动都不会把实例重启两遍）。
- `report:now`：无副作用，收到就做。

## 怎么扩展

| 想加什么 | 怎么做 | 要改协议吗 |
|---|---|---|
| 一个域里多一个指标（如 `mem.swap`、`cpu.usage`） | 直接加字段 | 不要（字段开放） |
| 新的域（如每个实例的 JVM 堆、线程数）→ `report:jvm` | 本文两张表各加一行；agent 在 `supports` 里加上 | 只在本文加一行，两侧代码各加一个分支 |
| 新的动作（如 `service:reload`） | 同上 | 同上 |
| **改已有原语的语义**（同名不同义） | **不许**——另起一个名字（如 `report:os2`），旧的留着直到没人用 | 需要，且必须走本文 |

## 为什么不像 `beangle/task` 那样做

`task` 的 hub→agent 是 `{id, commands}`——一个开放式 shell 字符串，两端没有共同的类型定义，写错
没人拦，agent 等于把 shell 借给了服务端。本项目明确不要这个（见
[roadmap.md](roadmap.md) 的「不借鉴」）。差别就在开头那句话：**它的原语是开放的，我们的原语封闭、
字段开放**。

## 节拍（已定，都是常数）

| 参数 | 取值 | 在哪 |
|---|---|---|
| `report:os` / `report:bas` 周期 | 30s | basctl `bas.agent.reportInterval`；hub 的 `report:now` 可随时插一次 |
| 保活 `ping` | hub 每 30s | bashub `AgentSocketInitializer.HeartbeatInterval` |
| agent 沉默超时 | 90s | basctl `bas.agent.silentTimeout`（超了重连） |
| 断线重连 | 10s | basctl `bas.agent.reconnectDelay` |
| 拨号超时 | 20s | basctl `bas.agent.connectTimeout`（`start` / `stop` 之后那一次不能久等） |

**不做成参数**：这几条都是「不合适就改代码」的常数，多一个旋钮就多一处漂移。

## 未定

- `hello` 里要不要带 `basctl` / `bas` 版本之外的构建信息（如 JDK 版本）——倾向不加，要用再加字段。
