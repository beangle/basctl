# 功能总览

`basctl` 是 Beangle Bas Server（下称 bas）的本地控制面命令行，`basagent` 是同一发行包里的
远端通道进程：输入只有一份 `conf/server.xml`，输出是「能跑起来的实例」和「能对外转发的路由」。
本文件讲它们由哪些能力构成、背后是什么模型、边界在哪；**怎么敲命令**见 [usage.md](usage.md)。

## 能力清单

| 能力 | 命令 | 做什么 | 详情 |
|---|---|---|---|
| 组件目录初始化 | `basctl init` | 把 `env.sh` / `bas.sh` / `start.sh` / `stop.sh` / `restart.sh` 铺到 `<workdir>/bin` 并建 `conf/`；缺少 `conf/basctl.conf` 时生成带注释、字段留空的 `0600` 模板，已存在则不覆盖。脚本内嵌在 basctl 里，随版本发布，是脚本唯一的安装/升级途径 | [usage.md](usage.md) |
| 解析与预取 | `basctl make [server.xml] <pattern>`、`basctl resolve` | 解析 webapp（`gav://` / `http(s)://` / 本地路径），生成实例目录与 jstart launch spec，再 `jstart resolve` 预取依赖，不起进程 | [start.md](start.md) |
| 起停 | `basctl start` / `basctl stop` | 定端口、写 `server.info`、后台 `jstart run`；停止时按 pid 优雅退出（`--timeout` / `--force`） | [start.md](start.md)、[server-info.md](server-info.md) |
| 状态 | `basctl status` | 读 `servers/<name>/server.info` 列出运行中的实例；配了 `<setline>` 时另报命名空间、管理口通不通与 route 列 | [server-info.md](server-info.md)、[setline.md](setline.md) |
| 看实例日志 | `basctl logs <farm.server>` | 读 `logs/<实例>/console.out` 的尾部（`-n` 缺省 50 行，上限 2000），`-f` 持续跟随（含日志滚动后的新文件）；通道的 `log:read` 与它共用同一份读法（`bas.logs`） | [usage.md](usage.md)、[channel.md](channel.md) |
| 嵌入式跑单应用 | `basctl run --engine=<type>-<version> <app>` | 一个参数给出容器类型与版本，生成单应用 spec 后前台 `jstart run`；纯前台，Ctrl-C 退出 | [run.md](run.md) |
| 本地代理与对账 | `basctl setline` | 按运行中的实例把路由推给已经在跑的 setline（推一次即退出，只推，不生成 setline 的配置、不拉起它） | [setline.md](setline.md) |
| 容器入口（creator） | `basctl make <type>` | jstart `[engine] init` 协议的回调，把容器启动命令写回 spec | [engine-creator.md](engine-creator.md) |
| 环境自检 | `basctl doctor` | 检查 `java`（必需）与 `jstart`（可选提示）；启用 setline 时还检查管理口可达性 | [doctor.md](doctor.md) |
| 防火墙 | `basctl firewall` | 按 `server.xml` 交互式配置 firewalld 的放行端口 | [usage.md](usage.md) |
| 汇报与指令通道 | `basagent report` / `basagent` | 主动拨一条出站 WebSocket 到控制台（bashub），把本机现状（主机家底 + 活着的实例）报上去，并接收固定原语（立即上报 / 取实例或 agent 日志）；后台由发行包安装的 `basagent.service` 管理 | [channel.md](channel.md)、[channel-protocol.md](channel-protocol.md) |
| 拉取配置 | `bas.sh pull`（`basagent pull`） | 从控制端拉取 `conf/server.xml`（旧配置备份为 `server_old.xml`）；`start` / `restart` 不隐式拉取 | [usage.md](usage.md) |
| 横幅与版本 | `basctl banner` / `basctl version` | `bas.sh version` 调前者：ASCII logo + bas 引擎版本 + basctl 版本 + 本机地址 | [usage.md](usage.md) |
| 发行 | `scripts/build_deb.sh` / `build_rpm.sh`、`Dockerfile` | deb / rpm 包，以及「一机器一出口」的容器镜像 | [container.md](container.md) |

## 核心模型：三份状态与对账

