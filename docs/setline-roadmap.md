# setline 集成 roadmap

本文件跟踪 bas / basctl 与 setline 的集成设想，供后续核对与跟踪。每项用复选框表示进度，落地后
回填 commit。**当前的落地情况**：R0 / R1 / R2 / R3 / R4 / R5 /
R7（route 列 + `start` 预检）/ R8 / R9 已完成；R6 未开始；R7 原设想的「embed 单应用注册」已明确不做
（`run` 保持纯前台，见 R7）。

| 编号 | 主题 | 状态 | 依赖 |
|---|---|---|---|
| R0 | 实例运行信息 `server.info` | 已落地 | — |
| R1 | 动态端口与端口分配 | 已落地 | R0 |
| R2 | `start` / `stop` 自动注册路由 | 已落地 | R0、R1 |
| R3 | 对账（`--watch` / `--sync`） | 已落地（子命令 `basctl setline --watch`） | R0、R1、R2 |
| R4 | basctl 容器化：一机器一出口 | 已落地（见 [container.md](container.md)） | R1-R3 |
| R5 | host 分组（多人 / 多项目共享） | 已落地（见 [setline-config.md](setline-config.md)） | R2、R3 |
| R6 | 生产侧 agent manifest 通道 | 未开始 | 独立 |
| R7 | 命令面融合 | 部分落地（route 列、start 预检；embed 单应用注册：不做） | R1-R3 |
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

- **是**：一个只做路由同步的守护进程（`basctl setline --watch`，已落地）。它读 `servers/*/server.info`
  得到「实例 → pid / 端口 / webapp / 对外 url」，通过 setline 的 `/__setline/routes` 增删路由。
  **不需要重新解析 `server.xml`**：运行信息就是实例启动时那份配置的投影。
- **不是**：应用进程的 supervisor。起停应用仍然是 `basctl start` / `stop` 的职责，对账进程不碰
  进程生命周期、不拉容器、不解析依赖。
- **粒度**：一个 `BAS_HOME`（一份 `server.xml`）一个对账进程，不是每个 farm / server 一个。
- **也可以不常驻**：`basctl setline --sync` 一次性对账（`start` / `stop` 之后本来就会各跑一次）。
  常驻与一次性的取舍已定：两者并存，见「待决策」。

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
- 落地时补了一处遗漏：动态端口最初只写进运行信息、没回填 `server.http`，于是 spec 里没有
  `--port=`，应用还在用引擎缺省端口（路由会指到一个没人听的端口）；现已在 `reserveInstance`
  里回填（见 `src/bas/starter.d`）。

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

**进度**：已落地。`basctl setline --sync`（把整组路由推给**已在跑**的 setline）、以及
`start` / `stop` 之后的自动对账都已可用；对账输入是 `servers/*/server.info`（见 R3），
`--no-setline` 可临时跳过。入口地址（当时叫 `listen`）与归属的最终形态在 R5 落地时改掉了：
进程归 systemd / 容器入口，basctl 不再拉起也不再停止（见 [setline-config.md](setline-config.md)）。

- **配置即开关**：`server.xml` 的 `<setline>` 出现才启用（等价于 `setline_enabled=false` 的反面），
  命名空间、入口地址、systemd 的取舍见 [setline-config.md](setline-config.md)。不配置就什么都不做。
- 启用时 `start` / `stop` 各推一次整组路由：入口上有人应答就复用（systemd、容器入口、手工、别的
  `BAS_HOME` 都算），没人应答就报错。失败只警告，不改启停的退出码。
- 注册内容：R0 之后直接由 `servers/*/server.info` 得到「实例 → 端口 → webapp → 对外 url」，
  不必重新解析 `server.xml`；同前缀多实例写成端口数组，交给 setline 健康检查 + 随机选。
- 命名空间取自 `<setline hostname>`（缺省 `localhost`，`*` 表示任意 Host），见 R5。
- 冲突前置：注册前先跑 `setlinePlan`，同路径被端口集合不同的多个 webapp 认领就**拒绝启动**——把
  今天的 `Route conflict` 从"生成配置时"提前到"启动前"。
- 加 `--no-setline` 临时跳过，避免 CI / 生产环境被动写路由。

**验收**

- [x] 没配置 `<setline>` 时 `basctl start` 完全不碰 setline
- [x] 配置了 `<setline>` 而没有 setline 在跑时~~`start` 就地把它拉起来并推送路由~~ → R5 改为
      **只警告并提示入口地址**（不就地拉起：进程归 systemd / 容器入口）
