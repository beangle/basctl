# 路线图

本文件只记**方向已定、尚未落地**的事，以及明确的待定项。已经做出来的能力见
[features.md](features.md)；那里的「边界与非目标」是长期约束，不随本文件变化。

每条给出：做什么、为什么这么切、哪些已经定死、哪些还待定。**落地顺序按编号走**，
前一条的产出是后一条的输入。

## R1 汇报与指令通道：basctl ↔ bashub

**状态：阶段 1–3 已落地（`basctl report` / `basctl agent` / `log:read` / `basctl logs`，含两侧测试与端到端）；
阶段 4 的 `service:start|stop|restart` 已落地，控制台审计待补**；bashub 侧的持久化未开工（现在只在内存登记册里）。

已落地的实现地图：协议 [channel-protocol.md](channel-protocol.md)、用法 [channel.md](channel.md)、
basctl 侧 `src/bas/{channel,agent,hub,report,logs}.d`、bashub 侧
`org.beangle.bashub.web.ws.agent`（`AgentRegistry` / `AgentSession` / `AgentEndpoint` /
`AgentConfigurator` / `AgentSocketInitializer`）与 `/api/bashub/monitor/agents/status`。

### 目标

生产机上的 basctl 主动把**现状**报给 bashub（`org.beangle.bashub`，配置控制台 + 管理台）。
视角是**节点**（basctl 所在的那台机器），不是流量：

- **操作系统**：CPU 核数、内存容量、磁盘挂载与容量这些**规划信息**（这台机器有多大的家底），
  外加水位的粗粒度读数——控制台要回答「这台机器还撑得住吗」，不做指标系统；
- **节点上跑着什么**：本机 `servers/*/server.info` 里活着的实例（id / pid / engine / 端口 /
  webapp / url）——控制台据此回答「哪台机器上跑了什么」；
- 控制台还能取回实例日志、下发启动 / 停止 / 重启。

### 已经定死的方向

- **basctl 出站 push，不是 bashub 进来拉**。生产机多在 NAT / 防火墙后面，开入站口要申请、
  要另配一套鉴权；出站 HTTP 只要机器能访问控制台。
- **汇报的是事实，不是配置**。主机指标取自本机；实例清单直接来自 `server.info` 的
  `liveInstances`，**不重新解析 `server.xml`**。这与 basctl 内部「意图 / 现状」的分工同构：
  bashub 是意图的远端权威（`profile` → `server.ftl` → `server.xml`），汇报通道把现状回传。
  控制台上「配置 vs 实际」的差异，就是这两条线对出来的。
- **不新增中间格式**：上报体的字段与 `server.info` 同名同义（要报路由时再带上 setline 那格的本机
  读数），控制台不再造一套平行模型（与 features.md 里「不做拓扑中间格式」同一条原则）。
- **地址复用控制台配置**：`conf/basctl.conf` 的 `[remote]` 同时服务 `pull` 与汇报端点，
  不引入第二个地址，也不依赖环境变量。
- **上报是整份替换语义**：以（主机 + BAS_HOME）为单位，谁报的就覆盖谁，天然幂等，控制台不必
  关心 basctl 报告的顺序。
- **不碰 setline，也不需要它演进**：「某个实例活着吗」由节点上的 basctl 判定（pid 存活 + 端口），
  不问 setline；启停实例也走 basctl 自己的代码。要报路由时可以（可选地）读
  `GET /_setline/routes`——现成的：对 localhost 一律放行、无凭据，`status` 已经在用
  （`bas.setlineproc.fetchRouteTable`）。
- **不是通用命令通道**：可下发的动作是**固定枚举**——启动 / 停止 / 重启指定实例、取日志。没有
  任意命令、没有远程 shell、没有参数透传：指令体里只有实例名与动作，basctl 侧走白名单后调用
  内部函数。控制台因此不会变成一台远程执行器（下面阶段 4 再展开）。

### 通道选型：参照 `beangle/task`

`beangle/task` 是同一套问题的现成例子（agent 主动连回服务端、服务端下发、agent 执行后回结果），
按它的技术模型对齐：

**借鉴**

