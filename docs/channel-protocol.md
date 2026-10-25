# 控制通道协议（草案）

> 只想知道传什么、什么格式、多久一次：看 [channel-summary.md](channel-summary.md)。

basagent 与 bashub 之间那条 WebSocket 连接上说什么、怎么说。**本文是协议的唯一权威**：两侧各自
实现，改协议先改本文，再同步两侧代码与测试，但读的都是本文这张表。

设计原则一句话：**原语封闭，字段开放。**

- **原语封闭**：`type` 是一个有限的名单，认不出即拒（或忽略）。没有「随便发个命令字符串」这种东西
  ——这是「不做通用命令下发」在协议层的落点。
- **字段开放**：每个原语内部只定义必需字段，加字段不算协议变更，读方忽略不认识的字段。这条沿用
  `server.info` 的老约定（[server-info.md](server-info.md)：「不认识的键与分节保留但不解释」）。

## 端点与鉴权

| 项 | 取值 |
|---|---|
| 路径 | `{remote.url}/api/bashub/monitor/agents/{project}/channel` |
| `{remote.url}` | `conf/basctl.conf` 的 `[remote] url`，如 `https://hub.example.com` 或 `https://hub.example.com/bas/hub`；生产必须 HTTPS，连接时换成 `wss`。`http://` 只允许精确的本机回环地址 |
| 凭证 | `Authorization: Bearer <project>:<[remote] token>`（握手头），token 取值是 bashub 的 `Project.key` |
| 身份 | `ip: <addr>[,<addr>…]`（握手头）：本机地址，多网卡时全部上报（**回环地址不发**，只有回环的开发机例外）；hub 过滤后只保留与 Host 配置命中的那个作为 `project + server ip` 身份，只顶掉同一 IP 的旧连接 |

- **一个 project 多台机器**：同一 project 的不同机器各持一条连接，互不顶替；hub 靠 `ip` 头区分，
  因此这个头在握手时必填。头里没有合法 IP 时 hub 返回 400；地址合法但不属于该 Project 的
  `ip` / `hosts.ip` 时返回 403（配置里没有任何 IP 也拒绝，不做“没配置就放行”的兜底）。
- **谁拨号**：basagent 主动出站。生产机多在 NAT 后面，开入站口要申请、要另配一套鉴权；出站只要
  机器能访问控制台。启用开关、地址与 token 都来自同目录 `conf/basctl.conf` 的 `[remote]`；
  三项齐全才拨号，没有该文件或字段不完整就不发任何外连，也不读取环境变量。
- **鉴权在握手，不在首帧**：凭证随 `pull` 通道下发，换掉即吊销；未通过鉴权的连接在握手阶段就被
  关掉，连一个字节的协议都拿不到。`Project.key` 由 bashub 新建时随机生成，可重置（重置即吊销）。
  `pull` 本身也用同一个 `<project>:<Project.key>` 做 Bearer 鉴权，不再依赖可伪造的 `ip:` 头。
- **传输完整性**：客户端恢复 `trustedCert` 校验并加载系统 CA；自签书或主机名不匹配必须握手失败。
  控制面和配置下载都不接受非回环地址上的明文 HTTP/WS。
- **一条连接一个 project**：同一 project 再次登录时服务端踢掉旧连接——agent 断线重连常常是「旧的
  还没超时、新的已经进来」，留着旧的会让 hub 往一条死连接发指令。所以路径里不带连接 id。
- **自动组网**：所有 agent 先以候选身份连 hub，带 `X-Bas-Group`；探测同组固定端口后发送
  `recommend`。hub 按 `(project, group)` 原子选出一个 master，发送 `become-master` /
  `become-follower`。master 保持 hub 并在内网接受 follower；follower 断开 hub，消息由 master
  加上 `agent`（follower 的 Host.ip）转发。
- **保活**：hub 按期发 `ping`，agent 回 `pong`；agent 那边沉默超时（150s）就重连。不用 WebSocket
  自带的 ping 帧——`vibe` 的客户端没有公开的 ping API，用消息做，协议少一层特例。
- **都不许退出**：任何一条消息、任何一次解析失败都不许让 agent 退出或断连；hub 侧同理（见下面
  「遇到不认识的怎么办」）。

## 信封

