# setline 集成 roadmap

本文件跟踪 bas / basctl 与 setline 的集成设想，供后续核对与跟踪。每项用复选框表示进度，落地后
回填 commit。**当前的落地情况**：R0 / R1 / R8 / R9 已完成，R2 的命令行部分已完成（启停挂接
未做），其余尚未开始。

| 编号 | 主题 | 状态 | 依赖 |
|---|---|---|---|
| R0 | 实例运行信息 `server.info` | 已落地 | — |
| R1 | 动态端口与端口分配 | 已落地 | R0 |
| R2 | `start` / `stop` 自动注册路由 | CLI 已落地（`--sync`/`--stop`），启停挂接未开始 | R0、R1（可先支持静态端口） |
| R3 | 对账（`--watch` / `--sync`） | 未开始 | R0、R1、R2 |
| R4 | basctl 容器化：一机器一出口 | 未开始 | R1-R3 |
| R5 | host 分组（多人 / 多项目共享） | 未开始 | R2、R3 |
| R6 | 生产侧 agent manifest 通道 | 未开始 | 独立 |
| R7 | 命令面融合 | 未开始 | R1-R3 |
| R8 | jstart 精简：去掉 `app.pid` 与 `stop` | 已落地 | 独立 |
| R9 | setline 管理面：写只认本机、读保留 `adminToken` | 已落地 | 独立 |

## 术语

| 术语 | 指什么 |
|---|---|
| 意图 | `conf/server.xml`：声明有哪些 farm / server / webapp，各自的 http 端口与对外路径 |
| 现状 | `$BAS_HOME/servers/<name>/server.info`：实例标识、pid、实际端口、webapp 与对外 url（见 [server-info.md](server-info.md)） |
| 运行态 | setline 的路由表（内存 + 它写回的 JSON 配置文件） |
| 对账 | 把**运行态**对齐到**现状**的过程：活着的实例有路由，死掉/消失的摘除 |

### 「对账进程」是什么，不是什么

- **是**：一个只做路由同步的守护进程（拟名 `basctl setline --watch`）。它读 `servers/*/server.info`
  得到「实例 → pid / 端口 / webapp / 对外 url」，通过 setline 的 `/__setline/routes` 增删路由。
  **不需要重新解析 `server.xml`**：运行信息就是实例启动时那份配置的投影。
- **不是**：应用进程的 supervisor。起停应用仍然是 `basctl start` / `stop` 的职责，对账进程不碰
  进程生命周期、不拉容器、不解析依赖。
- **粒度**：一个 `BAS_HOME`（一份 `server.xml`）一个对账进程，不是每个 farm / server 一个。
- **也可以不常驻**：`basctl setline --sync` 一次性对账，挂在 `start` / `stop` 之后即可。两者的
  取舍见「待决策」。

## R0 实例运行信息 `server.info`

**目标**：每个实例一份运行信息（pid、实际端口、webapp、对外 url），作为 `status` 与路由对账
共用的「现状」视图。格式见 [server-info.md](server-info.md)。

**进度**：已落地（`src/bas/serverinfo.d`，`start` / `stop` / `status` 全部改读它）。

- 取代旧的一行 pid 文件（`SERVER_PID`）；webapp 与 `url` 顺带记录，供对账直接算出路由。
- 只有 basctl 写：`start` 分配好端口先写第一段（无 `pid`，兼作端口预留），确认存活后补 `pid`；
  启动失败或 `stop` 后删除。
- 状态不进文件：running / stale 由 pid 是否存活推导，少一个需要同步的字段。

**验收**

- [x] `start` 后 `server.info` 含 id / engine（`<type>-<version>`）/ http.port / started / pid / 每个 webapp 的 url
- [x] 启动过程中（端口已分配、进程未就绪）文件已存在但无 `pid`；准备失败与启动失败都会删除它
- [x] `status` 与 `stop` 只读 `server.info`，不再依赖 `ss` / `netstat` 反查端口
- [x] 文件为原子替换（写临时文件再 `rename`），任何时刻读到的都是完整内容

**待手工验证**：真起一个 JVM，确认「准备中文件无 pid → 存活后补 pid → 失败/停止后文件消失」这条
时间线（单测只覆盖到渲染、写入与删除三个动作本身）。

## R1 动态端口与端口分配

**目标**：`<server http="0">`（或缺省）时由 basctl 分配端口并传给应用，端口在启动前就已知。

**进度**：已落地（`src/bas/portalloc.d`；`--port-range` 缺省 `20000-29999`，锁文件
`servers/.ports.lock`）。

- 分配区间缺省 `20000-29999`：避开特权端口、Linux 临时端口 `32768-60999`、k8s NodePort
  `30000-32767` 与常见开发端口；用 `--port-range=<from>-<to>` 覆盖。区间是机器环境，不写进
  `server.xml`，也不设环境变量。
