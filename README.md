# basctl

`basctl` 是 Beangle Bas Server 的控制面命令行工具，用 D 语言实现。
它把 `conf/server.xml` 解析成可运行的 Tomcat 实例：解析 webapp（`gav://` /
`http(s)://` / 本地路径）、生成实例目录与 jstart launch spec，并渲染容器所需的
`server.xml`、`web.xml`；也可按 farm 直接拉起实例，同时提供实例状态与防火墙等工具。

`engine` 模块的**容器入口**（creator，配合 jstart 的 war 运行协议）也由 basctl 提供，
见 [docs/engine-creator.md](docs/engine-creator.md)；`start` 的流程与生成的 spec 见
[docs/start.md](docs/start.md)；`setline` 把拓扑渲染成本地 setline 代理配置，见
[docs/setline.md](docs/setline.md)；围绕 setline 的后续设想（动态端口、自动注册、对账、容器化）
见 [docs/setline-roadmap.md](docs/setline-roadmap.md)，其中的实例运行信息格式见
[docs/server-info.md](docs/server-info.md)、入口配置与启用规则见
[docs/setline-config.md](docs/setline-config.md)；basctl 自身的功能规划见
[docs/roadmap.md](docs/roadmap.md)。

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
- `make` / `resolve` / `start` 需要本机有 `jstart`（负责构件的解析、下载与启动）

```sh
dub build --build=release-nobounds --compiler=ldc2
dub test --compiler=ldc2
```

产物为 `target/basctl`。单元测试集中在 `test/`（每个源模块一个 `*_test.d`），用 D 内建
`unittest` + `@("...")` 具名用例。

打包成 deb / rpm（仅安装 `/usr/bin/basctl`）见 [scripts/README.md](scripts/README.md)：
`scripts/build_deb.sh`（Debian 系）与 `scripts/build_rpm.sh`（Fedora/RHEL 系），版本取自
`src/bas/main.d` 的 `basctlVersion`，与 `basctl version` 的输出一致。

## 命令

| 命令 | 说明 |
|---|---|
| `basctl version` | 打印 `basctl <版本>`（单行纯文本，便于脚本取值） |
| `basctl banner [server.xml]` | 操作者横幅：logo + bas 引擎版本（取自 `<bas version>`）+ basctl 版本 + 本机地址；`bas.sh version` 调它。图形为纯 ASCII，只在交互终端出现，重定向到日志/管道时只剩版本行与本机地址 |
| `basctl status` | 列出 `$BAS_HOME/servers` 下运行中的实例：读 `server.info` 展示 pid、端口、引擎、启动时间与各 webapp 的对外 url；pid 已不在的显示为 `stale` |
| `basctl init [--force] [--dry-run] [workdir]` | 初始化组件目录：把控制脚本铺到 `<workdir>/bin`，并建 `conf/` |
| `basctl make [server.xml] <farm\|server\|all>` | 只准备不启动：生成 jstart spec 并 `jstart resolve` 预取依赖 |
| `basctl resolve <server.xml> [pattern...]` | 只解析 webapp，不生成实例 |
| `basctl start [server.xml] <farm\|server\|all> [--port-range=<from>-<to>]` | 为实例定端口（`<server http="0">` 时在区间内分配，缺省 `20000-29999`）、写 `server.info`、生成 jstart spec、resolve 并后台启动 |
| `basctl stop [server.xml] <farm\|server\|all> [--force] [--timeout=<sec>]` | 按 `server.info` 里的 pid 停止 `start` 启动的实例：SIGTERM 后等 `--timeout`（缺省 15 秒），`--force` 直接 SIGKILL |
| `basctl run --engine=<type>-<version> <app>` | 嵌入式运行单个 webapp：`--engine=tomcat-11.0.25` 同时给出容器类型与版本，生成单应用 spec 后前台 `jstart run` |
| `basctl setline [server.xml] [--output=<file>] [--listen=<addr>]` | 把服务拓扑渲染成 setline 配置（缺省写 `conf/setline.json` 并提示位置）：一个入口地址按路径前缀转发到各 server 的 http 端口，同一 webapp 的多实例自动成为端口列表，见 [docs/setline.md](docs/setline.md) |
| `basctl setline --sync` / `--stop [--force]` | 把整组路由推给正在跑的 setline（入口空着就地拉起来）／停掉 basctl 就地启动的那个，见 [docs/setline.md](docs/setline.md) |
| `basctl make <type> [options]` | 容器入口（creator）：把 jstart 的 `[engine] init` 协议翻译成容器启动命令 |
| `basctl firewall [workdir]` | 按配置交互式配置 firewalld 端口 |
| `basctl pull [--remote=<url>] [workdir]` | 从控制端拉取 `conf/server.xml`（请求带 `ip:` 头，旧配置备份为 `server_old.xml`） |