| 做法 | 为什么 |
|---|---|
| agent **主动出站**连一条 WebSocket 长连接，断线自动重连 | 与「出站 push」定死方向一致，不必暴露入站口 |
| 登录时证明身份（它用首帧 `/login`），secret 来自配置 | 与 `basctl.conf [remote] token` 同构；服务端按身份建 channel |
| channel / caller 的 `invoke` → `reply` 模型（每个请求带 id，有回调） | 请求-应答靠 `id` 配对，指令不会重复执行、不会张冠李戴 |
| 配置里的调度参数（`begin_at` / `repeat` 间隔） | 心跳与采样的节拍器，不用另造 |
| 服务端只服务本机调用（判 `req.peer()` 是否回环） | 与 setline「写接口只认回环对端」同一个口径 |

**不借鉴**

| 做法 | 为什么不 |
|---|---|
| `Commands` 拿到字符串就 `executeShell` | 正是本特性明确排除的「任意命令」；R1 的动作是固定枚举，指令体只有实例名与动作 |
| 用 task / commands / stdout 那套任务模型 | 我们要的是固定口径的上报与几个固定动作，不是「下发任务」；任务调度会变成第二个事实源 |
| 一个 XML 里放 server 与 agent 两种角色（靠有没有 `port` 区分） | basctl 的角色由命令决定；`server.xml` 只描述实例，远程连接放 `basctl.conf` |

**结论（已定）：WebSocket 长连接**，按 `task` 的做法。指令要「下发即响应」，日志与将来的流式
需求迟早要双向，一次把双向这层做对，不先用 HTTP 凑合再返工。

形态：

- 端点：`{remote.url}/api/bashub/monitor/agents/{profile}/channel`，`{remote.url}` 与 Profile 都由 `basctl.conf` 的
  `[remote] url/profile` 拼出。
- 鉴权：**握手请求带 `Authorization: Bearer <profile>:<Profile.key>`**——`vibe.http.websockets` 的
  `connectWebSocketEx` 支持在握手前改请求头，所以不必像 `task` 那样先连上再 `/login`；校验不过
  直接 401、连接不建立。（若某条链路上自定义头传不过去，退回 `task` 的首帧 `/login host key`，
  服务端在鉴权完成前不处理其它消息。）
- 服务端：bashub 挂一个 `@ServerEndpoint`（或 `ServerApplicationConfig`）。它**不走 webmvc 的
  mvc profile**，所以要先确认 ems 的过滤链 / `WebReconfigModule` 不拦这条路径（拦了就放行，
  否则 CAS 的 302 会打断握手）；部署的 Tomcat 要带 websocket-api（发行包默认带）。
- 在线注册表：按 profile 记活连接，同一 profile 重复登录**踢掉旧连接**（`task` 的做法），保证一个
  `BAS_HOME` 只有一条活连接；连接断了就是这个 profile 离线，控制台据此显示。
- 保活与重连：中间设备会把静默连接掐断，所以要有**应用层 ping/pong**（vibe-http 1.3 的
  `WebSocket` 没有公开的 ping 帧 API，用消息做）；断线后固定间隔重连（不做指数退避，少一个要调的
  参数），重连后先发整份快照，不做增量续传。

协议是**固定原语**——这就是「不是通用命令通道」的落点：agent → hub 只有
`hello` / `report:os` / `report:bas` / `result` / `pong`，hub → agent 只有
`ping` / `report:now` / `log:read` / `service:start|stop|restart`。

信封、每个原语的 body、未知消息怎么处理、以后怎么扩展，**只在
[channel-protocol.md](channel-protocol.md) 里定义一份**（草案），本文不复述，免得两张表漂移。
其中对 basctl 的稳定性最关键的一条：**认不出的原语一律不执行也不退出**（有 `id` 就回
`result{ok:false}`，没有就忽略），老 agent 不会被新 hub 打崩。

**备查：为什么不是长轮询。** 服务端 hold 也能做到「下发即响应」，但那要求 hold 期间不占用数据库
连接（那组路由挂着 `hibernate` 拦截器），且每次指令都要搭一次完整的请求/响应；WS 是一次投资、
长期一条连接。若 bashub 侧的 WS 接入最终被证明接不住（比如 ems 的过滤链改不动），再退回长轮询：
**原语表不变，只换承载**。

顺带一个已存在的事实：basctl 的 `dub.json` 声明了 `vibe-http` / `vibe-d:web` / `vibe-inet`，但HTTP
一直全走 `curl` 子进程，这些依赖一行没用。走 WS 正好把它们用起来：客户端连接来自
`vibe.http.websockets`，事件循环来自 `vibe-core`。**核对结果**：`vibe-d:web` / `vibe-inet` 与
`vibe-stream:tls` 仍被 transitively 需要（WS 走 `wss` 要 TLS），暂不删。