所有消息是同一个 JSON 信封，四个字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `type` | 是 | 原语名，`动作:对象` 形状（`report:os`、`service:start`），取本文的名单 |
| `id` | 否 | 请求号。**有 = 需要应答**（收到方必须回一条 `result`），无 = 通知，不等回执；最多 64 字符，只允许字母、数字和 `-_.:` |
| `at` | 是 | 产生时刻，`yyyy-MM-ddTHH:mm:ss±HH:MM`（本机时区，与 `server.info` 的 `started` 同格式）；`service:*` 只接受前后 10 分钟内的时刻 |
| `agent` | 否 | relay master 上的逻辑 agent（follower 的 IP）；直连或 master 自身消息不带 |
| `body` | 是 | 该原语的负载；没有负载就是 `{}` |

`id` 与 `at` 由**发起方**填。应答一律是 `result`，靠 `id` 配对。

## 原语：agent → hub

| 原语 | 类别 | body |
|---|---|---|
| `hello` | 通知 | `{host, basctl, basHome, bas, supports[]}`：连上后的第一条，见下「能力协商」（`basctl` 字段沿用原协议名，值是同包的发行版本） |
| `report:os` | 通知 | `{os:{name,kernel,arch}, cpu:{cores,load1,load5,load15}, mem:{total,available}, disk:[{mount,total,available}]}` |
| `report:bas` | 通知 | `{instances:[...], declared:[...]}`：`instances` 是活着的实例，每项与 `server.info` 的 `[server]` 同构（`id/pid/engine/httpPort/started` + `webapps[]`）；`declared` 是本机 `server.xml` 声明的可操作实例（`id/engine/httpPort?/webapps[]`） |
| `report:health` | 通知 | `{servers:[{id,state}]}`：响应 hub 的 `report:health`，只报本机声明实例的 `running` / `stopped`（hub 也接受 `error` 以便扩展）；不带 OS、内存、磁盘与 webapps 明细 |
| `pong` | 通知 | `{}`：保活应答 |
| `result` | 应答 | `{ok:bool, data?, error?}`：对所有带 `id` 请求的应答；失败时也可带限长后的 `data` 供排错 |
| `recommend` | 通知 | `{candidate, group}`：推荐组内 master 候选，由 hub 原子决定 |
| `agent:offline` | 通知 | `{}`：master 告知 hub 某个 relay follower 已断开（`agent` 字段给出 IP） |

- 容量与水位同处一个对象（`cpu.cores` 是配置、`cpu.load1` 是水位；`mem.total` 是配置、
  `mem.available` 是水位），控制台一次拿到「家底 + 现状」。
- 字节数一律用字节（不是 MB/G）、行号一律 1 基含两端。
- `declared` 与 `instances` 分开：前者是配置声明（用于停止后仍能启动），后者是运行事实；控制台按
  `id` 合并，未出现在 `instances` 的 `declared` 项按“已停止”渲染。
- **`report:os`、`report:bas` 与 `report:health` 都是整份替换语义**：谁报的就覆盖谁，天然幂等，
  hub 不必关心顺序。`report:health` 只覆盖轻量实例状态，不影响已缓存的完整快照。
- 缺的字段就是「本机取不到」（比如 Windows 开发机上没有 `/proc`），**不伪造**；控制台按「不可用」
  渲染。

## 原语：hub → agent

| 原语 | 类别 | body | 说明 |
|---|---|---|---|
| `ping` | 通知 | `{}` | 保活 |
| `report:now` | 通知 | `{}` | 请立刻报一次：agent 收到就发 `report:os` + `report:bas`。**不带 `id`**——报告本身就是回执，省一次往返 |
| `report:health` | 通知 | `{}` | 请立刻报一次轻量实例状态：agent 收到就发 agent→hub 的 `report:health`。**不带 `id`**——状态报告本身就是回执。bashub 用它控制运行历史的采样频率与窗口 |
| `log:read` | 请求 | `{instance, from, to, tail?}` | 读 `logs/<farm.server>/console.out` 的第 `from`–`to` 行；`from` / `to` 都省略时，`tail` 指定只取最后 N 行 |
| `agent:log` | 请求 | `{from, to, tail?}` | 读 basagent 自身的 console 日志；窗口语义与 `log:read` 相同 |
| `service:start` | 请求 | `{instance}` | 起一个实例 |
| `service:stop` | 请求 | `{instance}` | 停一个实例 |
| `service:restart` | 请求 | `{instance}` | 重启一个实例 |
| `become-master` | 通知 | `{master, port, term}` | hub 指定本 agent 为组内 master |
| `become-follower` | 通知 | `{master, port, term}` | hub 指定本 agent 跟随 master，随即断开 hub |
| `config:refresh` | 通知 | `{}` | hub 配置变更后，agent 重新拉取 server.xml 并重报实例清单 |