- [x] `basctl start platform.server1` 后，`GET /__setline/routes` 出现对应前缀与端口
- [x] `basctl stop` 后该端口从前缀的端口数组消失；数组为空则整条路由消失
- [x] 冲突拓扑启动即失败，且不写任何路由

**风险**：启用时 `conf/setline.json` 归 setline 进程（`basctl setline` 渲染不再默认覆盖它），
禁用时归渲染命令——一个文件一个所有者，见 [setline-config.md](setline-config.md)。

## R3 对账（`--watch` / `--sync`）

**目标**：路由恒等于"此刻真实活着的实例"，覆盖 `kill -9`、端口漂移、手工起停。

**进度**：已落地，形态取「同一个二进制里的常驻子命令」——`basctl setline --watch
[--interval=<sec>]`（缺省 5 秒轮询），而不是另立 `basctld`（理由见文末「实现形态与归属」）。
轮询时只在渲染结果变化后推送，闲时零流量；冲突则打印一次并保持现状，修好后下一周期自愈。

- 输入：`servers/*/server.info`（pid、`http.port`、各 webapp 的 `url`）；pid 不存活即视为不存在。
  不重新解析 `server.xml`——运行信息是实例启动时那份配置的投影，避免"配置改了但实例还是旧的"歧义。
- 输出：对 `*` 命名空间做一次 `PUT /__setline/routes/all` **整体替换**，而不是逐条 diff——setline
  对新端口从"健康"开始，不再被引用的端口会自动清出健康表，整体替换天然幂等。
- 触发：轮询优先（简单、跨平台），inotify 作为可选优化。

**验收**

- [x] `kill -9` 实例后一个周期内，对应路由被摘除
- [x] 重启实例（`stop` + `start`）后，新的 `server.info` 使路由随之变化；只改 `server.xml`
      而不重启时路由**不变**（运行信息跟随实例，而不是跟随当前配置）
- [x] 连续对账不产生重复路由；停掉对账进程不影响已有路由

**风险**：整体替换只覆盖**自己那个命名空间**（R5 之后）；多人共享时各自用不同的 `hostname`，
别都用 `*`（那是兜底命名空间，两组会互相覆盖）。

### 实现形态与归属（这个程序放哪）

**结论（已落地）**：就是 `basctl setline --watch` 一个常驻子命令，不另立 `basctld`；进程管理
交给 systemd（unit 里写这一行即可）。下面的判断依据留给将来它"长出别的职责"时再回看。

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

**状态：已落地**。三个仓库各自的源码在镜像里现编译（宿主的 ldc 产物链接宿主 glibc，搬进
Alpine 会因为 glibc 太旧起不来），容器入口自己拉起 setline（谁拥有进程谁负责起停），
basctl 只往它推路由。构建与运行见 [container.md](container.md)；涉及的文件：
`Dockerfile`、`scripts/build_image.sh`、`scripts/container/{entrypoint.sh,server.xml}`。

**目标**：镜像里跑 basctl + jstart + JDK + setline，对外只暴露一个端口。

- entrypoint：`basctl setline` 渲染配置 → `setline -f conf/setline.json` 常驻 →
  `basctl start all`（把实例路由推给它）。
- 容器内再多 farm / webapp / 实例，出口只有一个——这正是 setline「回环后端 + 单一 listen」最贴的
  形态，docker 端口映射永远是一行。
- k8s 视角：setline 当 pod 内 sidecar / 入口，Service、Ingress、探针都只面对 setline。
- 信号：SIGTERM → 停应用 → 停 setline，退出码 0；`BAS_HOME` 走卷。

**验收**

- [ ] `docker run -p 8080:8080` 后，容器内全部 webapp 都能从宿主机 8080 访问
- [ ] 容器内增删 server 不需要改 docker 端口映射
- [ ] SIGTERM 干净退出，无残留 java 进程（优雅 8 秒 → `--force`）

**风险**：运行期路由会写回配置文件，容器需要可写的 `BAS_HOME`。

**待手工验证**：镜像构建只到「编译通过、`java -version` 正常」这一步（`./scripts/build_image.sh`
产出 `basctl:0.0.1`）；下面三条要在真有 webapp 的环境里跑一遍才能打勾，步骤见
[container.md](container.md) 的「运行」。

## R5 host 分组（多人 / 多项目共享一个 setline）

**状态：已落地**，但形态与最初设想不同（讨论后改的，见 [setline-config.md](setline-config.md)）。

**目标**：一台机器上多份 `BAS_HOME` 共用一个 setline，路由互不干扰。

