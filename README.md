# basctl

`basctl` 是 Beangle SAS（Simple Application Server）的控制面命令行工具，用 D 语言实现。
它把 `conf/server.xml` 解析成可运行的 Tomcat 实例目录：解析 webapp（`gav://` /
`http(s)://` / 本地路径）、生成 `engines/` 与 `servers/`，并渲染 Tomcat 的
`server.xml`、`web.xml`、`setenv.sh`；也可按 farm 生成 jstart launch spec 并直接拉起实例，
同时提供实例状态与防火墙等工具。

本仓库由 `beangle-sas` 的 `core`（Scala）子项目迁移而来，**Proxy 相关能力不迁移**；
`engine` 模块的**引擎入口**（creator，配合 jstart 的 war 运行协议）也在此用 D 重写。
逐文件映射与已知差异见 [docs/core-migration.md](docs/core-migration.md)，引擎入口见
[docs/engine-creator.md](docs/engine-creator.md)，`start` 的流程与生成的 spec 见
[docs/start.md](docs/start.md)；控制面与运行时拆分需求见
[docs/requirements-sas-control-plane.md](docs/requirements-sas-control-plane.md)。

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
| `basctl make <server.xml> <farm\|server\|all>` | 解析 webapp 并生成 engines / servers |
| `basctl resolve <server.xml> [pattern...]` | 只解析 webapp，不生成实例 |
| `basctl start [server.xml] <farm\|server\|all>` | 按 farm 生成 jstart spec、resolve 并后台启动实例 |
| `basctl engine <type> [options]` | 引擎入口（creator）：把 jstart 的 `[engine] init` 协议翻译成容器启动命令 |
| `basctl firewall [workdir]` | 按配置交互式配置 firewalld 端口 |

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

## 与 jstart 的关系

构件的解析与下载委托给本机 `jstart` 命令（`fetch` / `resolve`）；`basctl` 只负责配置模型、
目录编排与配置渲染。`jstart` 不在 `PATH` 时可用环境变量 `sas_jstart` 指定其路径。

运行 war 时，jstart 按 `[engine] init` 协议调用引擎入口并把 war 交给它：入口准备 webapp、
写出最终启动命令，jstart 再 exec。`basctl engine tomcat-embed` / `undertow-embed` /
`tomcat-dist` 承接原 `beangle-sas` `engine` 模块的 `EmbedCreator` / `ServerCreator`
（如何调用、wrapper/spec 示例、必要参数、docBase 布局与 classpath 拼装见
[docs/engine-creator.md](docs/engine-creator.md)）：

```sh
# [engine] init 指向的一行 wrapper
exec basctl engine tomcat-embed "$@"
```

`basctl start` 会自动生成这样的 spec 与 wrapper（`[engine] init`），再 `jstart resolve`
校验依赖、`jstart run` 后台启动；详见 [docs/start.md](docs/start.md)。

`server.xml` 中 `<Repository>` / `<SnapshotRepo>` 的 `local` / `remote` / `token` 原样透传给
`jstart`；`remote` 里的 `${sas_remote_url}`、`token` 里的 `${sas_remote_token}` 在解析阶段
展开为同名环境变量。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。