- 算法：优先复用本实例上次记录的端口，否则区间内顺序找第一个空闲端口；探测与落盘在
  `servers/.ports.lock` 的 `flock` 内完成，避免并发 `start` 重号。
- 结果写进 `server.info` 的 `http.port`（R0），并以 `--port=<n>` 传给应用——静态端口走同一条路，
  引擎侧不需要区分。
- `setlinePlan` 仍跳过 `http <= 0`：动态端口不进静态渲染，只进运行态注册。

**验收**

- [x] 同一实例重启后优先复用原端口（`reservePort` 传上次记录的端口；单测覆盖）
- [x] 区间占满时报错清晰（`no free port in <from>-<to>`），不静默换区间
- [x] 静态端口（`>0`）行为不变：`basctl setline` 的输出与今天完全一致（`setlinePlan` 未改动）
- [x] 端口占用判定同时看「别的实例的 `server.info`（含未启动完的预留）」与「本机 `bind` 探测」

**待手工验证**：两个 `http="0"` 的 server 同时启动，各自拿到区间内不同端口并写进 `server.info`
（需要真实实例；单测覆盖的是挑选与预留逻辑）。

**风险**：端口可连 ≠ 应用可用。注册时机需要一个 readiness 判定，见 R2。

## R2 `start` / `stop` 自动注册路由

**目标**：`basctl start` 起完即注册路由，`stop` 即摘除；setline 不在时只警告、不影响启动。

**进度**：CLI 这一半已落地——`basctl setline --sync`（要入口 + 推整组路由，必要时就地启动）与
`basctl setline --stop [--force]` 都能用了；`start` / `stop` 里的自动挂接还没做，因此
下面的验收项仍为空。

- **配置即开关**：`server.xml` 的 `<setline listen="..."/>` 出现才启用（等价于
  `setline_enabled=false` 的反面），地址、就地启动、systemd 的取舍见
  [setline-config.md](setline-config.md)。不配置就什么都不做。
- 启用时 `start` 先确保入口可用（探测入口：已在跑则复用，否则就地启动；探测走**写**接口，它只认
  本机且不需要 token），再 `--sync`；`stop` 之后再 `--sync` 摘除。失败只警告，不改启停的退出码。
  需要停掉就地实例时用 `basctl setline --stop [--force]`。
- 注册内容：R0 之后直接由 `servers/*/server.info` 得到「实例 → 端口 → webapp → 对外 url」，
  不必重新解析 `server.xml`；同前缀多实例写成端口数组，交给 setline 健康检查 + 随机选。
- 命名空间固定 `*`（除非 R5 引入分组）。
- 冲突前置：注册前先跑 `setlinePlan`，同路径被端口集合不同的多个 webapp 认领就**拒绝启动**——把
  今天的 `Route conflict` 从"生成配置时"提前到"启动前"。
- 加 `--no-setline` 临时跳过，避免 CI / 生产环境被动写路由。

**验收**

- [ ] 没配置 `<setline>` 时 `basctl start` 完全不碰 setline
- [ ] 配置了 `<setline>` 而没有 setline 在跑时，`start` 就地把它拉起来并推送路由
- [ ] `basctl start platform.server1` 后，`GET /__setline/routes` 出现对应前缀与端口
- [ ] `basctl stop` 后该端口从前缀的端口数组消失；数组为空则整条路由消失
- [ ] 冲突拓扑启动即失败，且不写任何路由

**风险**：启用时 `conf/setline.json` 归 setline 进程（`basctl setline` 渲染不再默认覆盖它），
禁用时归渲染命令——一个文件一个所有者，见 [setline-config.md](setline-config.md)。

## R3 对账（`--watch` / `--sync`）

**目标**：路由恒等于"此刻真实活着的实例"，覆盖 `kill -9`、端口漂移、手工起停。

- 输入：`servers/*/server.info`（pid、`http.port`、各 webapp 的 `url`）；pid 不存活即视为不存在。
  不重新解析 `server.xml`——运行信息是实例启动时那份配置的投影，避免"配置改了但实例还是旧的"歧义。
- 输出：对 `*` 命名空间做一次 `PUT /__setline/routes/all` **整体替换**，而不是逐条 diff——setline
  对新端口从"健康"开始，不再被引用的端口会自动清出健康表，整体替换天然幂等。
- 触发：轮询优先（简单、跨平台），inotify 作为可选优化。

**验收**

- [ ] `kill -9` 实例后一个周期内，对应路由被摘除
- [ ] 重启实例（`stop` + `start`）后，新的 `server.info` 使路由随之变化；只改 `server.xml`
      而不重启时路由**不变**（运行信息跟随实例，而不是跟随当前配置）