| 状态 | 存在哪 | 谁写 | 谁读 |
|---|---|---|---|
| **意图** | `conf/server.xml` | 人 / `bas.sh pull` | 所有命令 |
| **现状** | `$BAS_HOME/servers/<name>/server.info` | `basctl start` / `stop`（唯一写者） | `status`、`stop`、对账 |
| **运行态** | setline 的路由表（内存 + 它写回自己配置文件的 `routes`） | setline 进程（`basctl setline` 只推） | `status` 的 route 列、对账 |
| **远端副本**（可选） | bashub 里那份「谁报的就覆盖谁」的现状 | `basagent report` / systemd 常驻 agent 的 `report:*` | 控制台（bashub）；basctl 自己不读 |

**对账** = 把运行态对齐到现状的过程：活着的实例有路由，死掉/消失的摘除。

- **是**：一个只做路由同步的动作（`basctl setline`，推一次就结束）。它读
  `server.info` 得到「实例 → pid / 端口 / webapp / 对外路径」，通过 setline 的
  `/_setline/routes` 增删路由；**不需要重新解析 `server.xml`**——运行信息就是实例启动时那份
  配置的投影。
- **不是**：应用进程的 supervisor。起停仍然是 `basctl start` / `stop` 的职责，对账不碰进程
  生命周期、不拉容器、不解析依赖。
- **粒度**：一个 `BAS_HOME`（一份 `server.xml`）一个对账动作，不是每个 farm / server 一个。
- **不常驻**：就是一次对账（`--sync` 是它的显式写法），时机是 `start` / `stop` 之后各一次，
  加上需要时手工敲一次。没有 `--watch` 轮询进程：setline 自己常驻，"什么时候改路由"由实例的
  启停说清；外部把实例弄没了的漂移，`status` 的 route 列会报出来。

## 目录约定

`BAS_HOME` 取 `conf/server.xml` 的上两级目录：

```
$BAS_HOME/
  conf/server.xml
  conf/setline.json             # setline 自己的配置（listen / adminListen / 运行期路由；归拉起 setline 的那个进程所有）
  engines/<name>-<version>/     # 解压并按需裁剪后的 Tomcat
  servers/<farm>.<server>/      # 单个实例的 catalina.base（server.info 记运行信息：pid / 端口 / webapp / url）
  webapps/                      # http 直链与 SNAPSHOT 覆盖的落地目录
  logs/
```

实例的端口在启动前就定下来：`<server http>` 有值就用它，为 `0`（或缺省）时由 `basctl start`
在 `--port-range`（缺省 `20000-29999`）内分配一个空闲端口，两种情况下都记进
`servers/<name>/server.info`——`start` / `stop` / `status` 与对账都读这一份「现状」，不再用 `ss`
反查端口。格式与生命周期见 [server-info.md](server-info.md)。

## `make` 的两种模式

`make` 是一种「准备」语义，按第一个参数区分两种输入：

| 调用 | 驱动与输入 | 产物 | 用途 |
|---|---|---|---|
| `make [server.xml] <pattern>` | `conf/server.xml`，批量选 Server | **持久**布局：`engines/<name>-<ver>/` + `servers/<name>/` + 按 server 生成一份 launch spec | 面向运维与启动前预取：只写 spec 并 `jstart resolve`，不起进程；随后 `basctl start` |
| `make <type> [options]` | jstart 的 `[engine] init` 协议，单次运行计划 | jstart base 下的 `engines/`、各 webapp 的 docBase，以及 `--entry-out` 里的**容器启动命令** | `start` / jstart 运行时的回调，用户一般不直接调用 |

`<type>` 取 `tomcat-server`、`tomcat`、`undertow` 或 `jetty`，分别对应全量 Tomcat 发行包与
三种嵌入式容器。

## 与 jstart 的关系

构件的解析与下载委托给本机 `jstart` 命令（`fetch` / `resolve`）；`basctl` 只负责配置模型、
目录编排与配置渲染。`jstart` 不在 `PATH` 时可用环境变量 `beangle_jstart` 指定其路径。

运行 war 时，jstart 按 `[engine] init` 协议调用 basctl 的 `make <type>` 并把 war 交给它：它准备
webapp、写出最终启动命令，jstart 再 exec。`basctl make tomcat` / `undertow` / `jetty` /
`tomcat-server` 承接原 `engine` 模块的 creator 逻辑（如何调用、spec 示例、必要参数、
docBase 布局与 classpath 拼装见 [engine-creator.md](engine-creator.md)）：