## 组件目录初始化

`basctl init [workdir]` 把控制脚本（`env.sh`、`bas.sh`、`start.sh`、`stop.sh`、
`restart.sh`）铺到 `<workdir>/bin` 并建好 `conf/`，用于从零搭建一个 bas 组件目录。
脚本内嵌在 basctl 里，随 basctl 版本发布，不再依赖单独的发行包：

```sh
basctl init /opt/bas          # 写入 /opt/bas/bin/*.sh（已存在的脚本保留）
basctl init --force /opt/bas  # 覆盖为当前 basctl 内置的脚本
basctl init --dry-run /opt/bas
```

`bin/setenv.sh` 与 `conf/server.xml` 是用户配置（分别由用户与 `basctl pull` 维护），
`init` 不生成也不改动它们。这是脚本唯一的安装/升级途径：升级 `basctl` 后重跑
`basctl init --force`，不再有单独的发行包 zip（原 `bas.sh update` 已移除）。

## 目录约定

`BAS_HOME` 取 `conf/server.xml` 的上两级目录：

```
$BAS_HOME/
  conf/server.xml
  conf/setline.json             # 本机 setline 入口配置（<setline> 启用时，归 setline 进程所有）
  engines/<name>-<version>/     # 解压并按需裁剪后的 Tomcat
  servers/<farm>.<server>/      # 单个实例的 catalina.base（server.info 记运行信息：pid / 端口 / webapp / url）
  webapps/                      # http 直链与 SNAPSHOT 覆盖的落地目录
  run/                          # 机器级守护进程的运行态（如就地启动的 setline.pid）
  logs/
```

实例的端口在启动前就定下来：`<server http>` 有值就用它，为 `0`（或缺省）时由 `basctl start` 在
`--port-range`（缺省 `20000-29999`）内分配一个空闲端口，两种情况下都记进 `servers/<name>/server.info`
——`start` / `stop` / `status` 与 setline 的路由对账都读这一份「现状」，不再用 `ss` 反查端口。
格式与生命周期见 [docs/server-info.md](docs/server-info.md)。

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
目录编排与配置渲染。`jstart` 不在 `PATH` 时可用环境变量 `bas_jstart` 指定其路径。

运行 war 时，jstart 按 `[engine] init` 协议调用 basctl 的 `make <type>` 并把 war 交给它：它准备
webapp、写出最终启动命令，jstart 再 exec。`basctl make tomcat` / `undertow` / `jetty` /
`tomcat-server` 承接原 `engine` 模块的 creator 逻辑（如何调用、spec 示例、必要参数、
docBase 布局与 classpath 拼装见
[docs/engine-creator.md](docs/engine-creator.md)）：

```sh
# [engine] init 直接写命令行（jstart 支持“程序 + 参数”，无需 wrapper）
init = basctl make tomcat
```

`basctl start` 会根据 `<engine type>` 自动把 `[engine] init` 写成对应 creator 的
`make <type>` 命令行（`tomcat-server` 多应用、`tomcat` / `undertow` / `jetty` 单应用），
再 `jstart resolve` 校验依赖、`jstart run` 后台启动；详见 [docs/start.md](docs/start.md)。

`basctl run` 面向单应用快速运行：一个 `--engine=<type>-<version>`（如
`tomcat-11.0.25`）同时给出容器类型与版本，bas 引擎版本取 basctl 内置默认
（`--bas=` 可覆盖），依赖集与 `start` 共用 `engines.ini`；详见 [docs/run.md](docs/run.md)。

`server.xml` 中 `<repository>` / `<snapshot-repo>` 的 `local` / `remote` / `token` 原样透传给
`jstart`；`remote` 里的 `${bas_remote_url}`、`token` 里的 `${bas_remote_token}` 在解析阶段
展开为同名环境变量。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。
