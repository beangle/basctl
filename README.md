# basctl

`basctl` 是 Beangle Bas Server 的本地控制面命令行工具，用 D 语言实现；同一仓库还构建
`basagent`，负责显式配置拉取与出站控制通道。
它把 `conf/server.xml` 解析成可运行的 Tomcat 实例：解析 webapp（`gav://` /
`http(s)://` / 本地路径）、生成实例目录与 jstart launch spec，并渲染容器所需的
`server.xml`、`web.xml`；也可按 farm 直接拉起实例，同时提供实例状态、本地代理对账与防火墙等工具。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/features.md](docs/features.md) | 功能清单、核心模型（意图 / 现状 / 运行态与对账）、目录约定、`make` 的两种模式、与 jstart 的关系、边界与非目标 |
| [docs/usage.md](docs/usage.md) | 安装、五分钟上手（接入 bashub / 独立使用）、命令一览、常见场景（`run` / 容器 / pull / firewall）、环境变量、排错 |
| [docs/start.md](docs/start.md) | `start` 的流程与生成的 jstart spec |
| [docs/run.md](docs/run.md) | `run`：嵌入式运行单个 webapp |
| [docs/server-info.md](docs/server-info.md) | 实例运行信息 `server.info` 的格式与生命周期、动态端口分配 |
| [docs/setline.md](docs/setline.md) | 本地代理：`<setline>` 配置、路由推送与 `status` 对账、多份 `BAS_HOME` 共享、部署与安全边界 |
| [docs/engine-creator.md](docs/engine-creator.md) | 容器入口（creator）：jstart `[engine] init` 协议 |
| [docs/doctor.md](docs/doctor.md) | 环境自检：`java`（必需）/ `jstart`（可选提示）/ setline 管理口 |
| [docs/container.md](docs/container.md) | 容器化「一机器一出口」：镜像内容、构建、运行、信号 |
| [docs/channel.md](docs/channel.md) | 汇报通道（basagent → bashub）：怎么启用、`report` / 常驻 agent、上报什么、失败怎么办 |
| [docs/channel-protocol.md](docs/channel-protocol.md) | 控制通道协议：端点与鉴权、消息信封、固定原语、节拍、未知消息的处理与扩展方式 |
| [docs/roadmap.md](docs/roadmap.md) | 待定项与下一步：R1 与 bashub 的汇报/指令通道（阶段 3 已落地、阶段 4 启停已落地、审计待补）、R2 漂移自动收敛、R3 生产侧拓扑 agent |
| [scripts/README.md](scripts/README.md) | deb / rpm 打包 |

## 版本语义

三个 `version` 互相独立，各自的来源唯一：

| 版本 | 声明位置 | 含义 |
|---|---|---|
| basctl | 编译期常量（`basctl version` 输出） | 本工具的发行号，与 bas 引擎无关 |
| bas | `conf/server.xml` 的 `<bas version>` | `beangle-bas-engine`（及 `beangle-bas-juli`）的版本 |
| 容器 | `<engine version>` | 容器版本：tomcat 为发行包版本，undertow 为 `io.undertow.ee:undertow-servlet` 版本，jetty 为 Jetty 版本 |

`<engine type>` 直接给出容器形态，取值与 creator / `engines.ini` 分节同名：`tomcat-server`
走全量发行包（多应用），`tomcat` / `undertow` / `jetty` 是嵌入式单应用。

各容器类型的默认依赖集固定在编译期内嵌的 [resources/engines.ini](resources/engines.ini)：
`{version}` / `{bas}` 分别由上述两个 version 展开；`<engine><jar>` 与默认集合并——GA
（`groupId:artifactId`）相同则覆盖，否则追加（用于自定义依赖或本地覆盖）。

## 配置格式

`conf/server.xml` 的格式由 [resources/bas-1.0.0.xsd](resources/bas-1.0.0.xsd) 定义：根元素为
`<bas>`，元素与属性一律小写连字符（如 `<snapshot-repo>`、`max-heap-size`、`run-at`）。
发布副本为 <http://beangle.github.io/schema/bas-1.0.0.xsd>，在配置根元素上加
`xsi:noNamespaceSchemaLocation="http://beangle.github.io/schema/bas-1.0.0.xsd"` 即可获得
IDE 补全与校验（见 `server.xml` 样例）。

## 构建与测试

- `ldc2` >= 1.32，`dub` >= 1.34
- `basagent` 构建与运行需要 OpenSSL 3.x（`wss://` 控制通道使用 `vibe-stream:tls/openssl-3.0`）；
  `basctl` 不链接 OpenSSL 或 vibe
- `make` / `resolve` / `start` / `run` 需要本机有 `jstart`（负责构件的解析、下载与启动）；
  `basctl doctor` 会显示它是否就位，但在 doctor 中只是可选提示，缺失不影响退出码
  （见 [docs/doctor.md](docs/doctor.md)）

```sh
dub build -c basctl --build=release-nobounds --compiler=ldc2
dub build -c basagent --build=release-nobounds --compiler=ldc2
dub test --compiler=ldc2
```

产物为 `target/basctl` 与 `target/basagent`。单元测试集中在 `test/`（每个源模块一个 `*_test.d`），用 D 内建
`unittest` + `@("...")` 具名用例。

打包成 deb / rpm（同一安装包内包含 `/usr/bin/basctl`、`/usr/bin/basagent`，并在
`/var/lib/bas` 预置 `bin/*.sh` 与 `conf/basctl.conf` 模板）见 [scripts/README.md](scripts/README.md)：
`scripts/build_deb.sh`（Debian 系）与 `scripts/build_rpm.sh`（Fedora/RHEL 系），版本取自
`src/bas/versioninfo.d` 的 `basctlVersion`，与 `basctl version` / `basagent version` 的输出一致。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。