- 动作用**三个原语**而不是一个 `service:control{action}`：白名单落在 `type` 上，信封层就能拒掉不认的
  动作，不必解析 body；将来加动作 = 加一个原语，审计时也一眼看得出干了什么。
- `log:read` 的应答：`result.data = {total, from, to, lines:[...], truncated?}`。`total` 是文件总行数，
  控制台据此翻页，不必再要一个「问行数」的原语。区间读，**不流式**（要实时看日志就登录机器）。
  单行最多 4 KiB、整个窗口最多约 200 KiB；超限时截断并置 `truncated=true`。
- `agent:log` 的应答与 `log:read` 同形。它只读标准安装的 `/var/log/bas/agent/console.out`
  （未安装时对应 `$BAS_HOME/logs/agent/console.out`），不接受实例名。
- `tail` 只影响首次窗口定位，不改变后续增量读：控制台取尾部后，用 `from = 上次 to + 1` 再读，
  agent 不保存会话状态，也不需要流式连接。
- `service:*` 的成功应答：`result.data = {state:"running"|"stopped", pid?}`。
- `service:*` 的失败应答仍带稳定错误码（如 `start-failed` / `prepare-failed`），
  并可在 `result.data` 中带限长排错信息：`{detail?, logTail?:[...], truncated?}`。`detail` 最多
  8 KiB，`logTail` 最多 100 行且每行最多 1000 字节；完整日志继续用 `log:read`。
- `service:*` 的实例名只能是 `server.xml` 里本机声明的 `farm.server`；动作走 basctl 内部的
  start / stop 分支，不拼 shell 命令。动作完成后 agent 重发一次完整快照（`report:os` + `report:bas`），控制台不必等
  下一轮轻量采样才看到新状态。
- `service:*` 必须带合法 `id` 与新鲜的 `at`；同一 `id` 只回放上次结果，不重复执行。WebSocket
  单帧上限为 256 KiB，超过的消息由连接层拒绝。
- `service:start` / `service:restart` 执行前，agent 先按 `[remote]` 拉取一次 `server.xml`；拉取或
  新配置解析失败时返回 `result{ok:false, error:"pull-failed"}`，不执行动作。`service:stop` 不拉取，
  始终按当前运行信息停机。
- 老 agent 不申报 `service:*` 时，hub 不下发；万一收到，agent 仍按「不认识」回
  `result{ok:false, error:"unsupported:<type>"}`。**改已有原语的语义不允许，改成这一套名字也不行**。

## 能力协商

`hello.supports` 是 agent 唯一的自述：它支持的原语名单（本文两张表里属于它的那些，**包括
`ping` / `report:now` / `report:health` / `log:read` / `agent:log` 这些 hub → agent 原语**）。
hub 只下发**交集**里的原语——老 agent 不会收到它不认识的东西。

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

## 节拍与超时

| 参数 | 取值 | 在哪 |
|---|---|---|
| 完整快照 `report:os` / `report:bas` | 首次连接、`report:now`、实例动作后可触发 | 不在常驻循环中周期重发 |
| 轻量 health 采样 | 缺省 300s，仅 07:00–22:00（bashub 主机时区） | bashub `hub.xml` 的 `<agent health-interval/health-start/health-end>`（兼容旧 `agent-health-*` 属性）；关闭后不再下发 `report:health` |
| 保活 `ping` | hub 每 60s | bashub `AgentSocketInitializer.HeartbeatInterval` |
| agent 沉默超时 | 150s | basagent `bas.agent.silentTimeout`（超了重连） |
| 断线重连 | 10s | basagent `bas.agent.reconnectDelay` |
| 拨号超时 | 20s | basagent `bas.agent.connectTimeout`（`report` 与重连都不能久等） |

所有采样节拍都由 hub 控制；agent 本地不保存 interval 或时间窗口。`agent-health-*` 的值只在
bashub 启动时读取，修改后重启 bashub 生效。

## 未定

- `hello` 里要不要带 `basctl` / `bas` 版本之外的构建信息（如 JDK 版本）——倾向不加，要用再加字段。