- 分组键**来自 `server.xml`**：`<setline hostname="alice.localhost">`（缺省 `localhost`，`*` 表示
  任意 Host）。最初设想用环境变量（`BAS_SETLINE_GROUP`），改成配置是因为它在这里没有漂移风险：
  一份 `BAS_HOME` 只有一份 `server.xml`，值天然唯一；反过来环境变量会出现"忘了 export 就写进
  `*`"的隐形漂移——正是 `--host` 那次的教训。
- 入口地址由 `server.xml` 的 `<setline endpoint>` 声明（命令行 `--endpoint` 覆盖单次调用），
  只有一处在解析（`bas.endpoint.resolveSetlineEndpoint`）。中途试过"环境变量
  `bas_setline_endpoint` + 内置缺省 `127.0.0.1:8080`"两级兜底，结论是**不要**：多一层看不见的
  状态，就得在 `doctor` / `status` / `--sync` / `start` 各处再解释一遍，还得为"环境与配置不一致"
  专门加告警，反而更容易漂移；地址写进 `server.xml` 只需要一行，改端口时 diff 里看得见。
- 命名空间与地址是两件不同粒度的事：`hostname` 是"我占哪一格"（每份配置不同），`endpoint` 是
  "门在哪"（共享时各份填同一个地址）。
- 配套结论：setline 变成**机器级常驻服务**（systemd / 容器入口），basctl 不拉起、不停止，
  因此 `--stop`、`run/setline.pid`、就地启动那一套一并退役。
- 浏览器把 `*.localhost` 解析到回环，所以 `alice.localhost` 开箱可用；命令行要
  `curl --resolve` 或写 hosts，或者干脆用 `hostname="*"`。
- 配合 git worktree：一个 worktree 一份 `BAS_HOME` + 一个 `hostname`，切分支不停别人的服务。

**验收**

- [x] 同一台机器两个 `BAS_HOME` 各自 `hostname`，同前缀互不干扰（`routes` 分组边界）
- [x] 不写 `hostname` 时行为可预期：命名空间是 `localhost`，要「任意 Host」得显式写 `*`
- [x] `<setline hostname>` 校验（域名字符或 `*`），写坏了报错而不是悄悄换一个名字
- [x] 入口没人应答时报错并提示入口地址的出处，不再就地拉起
- [x] 入口地址两个来源（`--endpoint` / `<setline endpoint>`）收在一个解析入口，`doctor` /
      `status` / `start` / `stop` / `--sync` 取到的是同一个地址；配了 `<setline>` 就必须写
      `endpoint`（缺了是配置错误），没配 `<setline>` 则完全不碰 setline——"没启用"与"写坏了"
      分得开，也不再有"忘记 export 就漂移"的隐形路径或猜出来的缺省

**风险**：`hostname` 缺省从"任意 Host"（旧行为）收紧成 `localhost`，靠 IP 或别的域名访问的
老部署要显式写 `hostname="*"`——迁移时注意（xsd 与样例已同步）。

## R6 生产侧 agent manifest 通道

**目标**：basctl / bashub 只产出拓扑 manifest → registry → 边缘机的 setline agent 拉取并渲染
haproxy / nginx。

- 与 R1-R3 完全解耦：不依赖 localhost 写接口，不涉及 runtime routes。
- setline 自身规定「normal proxy 模式不许生成 / 同步外部配置」，所以这是两条路、两种模式。

**验收**

- [ ] agent 渲染产物与 bashub 现有的 haproxy / nginx 模板输出一致

## R7 命令面融合

**目标**：把"路由"从一条独立命令（`basctl setline`）摊进日常命令面——看状态、起停、跑单应用时
都能直接看到/维护自己那一格路由，不必记着额外再敲一次 `--sync`。

**进度**：route 列与 `start` 预检已落地。原设想的「embed 单应用注册」（`basctl run --route=<路径>`）
**已决定不做**：`run` 是一次性的前台委托（写 spec → `exec jstart run`，退出码就是服务进程的退出码），
Ctrl-C 由终端整组转发，它不写 `server.info`、不碰 setline，也不在 `BAS_HOME` 留痕。

- `basctl status` 的 route 列：拿运行中实例该有的路由（`runningPlan`）与 setline 上的实际路由
  对照，报 `missing on setline` / `setline has …, want …` / `not in this BAS_HOME`，全对得上就是
  一行 `routes in sync (N)`。读的是**读**接口（`GET /__setline/routes`，只读无副作用）；setline
  对本机来源免凭据（见 R9），所以这条路径开箱即用、`server.xml` 里不存凭据，只有入口指向别的
  机器时才可能撞上 `adminToken`，那时如实报出来而不是猜。