### 阶段

| 阶段 | 做什么 | 前置 | 状态 |
|---|---|---|---|
| 1 | 事件驱动的现状汇报（**不引入常驻进程**） | 无 | 已落地 |
| 2 | 心跳与主机负载（常驻 agent、保持一条 WS 连接） | 阶段 1 | 已落地 |
| 3 | 只读指令：`log:read` 取日志区间 | 阶段 2 | 已落地 |
| 4 | 写指令：`service:*` + 审计 | 阶段 3 | 启停已落地，审计待补 |

阶段 1 不依赖进程常驻，可以独立落地并验证「汇报对不对」；阶段 3 / 4 共用阶段 2 建起来的那条
连接，只是往上面加消息类型。

#### 阶段 1：事件驱动的现状汇报

- 命令：`basctl report`——连上 WS、发 `hello` + `report`、断开。就是阶段 2 常驻循环的「跑一轮」，
  不是另一套协议。
- 时机与 setline 对账同构（不引入守护进程）：`start` / `stop` 之后各一次，加上需要时手工一次。
- 端点：`{remote.url}/api/bashub/monitor/agents/{profile}/channel`——**路径里不带连接 id**，一个 profile 一条连接（重复
  登录踢旧的）。握手前就要可达、按 key 校验，不能挂 security 拦截器（ems 的过滤链放行这一段是
  bashub 侧的验证项，见下面「待定」）。`report` 消息在 bashub 侧落到哪张表由它决定，不新增第三种
  格式。
- 鉴权：**握手时**带 `Authorization: Bearer <profile>:<token>`（通道认凭证不认地址）。地址、Profile 和 token
  都来自 `conf/basctl.conf` 的 `[remote]`；`pull` 本身也用同一个 token 做 Bearer 鉴权，不再依赖
  `ip:` 头。token 就是 bashub 的 `Profile.key`：**新建配置时随机生成**，另给一个重置入口
  （`POST /api/bashub/config/profiles/{id}/reset-key`，换 key 即吊销）。
- bashub 侧（**未开工**）：现在只落在内存登记册（`AgentRegistry`，每个 profile 只留最近一次、
  断连即摘除），够控制台回答「此刻谁在线、上面跑着什么」。要做历史点 / 曲线才需要一张
  「主机 / 实例现状」表 + 迁移脚本；现状数据是**可丢的**——丢了下次汇报就回来，不进配置表。

#### 阶段 2：心跳与主机负载

- 常驻的理由有两个，都绕不过去：**水位**只有连续采样才有意义（CPU 使用率、内存 / 磁盘水位），
  以及**指令**必须有人来取（下面的阶段 3 / 4 全靠它）。所以这一阶段引入 `basctl agent` 常驻，
  以 systemd unit 运行：连上 WS、周期发 `report`、收 `ping` 回 `pong`、收到指令就执行（阶段 3 / 4
  往下面那张消息表上加）。
- **一份 BAS_HOME 一个 agent**（basctl 的世界就是一份 `server.xml` / 一份 `BAS_HOME`）。机器级
  的聚合交给 bashub 按 host 合并——不要为此把 agent 提到机器级，也不要和机器级的 setline
  合成一个进程：两者的生命周期与归属都不同。
- 有常驻之后，阶段 1 的事件驱动不冲突：`start` / `stop` 之后那一次上报是「立刻推一次」的直接
  实现（一次性连、报完断开，不叫醒常驻 agent——那要另造一条本机控制通道，不值）。
- 采集实现：Linux 读 `/proc/loadavg`、`/proc/meminfo`，磁盘走 `statvfs`；Windows 开发机上这些
  字段**缺省即为空**（不报错、不伪造），控制台按「不可用」渲染——`status` 已经是不依赖
  `ss`/`netstat` 的路线，这里保持一致。

#### 阶段 3：只读指令（取日志）

- 要能把实例日志取回控制台：`logs/<farm.server>/console.out` 的一段。协议**只覆盖正在写的这一份**
  ——归档（`logs/archive/<实例>-YYYYMMDD.out`）要查就直接读机器上的文件，不为它再加一条原语。
- 控制台下发 `log:read`，basctl 读文件后以 `result` 回过去。**不做流式**（不持续推）——先接受；
  要实时看日志就登录机器。
- 本地命令 `basctl logs <实例> [-n N] [-f]` 与 `log:read` **共用同一份读法**（`bas.logs`：定位、
  按行区间读、跟随），两处只写一遍「日志在哪、怎么数行」。`-f` 只吃完整行（半行等它写完），
  日志滚动（文件变短）后自动跟新文件。

