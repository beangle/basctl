# 功能总览

`basctl` 是 Beangle Bas Server（下称 bas）的本地控制面命令行，`basagent` 是同一发行包里的
远端通道进程：输入只有一份 `conf/server.xml`，输出是「能跑起来的实例」和「能对外转发的路由」。
本文件讲它们由哪些能力构成、背后是什么模型、边界在哪；**怎么敲命令**见 [usage.md](usage.md)。

## 能力清单

| 能力 | 命令 | 做什么 | 详情 |
|---|---|---|---|
| 组件目录初始化 | `basctl init` | 把 `env.sh` / `bas.sh` / `start.sh` / `stop.sh` / `restart.sh` 铺到 `<workdir>/bin` 并建 `conf/`；缺少 `conf/basctl.conf` 时生成带注释、字段留空的 `0600` 模板，已存在则不覆盖。脚本内嵌在 basctl 里，随版本发布，是脚本唯一的安装/升级途径 | [usage.md](usage.md) |
| 解析与预取 | `basctl make [server.xml] <pattern>`、`basctl resolve` | 解析 webapp（`gav://` / `http(s)://` / 本地路径），生成实例目录与 jstart launch spec，再 `jstart resolve` 预取依赖，不起进程 | [start.md](start.md) |
| 起停 | `basctl start` / `basctl stop` | 非运行实例先删除整个实例目录再定端口、写 `server.info`、后台 `jstart run`；停止时按 pid 优雅退出（`--timeout` / `--force`） | [start.md](start.md)、[server-info.md](server-info.md) |
| 状态 | `basctl status` | 读 `servers/<name>/server.info` 列出运行中的实例 | [server-info.md](server-info.md) |
| 看实例日志 | `basctl logs <farm.server>` | 读 `logs/<实例>/console.out` 的尾部（`-n` 缺省 50 行，上限 2000），`-f` 持续跟随（含日志滚动后的新文件）；通道的 `log:read` 与它共用同一份读法（`bas.logs`） | [usage.md](usage.md)、[channel.md](channel.md) |
| 嵌入式跑单应用 | `basctl run --engine=<type>-<version> <app>` | 一个参数给出容器类型与版本，生成单应用 spec 后前台 `jstart run`；纯前台，Ctrl-C 退出 | [run.md](run.md) |
| Agent 协调模型 | `master` / `follower` 与 LinkMutex | 启动顺序/拓扑无关，master 串行迁移 follower，最终收敛 | [agent-coordination.md](agent-coordination.md) |
| Proxy endpoints | `server.xml` 多代理点与 webapp `endpoints` | 每台代理机一个 setline agent，按 project + IP 查询；无域名 group 使用本机 IP | [endpoints.md](endpoints.md) |
| native 可执行包 | `engine type="native"` | 通过 `basctl make native` 解压 tar.gz 到 `servers/<name>` 并 exec；没有 Tomcat 目录 | [native.md](native.md) |
| 容器入口（creator） | `basctl make <type>` | jstart `[engine] init` 协议的回调，把容器启动命令写回 spec | [engine-creator.md](engine-creator.md) |
| 环境自检 | `basctl doctor` | 检查 `java`（必需）与 `jstart`（可选提示） | [doctor.md](doctor.md) |
| 防火墙 | `basctl firewall` | 按 `server.xml` 交互式配置 firewalld 的放行端口 | [usage.md](usage.md) |
| 汇报与指令通道 | `basagent report` / `basagent` | 主动拨一条出站 WebSocket 到控制台（bashub），把本机现状（主机家底 + 活着的实例）报上去，并接收固定原语（立即上报 / 取实例或 agent 日志）；后台由发行包安装的 `basagent.service` 管理 | [channel.md](channel.md)、[channel-protocol.md](channel-protocol.md) |
| 拉取配置 | `bas.sh pull`（`basagent pull`） | 从控制端拉取 `conf/server.xml`（旧配置备份为 `server_old.xml`）；`start` / `restart` 不隐式拉取 | [usage.md](usage.md) |
| 横幅与版本 | `basctl banner` / `basctl version` | `bas.sh version` 调前者：ASCII logo + bas 引擎版本 + basctl 版本 + 本机地址 | [usage.md](usage.md) |
| 发行 | `scripts/build_deb.sh` / `build_rpm.sh`、`Dockerfile` | deb / rpm 包，以及「一机器一出口」的容器镜像 | [container.md](container.md) |

## 核心模型：三份状态与对账

| 状态 | 存在哪 | 谁写 | 谁读 |
|---|---|---|---|
| **意图** | `conf/server.xml` | 人 / `bas.sh pull` | 所有命令 |
| **现状** | `$BAS_HOME/servers/<name>/server.info` | `basctl start` / `stop`（唯一写者） | `status`、`stop`、basagent |
| **远端副本**（可选） | bashub 里那份「谁报的就覆盖谁」的现状 | `basagent report` / systemd 常驻 agent 的 `report:*` | 控制台（bashub）；basctl 自己不读 |

**路由同步** = 由 basagent 上报运行态，bashub 生成 routes，setline-agent 下载并渲染。

- **basctl 不负责对账**：`start` / `stop` 只写 `server.info`，不调用 setline 或 basagent；
  basagent 作为调用方自行上报，basctl 不感知它是否在线。
- **不是**：应用进程的 supervisor。起停仍然是 `basctl start` / `stop` 的职责。
  生命周期、不拉容器、不解析依赖。
- **容器里不做 supervisor**：实例崩了不会自动重启，也没有 `HEALTHCHECK`；要这些用编排层的探针
  与重启策略（见 [container.md](container.md)）。
- **不做路径改写**：只按路径前缀匹配，前缀原样透传；不把「应用健康」塞进 setline（它只有 TCP
  探活，表达不了「起来了但 500」）。

## 尚未定的事

已经整理进 [roadmap.md](roadmap.md)：R1 与 bashub 的汇报/指令通道、R2 漂移自动收敛、
R3 生产侧拓扑 agent。本文件只保留长期约束（上面的「边界与非目标」）。
