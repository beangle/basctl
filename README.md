# basctl

`basctl` 是 Beangle SAS（Simple Application Server）的控制面命令行工具，用 D 语言实现。
它把 `conf/server.xml` 解析成可运行的 Tomcat 实例：解析 webapp（`gav://` /
`http(s)://` / 本地路径）、生成实例目录与 jstart launch spec，并渲染容器所需的
`server.xml`、`web.xml`；也可按 farm 直接拉起实例，或以嵌入式模式运行单个 webapp
（war / Maven 坐标 / url），同时提供实例状态与防火墙等工具。

`engine` 模块的**容器入口**（creator，配合 jstart 的 war 运行协议）也由 basctl 提供，
见 [docs/engine-creator.md](docs/engine-creator.md)；`start` 的流程与生成的 spec 见
[docs/start.md](docs/start.md)，嵌入式 `run` 见 [docs/run.md](docs/run.md)。

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

## 命令

| 命令 | 说明 |
|---|---|
| `basctl version` | 打印版本横幅与本机地址 |
| `basctl status` | 列出 `$SAS_HOME/servers` 下运行中的实例及其监听端口 |
| `basctl make [server.xml] <farm\|server\|all>` | 只准备不启动：生成 jstart spec 并 `jstart resolve` 预取依赖 |
| `basctl resolve <server.xml> [pattern...]` | 只解析 webapp，不生成实例 |
| `basctl start [server.xml] <farm\|server\|all>` | 按 farm 生成 jstart spec、resolve 并后台启动实例 |
| `basctl stop [server.xml] <farm\|server\|all> [--force] [--timeout=<sec>]` | 停止 `start` 启动的实例（逐个 `jstart stop`） |
| `basctl run [options] <app>` | 嵌入式运行单个 webapp（war / Maven 坐标 / url）：生成单应用 spec 后前台 `jstart run` |
| `basctl make <type> [options]` | 容器入口（creator）：把 jstart 的 `[engine] init` 协议翻译成容器启动命令 |
| `basctl firewall [workdir]` | 按配置交互式配置 firewalld 端口 |
| `basctl pull [--remote=<url>] [workdir]` | 从控制端拉取 `conf/server.xml`（请求带 `ip:` 头，旧配置备份为 `server_old.xml`） |

## 目录约定

`SAS_HOME` 取 `conf/server.xml` 的上两级目录：

```
$SAS_HOME/
  conf/server.xml
  engines/<name>-<version>/     # 解压并按需裁剪后的 Tomcat
  servers/<farm>.<server>/      # 单个实例的 catalina.base
  webapps/                      # http 直链与 SNAPSHOT 覆盖的落地目录
  logs/
```

## `make` 的两种模式

`make` 是一种「准备」语义，按第一个参数区分两种输入：

| 调用 | 驱动与输入 | 产物 | 用途 |
|---|---|---|---|
| `make [server.xml] <pattern>` | `conf/server.xml`，批量选 Server | **持久**布局：`engines/<name>-<ver>/` + `servers/<name>/` + 按 server 生成一份 launch spec | 面向运维与启动前预取：只写 spec 并 `jstart resolve`，不起进程；随后 `basctl start` |
| `make <type> [options]` | jstart 的 `[engine] init` 协议，单次运行计划 | jstart base 下的 `engines/`、各 webapp 的 docBase，以及 `--entry-out` 里的**容器启动命令** | `start` / `run` / jstart 运行时的回调，用户一般不直接调用 |

`<type>` 取 `tomcat-dist`、`tomcat-embed` 或 `undertow-embed`，分别对应全量 Tomcat 发行包与
两种嵌入式容器。

## 与 jstart 的关系

构件的解析与下载委托给本机 `jstart` 命令（`fetch` / `resolve`）；`basctl` 只负责配置模型、
目录编排与配置渲染。`jstart` 不在 `PATH` 时可用环境变量 `sas_jstart` 指定其路径。

运行 war 时，jstart 按 `[engine] init` 协议调用 basctl 的 `make <type>` 并把 war 交给它：它准备
webapp、写出最终启动命令，jstart 再 exec。`basctl make tomcat-embed` /
`undertow-embed` / `tomcat-dist` 承接原 `beangle-sas` `engine` 模块的 `EmbedCreator` /
`ServerCreator`（如何调用、spec 示例、必要参数、docBase 布局与 classpath 拼装见
[docs/engine-creator.md](docs/engine-creator.md)）：

```sh
# [engine] init 直接写命令行（jstart 支持“程序 + 参数”，无需 wrapper）
init = basctl make tomcat-embed
```

`basctl start` 会自动把 `[engine] init` 写成本 basctl 的 `make tomcat-dist`
命令行，再 `jstart resolve` 校验依赖、`jstart run` 后台启动；详见
[docs/start.md](docs/start.md)。

`basctl run` 则面向单应用：它把目标写成单应用 spec（`[app] entry` +
`make <tomcat|undertow>-embed`），再前台 `jstart run` 并把终端与退出码透传给调用者；
引擎/容器版本内置在 basctl，可用 `sas_*_version` 覆盖。详见 [docs/run.md](docs/run.md)。

`server.xml` 中 `<repository>` / `<snapshot-repo>` 的 `local` / `remote` / `token` 原样透传给
`jstart`；`remote` 里的 `${sas_remote_url}`、`token` 里的 `${sas_remote_token}` 在解析阶段
展开为同名环境变量。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。