- [ ] 连续对账不产生重复路由；停掉对账进程不影响已有路由

**风险**：整体替换会覆盖"别人"写进 `*` 的路由。多人共享时需要 R5 的分组或独立命名空间。

### 实现形态与归属（这个程序放哪）

- **不需要第二个 `main`**：守护进程就是一个常驻子命令（`basctl setline --watch` 启动后不退出），
  进程管理交给 systemd——照抄 setline 已有的 unit 文件即可。dub 也允许一个包出多个可执行
  （`configurations` 各自 `targetName` + `mainSourceFile`）或 `subPackages`，所以"一个仓库一个
  二进制"不是硬约束。
- **要独立二进制时，先同仓库**：当它开始自己决定做什么（监控、重启、告警、清理），就不该只是 CLI
  的一个模式。此时在同一仓库加 `basctld`，共享 `bas.config` / `bas.serverinfo` / `bas.portalloc`
  ——把 `src/bas/` 当库用，两个 main 只做参数解析与调度（basctl 现在已经是这个形状）。
- **什么时候才开新仓库**：当它"职责独立 + 被别的项目复用 + 发布节奏不同 + 运行身份/权限不同"四项
  多数成立时。beangle 的 D 包没有发到 code.dlang.org，跨仓库依赖只能 `dub add-local` 或相对路径，
  成本高，能同仓库就先同仓库。
- **职责边界**：它读 `server.info`、写 setline 路由，**不写 `server.info`**（唯一写者是
  `start`/`stop`）；不做 TCP 健康探测（setline 已做），也不做进程内应用健康（应用出 `/status`）。
  第一版只报告、不自动重启。
- **先做 `--sync`**：一次性对账挂在 `start`/`stop` 之后就能覆盖大部分情况；常驻只在需要覆盖
  `kill -9`、手工起停、端口漂移时才值得。

## R4 basctl 容器化：一机器一出口

**目标**：镜像里跑 basctl + jstart + JDK + setline，对外只暴露一个端口。

- entrypoint：`basctl setline` 生成配置 → `setline -f conf/setline.json` 常驻 → `basctl start all`。
- 容器内再多 farm / webapp / 实例，出口只有一个——这正是 setline「回环后端 + 单一 listen」最贴的
  形态，docker 端口映射永远是一行。
- k8s 视角：setline 当 pod 内 sidecar / 入口，Service、Ingress、探针都只面对 setline。
- 信号：SIGTERM → 停应用 → 停 setline，退出码 0；`BAS_HOME` 走卷。

**验收**

- [ ] `docker run -p 8080:8080` 后，容器内全部 webapp 都能从宿主机 8080 访问
- [ ] 容器内增删 server 不需要改 docker 端口映射
- [ ] SIGTERM 干净退出，无残留 java 进程

**风险**：运行期路由会写回配置文件，容器需要可写的 `BAS_HOME`。

## R5 host 分组（多人 / 多项目共享一个 setline）

**目标**：一台机器上多份 `BAS_HOME` 共存，互不干扰。

- 分组键来自**环境 / 命令行**（如 `BAS_SETLINE_GROUP=alice`），**不来自 `server.xml`**。
- `*.localhost` 一般由系统直接解析到 127.0.0.1，浏览器无需改 hosts。
- 配合 git worktree：一个 worktree 一份 `BAS_HOME` + 一个分组，切分支不停服务。

**验收**

- [ ] 同一台机器两个 `BAS_HOME` 各自分组，同前缀互不干扰
- [ ] 未设分组时行为与今天一致（写 `*`）

**风险**：这实际上复活了一个"没有配置来源的旋钮"（见 `--host` 的教训）。它必须被明确归类为
"环境"，而不是"配置"。

## R6 生产侧 agent manifest 通道

**目标**：basctl / bashub 只产出拓扑 manifest → registry → 边缘机的 setline agent 拉取并渲染
haproxy / nginx。

- 与 R1-R3 完全解耦：不依赖 localhost 写接口，不涉及 runtime routes。
- setline 自身规定「normal proxy 模式不许生成 / 同步外部配置」，所以这是两条路、两种模式。

**验收**

- [ ] agent 渲染产物与 bashub 现有的 haproxy / nginx 模板输出一致

## R7 命令面融合

- [ ] `basctl status` 增加 route 列（对 `GET /__setline/routes` 反查）
- [ ] `basctl run --port=0 --route=/x`：embed 单应用自动注册、退出摘除，复活"单应用快速入口"
- [ ] `basctl start` 前做冲突预检（同 R2）

## R8 jstart 精简：去掉 `app.pid` 与 `stop`

**状态：已落地**。jstart 只负责"解析 + 准备 + exec"，实例身份与停止交给 basctl。

