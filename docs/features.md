# 功能总览（basctl）

`basctl` 是 Beangle Bas Server（下称 bas）的**本地控制面命令行**：输入只有一份
`conf/server.xml`，输出是「能跑起来的实例」和「能对外转发的路由」。本文只讲 basctl；
常驻远端客户端 `basagent` 单独见 [basagent.md](basagent.md)。

## 能力清单

| 能力 | 命令 | 做什么 | 详情 |
|---|---|---|---|
| 组件目录初始化 | `basctl init` | 把 `env.sh` / `bas.sh` / `start.sh` / `stop.sh` / `restart.sh` 铺到 `<workdir>/bin` 并建 `conf/`；**不生成 `basctl.env`** | [usage.md](usage.md) |
| 解析与预取 | `basctl make` / `basctl resolve` | 解析 webapp（`gav://` / `http(s)://` / 本地路径），生成实例目录与 jstart launch spec，再预取依赖，不起进程 | [start.md](start.md) |
| 开机自启 | `basctl autostart` | 按 `<auto-start>` / `wait-for` 逐个启动本机节点；不并发 | [usage.md](usage.md) |
| 起停 | `basctl start` / `stop` | 定端口、写 `server.info`、后台 `jstart run`；停止时按 pid 优雅退出 | [start.md](start.md)、[server-info.md](server-info.md) |
| 状态 | `basctl status` | 读 `servers/<name>/server.info` 列出运行中的实例 | [server-info.md](server-info.md) |
| 看实例日志 | `basctl logs <farm.server>` | 读 `logs/<实例>/console.out` 尾部；`-f` 持续跟随 | [usage.md](usage.md) |
| 嵌入式跑单应用 | `basctl run --engine=<type>-<version> <app>` | 生成单应用 spec 后前台 `jstart run` | [run.md](run.md) |
| native 可执行包 | `basctl make native` | 解压 tar.gz 到 `servers/<name>` 并 exec | [native.md](native.md) |
| 容器入口（creator） | `basctl make <type>` | 把 jstart `[engine] init` 协议翻译成容器启动命令 | [engine-creator.md](engine-creator.md) |
| 环境自检 | `basctl doctor` | 检查 `java`（必需）与 `jstart`（可选提示） | [usage.md](usage.md) |
| 防火墙 | `basctl firewall` | 按 `server.xml` 交互式配置 firewalld 端口 | [usage.md](usage.md) |
| 代理配置 | `basctl proxy apply/status` | 应用本地代理 ZIP bundle，校验、落盘、reload；不访问网络 | [proxy.md](proxy.md) |
| 横幅与版本 | `basctl banner` / `version` | ASCII logo、bas 版本、basctl 版本、本机地址 | [usage.md](usage.md) |
| 发行 | `scripts/build_deb.sh` / `build_rpm.sh` | deb / rpm 包 | [scripts/README.md](../scripts/README.md) |

## 核心模型：意图与现状

| 状态 | 存在哪 | 谁写 | 谁读 |
|---|---|---|---|
| **意图** | `conf/server.xml` | 人 / 外部配置分发 | 所有命令 |
| **现状** | `$BAS_HOME/servers/<name>/server.info` | `basctl start` / `stop`（唯一写者） | `status`、`stop` |

- basctl 不负责对账，也不是应用进程的 supervisor；起停仍是 `start` / `stop` 的职责。
- 实例崩了不会自动重启；需要时用编排层探针与重启策略。