- `start` 预检：R2 的"冲突前置"已经覆盖了**声明了端口**的拓扑（`setlinePlan`，配置级，跑不跑都
  算）；`http="0"`（动态端口）的冲突要等端口分配完，由起完那次对账兜底——那时冲突只警告、不写
  路由，因此现象是"实例起来了但没路由"，不是"启动失败"。
- 不做：让 embed 的单应用（`basctl run`）在 setline 上注册一格、退出即摘除。`run` 是开发期的
  临时前台进程，行为要可预期地"跑完就没了"；真要长期对外，用 `basctl start` 走 `server.info`
  那条路（R0-R2）。因此 `run` 连 `--port=0` 的动态端口分配都不需要——端口由 jstart / 容器自己给。

**验收**

- [x] `basctl status` 增加 route 列（对 `GET /__setline/routes` 反查）
- [x] 决定 `run` 不注册 setline（前台执行、Ctrl-C 退出即可），本项验收项撤销
- [x] `basctl start` 前做冲突预检（同 R2）

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
localhost，不认凭据（路由变即流量变）；**读**接口（`GET /__setline/routes`、状态页）**本机来源
同样免凭据**（读写一条门），非本机来源才看 `adminToken`（`X-Setline-Token` / Basic Auth）且不限
来源——路由表将来要开放给同网段的服务进程读取，例如把拓扑渲染成 haproxy / nginx 配置的同步
agent（见 R6）。basctl 侧读写都从 localhost 发，因此 `server.xml` 里没有任何凭据。

**为什么最初想删、后来保留**：token 诞生在第一条 commit，当时它管的是**写**（改路由）的凭据；
写接口加上 localhost 门之后，写路径上它就冗余了，而读路径（`GET` routes + 状态页）是它最后的
消费者。既然读要留给同网段的服务进程，这个凭据就有用，删不得——改为把它明确成「非本机读的
凭据」并写进文档。R7 的 route 列要读一次路由表，才把"本机读也免凭据"补齐：本机的读写不该有两种
待遇，否则 basctl 得在 `server.xml` 里多存一个只读凭据（与"减少配置"的方向相反）。

**验收**

- [x] 写接口非本机来源一律 403；本机调用不需要任何凭据
- [x] 读接口（含状态页）本机来源免凭据；非本机在配了 `adminToken` 时缺凭据返回 401，凭据正确可读
- [x] setline 的 `README.md` / `doc/runtime-routes-api.md` 说明「本机读写免凭据、非本机读看 token」
- [x] basctl 的 `--sync` / `status` 从 localhost 调用，配了 `adminToken` 的 setline 一样能写能读

## 已完成的前置（基线）

- [x] webapp `<url path>` 声明对外路径，`routePaths()` 未声明时回退 context path（basctl `2d6f33e`）
- [x] `setlinePlan` 冲突检测：同路径被端口集合不同的多个 webapp 认领即报错
- [x] `basctl setline` 渲染单一 `*` 命名空间
- [x] 实例运行信息 `server.info` 与端口分配（R0 / R1）：`start` 分配端口并记录，`status` 按它展示
      （不保留 `SERVER_PID` 兼容读取），`stop` 按其中的 pid 停止
- [x] jstart 精简（R8）：去掉 `app.pid` 与 `stop`，实例身份与停止归 basctl
- [x] setline 的运行期路由接口：管理接口仅 localhost 可调；路由写回配置文件（重读→只替换 `routes`
      →tmp+rename），仍被引用端口的健康状态会保留（见 setline `doc/runtime-routes-api.md`）
- [x] `server.xml` 的 `<setline hostname>` 解析（xsd + config.d）与 `--sync`/`--watch` 的命令面
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
2. ~~**对账形态**：常驻 `--watch`，还是只在 start/stop 里同步一次，或两者并存~~ **已定：两者
   并存**——`start` / `stop` 各同步一次保证即时（失败只警告，见 R2），`--watch` 处理 `kill -9`、
   手工起停、端口漂移等漂移（见 R3）；`--watch` 是前台子命令，常驻与否交给 systemd。
3. ~~**是否引入 `--group`**~~ **已定：不引入**——分组键就是 `server.xml` 的
   `<setline hostname>`（缺省 `localhost`，`*` 表示任意 Host），见 R5。
4. **守护进程的运行身份**：单份 `BAS_HOME` 还是多份（一台机器上多个 bas 实例），以及以什么账号
   运行（要能对实例进程发信号）。