- jstart 不再写 `<base>/app.pid`；不再提供 `stop`（`--timeout` / `--force` 一并去掉），
  `run` 原有的"同一实例在运行就拒绝启动"随之消失。
- basctl 接管停止：按 `server.info` 的 pid 发 SIGTERM，`--timeout` 超时后报错，
  `--force` 直接 SIGKILL（同时跳过 pid 身份核对）。
- 同步范围：jstart 的 usage / `docs/commands.md`（原「组件 base 与 pid 文件」）/ README、
  `beangle.github.io/jstart` 页面、`test/smoke.sh`；破坏性变更记在 jstart 的 CHANGELOG。

**验收**

- [x] jstart 运行后实例目录里不再出现 `app.pid`，`jstart stop` 不再存在
- [x] `basctl stop` 不依赖 jstart 也能停干净（含 `--force` 强杀）
- [x] jstart 文档与站点不再出现 `stop` / `app.pid` 的使用说明

## R9 setline 管理接口：写只认本机，读保留 token

**状态：已落地**。setline 侧：写接口（`PUT` / `DELETE` 路由）只接受 TCP 对端
localhost，不认凭据（路由变即流量变）；**读**接口（`GET /__setline/routes`、状态页）保留
`adminToken`（`X-Setline-Token` / Basic Auth）且不限来源——路由表将来要开放给同网段的服务进程
读取，例如把拓扑渲染成 haproxy / nginx 配置的同步 agent（见 R6）。basctl 侧新增
`basctl setline --sync` 与 `--stop [--force]`，只走写路径，因此 `server.xml` 里不放 token。

**为什么最初想删、后来保留**：token 诞生在第一条 commit，当时它管的是**写**（改路由）的凭据；
写接口加上 localhost 门之后，写路径上它就冗余了，而读路径（`GET` routes + 状态页）是它最后的
消费者。既然读要留给同网段的服务进程，这个凭据就有用，删不得——改为把它明确成「读凭据」并写进
文档。

**验收**

- [x] 写接口非本机来源一律 403；本机调用不需要任何凭据
- [x] 读接口（含状态页）配了 `adminToken` 时缺凭据返回 401，凭据正确可读；不配即放行
- [x] setline 的 `README.md` / `doc/runtime-routes-api.md` 说明「读留 token、写只认本机」的分工
- [x] basctl 的 `--sync` 复用探测走写接口，配了 `adminToken` 也能复用已运行的 setline

## 已完成的前置（基线）

- [x] webapp `<url path>` 声明对外路径，`routePaths()` 未声明时回退 context path（basctl `2d6f33e`）
- [x] `setlinePlan` 冲突检测：同路径被端口集合不同的多个 webapp 认领即报错
- [x] `basctl setline` 渲染单一 `*` 命名空间
- [x] 实例运行信息 `server.info` 与端口分配（R0 / R1）：`start` 分配端口并记录，`status` 按它展示
      （不保留 `SERVER_PID` 兼容读取），`stop` 按其中的 pid 停止
- [x] jstart 精简（R8）：去掉 `app.pid` 与 `stop`，实例身份与停止归 basctl
- [x] setline 的运行期路由接口：管理接口仅 localhost 可调；路由写回配置文件（重读→只替换 `routes`
      →tmp+rename），仍被引用端口的健康状态会保留（见 setline `doc/runtime-routes-api.md`）
- [x] `server.xml` 的 `<setline listen>` 解析（xsd + config.d）与 `--sync`/`--stop` 的命令面
- [x] `basctl setline --sync` 的入口探测：写接口只认本机且无需 token，用它当「是不是我们的 setline」

## 非目标

- 不用 setline 做生产 L4/L7 负载均衡：随机选后端、无权重、无粘滞会话、不终止 TLS、HTTP/1.x。
- 不追求跨主机后端：setline 的后端固定 `127.0.0.1:<port>`。
- 不做路径改写：setline 只按路径前缀匹配，前缀原样透传。
- 不把"应用健康"塞进 setline：它只有 TCP connect 探活，表达不了"起来了但 500"。

## 待决策

1. **写者纪律**：`server.xml`（意图）、`server.info`（现状）、setline 配置文件（运行态）三份状态
   谁写谁读。已定：启用时 `conf/setline.json` 归 setline 进程（`routes` 由它写回），禁用时归
   `basctl setline` 渲染，见 [setline-config.md](setline-config.md)。
2. **对账形态**：常驻 `--watch`，还是只在 start/stop 里同步一次，或两者并存（watch 处理漂移，
   sync 保证即时）。
3. **是否引入 `--group`**：引入后如何映射到 setline 的 host 匹配语义。
4. **守护进程的运行身份**：单份 `BAS_HOME` 还是多份（一台机器上多个 bas 实例），以及以什么账号
   运行（要能对实例进程发信号）。