#### 阶段 4：写指令（`service:*`）

- 动作就是 `service:start` / `service:stop` / `service:restart` 三个原语
  （见 [channel-protocol.md](channel-protocol.md)），作用对象是指定实例，body 只有 `{instance}`：
  **不开任意 shell**，basctl 侧走白名单后调用内部函数，不拼命令行、不 `eval`、不把控制台输入透传
  给 shell。
- 复用同一条连接：控制台下发这三个原语（带 `id`），basctl 执行完以 `result` 回执。**指令通道的
  前置条件是常驻 agent（阶段 2）**——没有连接就没人来取指令。
- 已落地：agent 申报 `service:start|stop|restart`，按实例调用本地 start / stop 分支；`restart`
  先准备再停，动态端口沿用停机前的值；动作后立即重报 `report:bas`。
- 控制台侧还要记审计：谁点的、什么时候、结果如何；停止 / 重启这类破坏性动作前端已经二次确认。

### 非目标

- **不做 supervisor**：实例崩了不会自动重启，这条不变（见 features.md）。
- **不做通用监控**：不替代 Prometheus / node_exporter。只报 cpu / mem / disk 三个粗粒度值，
  够控制台判断「这台机器还行吗」为止。
- **不做 setline 的流量 / 健康监控**：不读它的统计，也不为它新增接口；本特性只看节点与实例。
- **不做通用命令下发**：不做远程 shell、不做「在某某机器上跑个脚本」，动作就是那几个固定枚举。
- **不做配置下发**：控制台的配置编辑仍走 `profile` → `server.ftl` → `server.xml` → `basctl pull`。
  汇报通道只往回传事实。
- **不装到非 bas 的服务上**：只覆盖 basctl 管辖的实例。

### 待定

- **ems 的过滤链要实测放行**：`/api/bashub/monitor/agents/{profile}/channel` 的 **HTTP 升级请求**不能被登录拦截 302 掉。
  静态看是安全的——ems 的登录拦截是 webmvc 的 action 拦截器（不是 servlet `Filter`），而容器里的
  `WsFilter` 比 `Dispatcher` 先拿到升级请求；但**没在 ems 的完整过滤链下实测过**，落地前要跑一次
  （起一个真 bashub，用 `basctl report` 连过去看 `AgentRegistry` 有没有登记上）。
- `hello` 里要不要带 `basctl` / `bas` 版本之外的构建信息（如 JDK 版本）——倾向不加。
- agent 常驻的落地形态：systemd unit 归 `basctl init` 铺，还是发行包自带；以什么账号跑。
- bashub 侧的存储形态：现状表（只留最近一次）还是保留若干历史点——决定控制台有没有曲线。
- 同机多份 `BAS_HOME` 时，主机指标由 bashub 按 host 合并，还是 agent 干脆提到机器级只报一次。
- 控制台页面：`GET /api/bashub/monitor/agents/status` 已经能拿到在线节点与现状，但 SPA 里还没有页面。

## R2 「漂移自动收敛」要不要做

现在只靠 `start` / `stop` 加手工一次对账；外部把实例弄没了的漂移，要人看见 `status` 的 route 列
才会去修。要做成常驻对账进程（谁跑、以什么账号跑、一台机器一个还是每份 `BAS_HOME` 一个）之前，
先看实际有多少这种漂移——`--watch` 已经因为「时机已经说清」删掉了。

R1 阶段 2 的 agent 是它天然的宿主（同一条常驻、同一份 `server.info`），但**不要顺手合并**：
对账改的是 setline 的路由表，汇报改的是控制台的现状表，出错的后果不一样，先各自跑稳。

## R3 生产侧（haproxy / nginx）的拓扑 agent

生产入口那台机器上要不要一个拉拓扑、渲染反代配置的 agent，以及它的通道（registry、拉取频率与
鉴权、`reload` 还是 `restart`），尚未定。产出侧已定：交付物就是 `server.xml`（basctl 不导出
平行的中间格式），需要运行态就读被代理机器的 setline 读接口（`GET /_setline/routes`，跨机读要
写在 `peerReaders` 里）。

它与 R1 是同一条通道的另一种消费：R1 传的是「现状」，R3 要的是「意图 + 路由」。**R1 的传输/
鉴权决策要一次做对，两者共用**，别到时候再发明第二套。
