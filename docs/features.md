# 功能总览

`basctl` 是 Beangle Bas Server（下称 bas）的控制面命令行：输入只有一份 `conf/server.xml`，
输出是「能跑起来的实例」和「能对外转发的路由」。本文件讲它由哪些能力构成、背后是什么模型、
边界在哪；**怎么敲命令**见 [usage.md](usage.md)。

## 能力清单

| 能力 | 命令 | 做什么 | 详情 |
|---|---|---|---|
| 组件目录初始化 | `basctl init` | 把 `env.sh` / `bas.sh` / `start.sh` / `stop.sh` / `restart.sh` 铺到 `<workdir>/bin` 并建 `conf/`；脚本内嵌在 basctl 里，随版本发布，是脚本唯一的安装/升级途径 | [usage.md](usage.md) |
| 解析与预取 | `basctl make [server.xml] <pattern>`、`basctl resolve` | 解析 webapp（`gav://` / `http(s)://` / 本地路径），生成实例目录与 jstart launch spec，再 `jstart resolve` 预取依赖，不起进程 | [start.md](start.md) |
| 起停 | `basctl start` / `basctl stop` | 定端口、写 `server.info`、后台 `jstart run`；停止时按 pid 优雅退出（`--timeout` / `--force`） | [start.md](start.md)、[server-info.md](server-info.md) |
| 状态 | `basctl status` | 读 `servers/<name>/server.info` 列出运行中的实例；配了 `<setline>` 时另报命名空间、入口通不通与 route 列 | [server-info.md](server-info.md)、[setline.md](setline.md) |
| 嵌入式跑单应用 | `basctl run --engine=<type>-<version> <app>` | 一个参数给出容器类型与版本，生成单应用 spec 后前台 `jstart run`；纯前台，Ctrl-C 退出 | [run.md](run.md) |
| 本地代理与对账 | `basctl setline`（渲染 / `--sync` / `--watch`） | 把拓扑渲染成 setline 配置；按运行中的实例把路由推给本机 setline | [setline.md](setline.md)、[setline-config.md](setline-config.md) |
| 容器入口（creator） | `basctl make <type>` | jstart `[engine] init` 协议的回调，把容器启动命令写回 spec | [engine-creator.md](engine-creator.md) |
| 环境自检 | `basctl doctor` | 检查 `java` / `jstart`（启用 setline 时还有入口可达性） | [doctor.md](doctor.md) |
| 防火墙 | `basctl firewall` | 按 `server.xml` 交互式配置 firewalld 的放行端口 | [usage.md](usage.md) |
| 拉取配置 | `basctl pull` | 从控制端拉取 `conf/server.xml`（旧配置备份为 `server_old.xml`） | [usage.md](usage.md) |
| 横幅与版本 | `basctl banner` / `basctl version` | `bas.sh version` 调前者：ASCII logo + bas 引擎版本 + basctl 版本 + 本机地址 | [usage.md](usage.md) |
| 发行 | `scripts/build_deb.sh` / `build_rpm.sh`、`Dockerfile` | deb / rpm 包，以及「一机器一出口」的容器镜像 | [container.md](container.md) |

## 核心模型：三份状态与对账

| 状态 | 存在哪 | 谁写 | 谁读 |
|---|---|---|---|
| **意图** | `conf/server.xml` | 人 / `basctl pull` | 所有命令 |
| **现状** | `$BAS_HOME/servers/<name>/server.info` | `basctl start` / `stop`（唯一写者） | `status`、`stop`、对账 |
| **运行态** | setline 的路由表（内存 + 它写回的 `conf/setline.json`） | setline 进程（`basctl setline` 只推） | `status` 的 route 列、对账 |

**对账** = 把运行态对齐到现状的过程：活着的实例有路由，死掉/消失的摘除。

- **是**：一个只做路由同步的动作（`basctl setline --sync` 一次，或 `--watch` 常驻）。它读
  `server.info` 得到「实例 → pid / 端口 / webapp / 对外路径」，通过 setline 的
  `__setline/routes` 增删路由；**不需要重新解析 `server.xml`**——运行信息就是实例启动时那份
  配置的投影。
- **不是**：应用进程的 supervisor。起停仍然是 `basctl start` / `stop` 的职责，对账不碰进程
  生命周期、不拉容器、不解析依赖。
- **粒度**：一个 `BAS_HOME`（一份 `server.xml`）一个对账动作，不是每个 farm / server 一个。
- **也可以不常驻**：`--sync` 一次性对账（`start` / `stop` 之后本来就会各跑一次），`--watch`
  常驻交给 systemd。

## 目录约定

`BAS_HOME` 取 `conf/server.xml` 的上两级目录：

```
$BAS_HOME/
  conf/server.xml
  conf/setline.json             # setline 自己的配置（listen / 运行期路由；归拉起 setline 的那个进程所有）
  engines/<name>-<version>/     # 解压并按需裁剪后的 Tomcat
  servers/<farm>.<server>/      # 单个实例的 catalina.base（server.info 记运行信息：pid / 端口 / webapp / url）
  webapps/                      # http 直链与 SNAPSHOT 覆盖的落地目录
  run/                          # 机器级守护进程的运行态（如对账进程的 pid）
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

`server.xml` 中 `<repository>` / `<snapshot-repo>` 的 `local` / `remote` / `token` 原样透传给
`jstart`；`remote` 里的 `${bas_remote_url}`、`token` 里的 `${bas_remote_token}` 在解析阶段
展开为同名环境变量。

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
  只产出 bas 那部分路由，**不要拿它整体覆盖**全局配置——当片段并入（见 [setline.md](setline.md)）。
- **不做拓扑中间格式**：需要在 haproxy / nginx 那侧渲染反代配置时，交付物就是 `server.xml`
  本身（消费方复用 bas 的配置模型，别再写一份解析器）；要运行态（动态端口、存活实例）就读对方
  setline 的 `GET /__setline/routes`（非本机来源用 `X-Setline-Token`）。basctl **不导出**平行的
  `manifest.json` 之类文件——那是第二个事实源，必然漂移。
- **容器里不做 supervisor**：实例崩了不会自动重启，也没有 `HEALTHCHECK`；要这些用编排层的探针
  与重启策略（见 [container.md](container.md)）。
- **不做路径改写**：只按路径前缀匹配，前缀原样透传；不把「应用健康」塞进 setline（它只有 TCP
  探活，表达不了「起来了但 500」）。
- **不做 `run` 的路由注册**：`run` 是开发态的临时前台进程，行为要可预期地「跑完就没了」，
  既不写 `server.info` 也不碰 setline；要持久对外就用 `start`。

## 尚未定的事

- **对账进程（`--watch`）的运行身份**：一台机器上是每份 `BAS_HOME` 一个，还是一个管多份；
  以什么账号运行（要能对实例进程发信号）。
- **生产侧 agent 通道的形态**：registry 存什么、agent 多久拉一次、拉取的鉴权、渲染完是
  `reload` 还是 `restart`。产出侧已定：消费 `server.xml` / setline 读接口，不新增中间格式。