```sh
# [engine] init 直接写命令行（jstart 支持“程序 + 参数”，无需 wrapper）
init = basctl make tomcat
```

`basctl start` 会根据 `<engine type>` 自动把 `[engine] init` 写成对应 creator 的
`make <type>` 命令行（`tomcat-server` 多应用、`tomcat` / `undertow` / `jetty` 单应用），
再 `jstart resolve` 校验依赖、`jstart run` 后台启动；详见 [start.md](start.md)。

`basctl run` 面向单应用快速运行：一个 `--engine=<type>-<version>` 同时给出容器类型与版本，
bas 引擎版本取 basctl 内置默认（`--bas=` 可覆盖），依赖集与 `start` 共用 `engines.ini`；
详见 [run.md](run.md)。

`server.xml` 中 `<repository>` / `<snapshot-repo>` 的 `local` / `remote` / `token` 透传给
`jstart`：多个仓库时 `token` 与 `remote` 按位置对应，并合并成 `token@url` 写入
`--remote` / `--snapshot-remote`；空段即该仓库匿名。
`remote` 里的 `${bas_remote_url}`、`token` 里的 `${bas_remote_token}` 在解析阶段用同目录
`conf/basctl.conf` 的 `remote.url` / `remote.token` 展开，不读取同名环境变量；bashub 生成的
`<snapshot-repo token>` 则直接来自 Project 的 micdn `download-key`。

实例身份与停止只归 basctl：jstart 不再写 `app.pid`、也不提供 `stop`，它就是「解析 + 准备 +
exec」——所以 `run` 是纯前台（Ctrl-C 退出），`start` 起来的是后台进程，两者的运行信息都记在
`server.info` 里（见 [server-info.md](server-info.md)）。

## 边界与非目标

- **只覆盖 bas 管辖的服务**：路由全部来自 `server.xml` 的 farm / server / webapp，不含 basctl
  之外的服务。
- **setline 不是生产负载均衡**：随机选后端、无权重、无粘滞会话、不终止 TLS、只做 HTTP/1.x，
  后端固定 `127.0.0.1:<port>`（因此不能代理别的机器上的 server），且基于 epoll，**Linux only**。
  生产入口（haproxy / nginx）是另一条路。
- **代理是全局的**：一台机器通常只有一份 setline，它同时服务 bas 与别的系统。`basctl setline`
  只推 bas 那一格（`<setline hostname>` 命名空间），别的分组既不读也不清理。
- **不做拓扑中间格式**：需要在 haproxy / nginx 那侧渲染反代配置时，交付物就是 `server.xml`
  本身（消费方复用 bas 的配置模型，别再写一份解析器）；要运行态（动态端口、存活实例）就读对方
  setline 的 `GET /_setline/routes`（跨机读要写在它的 `peerReaders` 里）。basctl **不导出**平行的
  `manifest.json` 之类文件——那是第二个事实源，必然漂移。
- **不生成 setline 的配置**：`listen` / `adminListen` / 调参属于拥有 setline 进程的那个
  （systemd unit / 容器入口 / 手工），basctl 只按 `<setline port>` 拨管理口；早先的
  `basctl setline --output` 渲染模式已删（那是第二个配置源，还会和 setline 自己的相反）。
- **容器里不做 supervisor**：实例崩了不会自动重启，也没有 `HEALTHCHECK`；要这些用编排层的探针
  与重启策略（见 [container.md](container.md)）。
- **不做路径改写**：只按路径前缀匹配，前缀原样透传；不把「应用健康」塞进 setline（它只有 TCP
  探活，表达不了「起来了但 500」）。
- **不做 `run` 的路由注册**：`run` 是开发态的临时前台进程，行为要可预期地「跑完就没了」，
  既不写 `server.info` 也不碰 setline；要持久对外就用 `start`。

## 尚未定的事

已经整理进 [roadmap.md](roadmap.md)：R1 与 bashub 的汇报/指令通道、R2 漂移自动收敛、
R3 生产侧拓扑 agent。本文件只保留长期约束（上面的「边界与非目标」）。
