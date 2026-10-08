# basctl

`basctl` 是 Beangle Bas Server 的控制面命令行工具，用 D 语言实现。
它把 `conf/server.xml` 解析成可运行的 Tomcat 实例：解析 webapp（`gav://` /
`http(s)://` / 本地路径）、生成实例目录与 jstart launch spec，并渲染容器所需的
`server.xml`、`web.xml`；也可按 farm 直接拉起实例，同时提供实例状态、本地代理对账与防火墙等工具。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/features.md](docs/features.md) | 功能清单、核心模型（意图 / 现状 / 运行态与对账）、目录约定、`make` 的两种模式、与 jstart 的关系、边界与非目标 |
| [docs/usage.md](docs/usage.md) | 安装、五分钟上手、命令一览、常见场景（`run` / setline / 容器 / pull / firewall）、环境变量、排错 |
| [docs/start.md](docs/start.md) | `start` 的流程与生成的 jstart spec |
| [docs/run.md](docs/run.md) | `run`：嵌入式运行单个 webapp |
| [docs/server-info.md](docs/server-info.md) | 实例运行信息 `server.info` 的格式与生命周期、动态端口分配 |
| [docs/setline.md](docs/setline.md) | 本地代理：路由渲染、`--sync` / `--watch` 对账、`status` 的 route 列 |
| [docs/setline-config.md](docs/setline-config.md) | `<setline>` 的配置与启用规则、多份 `BAS_HOME` 共享、安全边界 |
| [docs/engine-creator.md](docs/engine-creator.md) | 容器入口（creator）：jstart `[engine] init` 协议 |
| [docs/doctor.md](docs/doctor.md) | 环境自检：`java` / `jstart` / setline 入口 |
| [docs/container.md](docs/container.md) | 容器化「一机器一出口」：镜像内容、构建、运行、信号 |
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
- `make` / `resolve` / `start` 需要本机有 `jstart`（负责构件的解析、下载与启动）；
  这些命令是否就位可以用 `basctl doctor` 自查（见 [docs/doctor.md](docs/doctor.md)）

```sh
dub build --build=release-nobounds --compiler=ldc2
dub test --compiler=ldc2
```

产物为 `target/basctl`。单元测试集中在 `test/`（每个源模块一个 `*_test.d`），用 D 内建
`unittest` + `@("...")` 具名用例。

打包成 deb / rpm（仅安装 `/usr/bin/basctl`）见 [scripts/README.md](scripts/README.md)：
`scripts/build_deb.sh`（Debian 系）与 `scripts/build_rpm.sh`（Fedora/RHEL 系），版本取自
`src/bas/main.d` 的 `basctlVersion`，与 `basctl version` 的输出一致。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。
