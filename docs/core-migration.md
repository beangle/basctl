# core 模块迁移进度（basctl）

本文档记录 `beangle-sas` 的 `core` 子项目（Scala）向 `basctl`（D）的迁移映射。
**Proxy 相关能力按约定不迁移**：`config/Proxy.scala`、`tool/Proxy.scala`、
`tool/ProxyGenerator.scala`，以及 `Container` 中生成 proxy backend / `entryPoint`
的部分。

## 模块映射

| Scala（core/src/main/scala/org/beangle/sas） | basctl（src/bas） | 状态 |
|---|---|---|
| `Logo.scala` | `banner.d`（`logo`） | 完成 |
| `config/ArchiveURI.scala`、`config/Artifact.scala` | `artifact.d` | 完成 |
| `config/Container.scala`（去 Proxy） | `config.d`（`Container` + 解析 + 查询） | 完成 |
| `config/Engine.scala`（Engine/Listener/Context/Loader/JarScanner/Jar） | `config.d` | 完成 |
| `config/Farm.scala`（Farm/Server） | `config.d` | 完成 |
| `config/Host.scala`、`config/Resource.scala`、`config/Webapp.scala`、`config/Repository.scala`、`config/Connector.scala` | `config.d` | 完成 |
| `daemon/ServerStatus.scala` | `serverstatus.d` | 完成 |
| `tool/Jstart.scala` | `jstart.d` | 完成 |
| `tool/Resolver.scala` | `resolver.d` | 完成 |
| `tool/Maker.scala` | `maker.d` | 完成 |
| `maker/TomcatMaker.scala` | `tomcatmaker.d` | 完成 |
| `tool/SasTool.scala`（`download`/`rollLog`/`detectExecution`） | `download.d`、`serverstatus.d` | 完成 |
| `tool/Aes.scala` | — | 不迁移（`aes` 子命令已移除） |
| `tool/Firewall.scala` | `firewall.d`、`shellenv.d` | 完成 |
| `tool/Version.scala` | `banner.d` + `net.d` | 完成 |
| `tool/ShellEnv.scala` | `shellenv.d`（不含 `toXml`） | 部分 |
| `tool/Proxy.scala`、`tool/ProxyGenerator.scala`、`config/Proxy.scala` | — | 明确不迁移 |

## 生成物替代

Scala 用 Freemarker 模板渲染；basctl 用 D 代码直接渲染，输出等价：

| 模板 | 替代 |
|---|---|
| `tomcat/conf/server.xml.ftl` | `render.d` `renderServerXml` |
| `tomcat/conf/web.xml.ftl` | `render.d` `renderWebXml` + `mimetypes.d` |
| `sas/setenv.sh.ftl` | `render.d` `renderSetenvSh` |
| `sas/firewall.ftl` | `render.d` `renderFirewallConf` |
| `tomcat/conf/catalina.properties` | 内嵌资源（`resources/tomcat/conf/`） |
| `sas/mime.types` | 内嵌资源（`resources/sas/`） |

## CLI

| 命令 | 对应 Scala 入口 |
|---|---|
| `basctl version` | `tool.Version.main` |
| `basctl status` | `daemon.ServerStatus` + `sas.sh status` |
| `basctl make <server.xml> <farm\|server\|all>` | `tool.Maker.main` |
| `basctl resolve <server.xml> [pattern...]` | `tool.Resolver.main` |
| `basctl start [server.xml] <farm\|server\|all>` | `start.sh` + `tool.Maker.main`（改为生成 jstart spec 并委托 jstart 启动，见 [start.md](start.md)） |
| `basctl engine <type> [options]` | `engine`（Java）的 `EngineCreator` / `tomcat.EmbedCreator` / `undertow.EmbedCreator` / `tomcat.ServerCreator` |
| `basctl firewall [workdir]` | `tool.Firewall.main` |

## engine 模块的引擎入口（creator）迁移

`beangle-sas` 的 `engine` 模块（Java，配合 jstart 的 war 运行协议）里的**引擎入口**也用 D
重写进 basctl，运行入口因此不再需要启动一个 JVM。映射与差异见
[engine-creator.md](engine-creator.md)：

| Java（engine/src/main/java/org/beangle/sas/engine） | basctl（src/bas） | 状态 |
|---|---|---|
| `EngineCreator`（协议解析 / docBase / 解压 / argv） | `enginecreator.d` 的公共函数 | 完成 |
| `tomcat.EmbedCreator` | `basctl engine tomcat-embed` | 完成 |
| `undertow.EmbedCreator` | `basctl engine undertow-embed` | 完成 |
| `tomcat.ServerCreator` | `basctl engine tomcat-dist`（复用 `tomcatmaker.d` 的精简规则与 `render.d` 资源） | 完成（单/多应用） |

已知差异：

- 多 webapp（`[subapp <id>]`）在 D 版中新增支持：jstart 把各 subapp 写进
  `<base>/engine-subapps.jstart`，`tomcat-dist` 逐个建 `<Context>`（各用自己的
  `DependencyClassLoader`，`libs` 透传到 Context 的 Loader）；迁移前的 Java
  `ServerCreator` 只处理单个 webapp；
- `tomcat.ServerCreator` 原先把 `System.getProperty("java.class.path")` 当作引擎 classpath，
  D 版改为读取 jstart 的 `--engine-classpath-file=`，与新的 `[engine] init` 协议一致；
- 引擎属性 `--local-repo=` 统一转成 `-Dsas.repo=`（并在 `-Dsas.home=` 注入组件 base），
  供容器内 `DependencyClassLoader` 使用。

## 尚未迁移 / 已知差异

- **Proxy 全链路**：按约定不迁移（含 `Container` 的 backend 生成与 `Webapp.entryPoint`）。
- `ShellEnv.toXml`（整份 `server.xml` 再渲染）未实现；当前只需读取配置。
- `Container.runnableWebapps`（按 `entryPoint` 过滤）未实现，其依赖 Proxy。

## 真实 jstart 端到端验证

以 `~/workspace/beangle/jstart` 的构建产物为外部命令（`sas_jstart=/path/to/jstart`），
用 `make` / `resolve` 验证了 `Resolver` 各条分支（`dub test` 46 项全绿，测试集中在
`test/`，每个源模块一个 `*_test.d`）：

| 场景 | server.xml 写法 | 结果 |
|---|---|---|
| gav webapp（jar→war） | `uri="gav://org.beangle.ems:beangle-ems-cas_3:war:4.8.8"` | `jstart fetch` 命中本地仓库，docBase 指向 war，`unpackWAR="false"` |
| 强制解包 | 同上 + `unpack="true"` | 解包到 `servers/<srv>/webapps/<path>`，docBase 改为该目录 |
| gav 无依赖 war（`resolveSupport` 默认 true） | 临时仓库中自造的最小 war | `jstart resolve` 退出 0，实例正常生成 |
| 依赖解析失败 | 不存在的 gav | 打印 `Cannot resolve <srv>`，`servers/<srv>/error` 写入 gav；`make` 退出码 0（与 Scala `Maker` 一致） |
| http(s) 直链 | 中央仓库一个 jar 直链 | 经 `curl` 落到 `$SAS_HOME/webapps/`，docBase 指向该文件 |
| SNAPSHOT 本地覆盖 | `SnapshotRepo` + `$SAS_HOME/webapps/<file>` 中较新的同名 war | docBase 改用本地覆盖的 war |
| `<Webapp libs>` | `libs="org.postgresql:postgresql:42.7.9"` | 逐个 `jstart fetch`，失败仅告警不阻断（与 Scala 一致） |

多应用（`[subapp <id>]`）也做过真实端到端验证：用上述 `jstart` 跑一个声明两个 subapp 的
spec（`portal` → `/portal`、`admin` → `/admin`），`basctl engine tomcat-dist` 生成带两个
`<Context>` 的 `server.xml` 并启动成功，两个上下文各自返回本应用的首页。两个 war 的
`WEB-INF/classes/META-INF/beangle/dependencies` 各写一条不同的 gav、再给 `portal` 加
`libs = org.slf4j:slf4j-api:2.0.19`：日志显示 `admin` 上下文只追加自己的 1 个 jar、
`portal` 上下文追加自己的 1 个加 `libs` 的 1 个（资源 URL 分别指向各自 docBase），
即每个 Context 用自己的 `DependencyClassLoader` 解析各自的清单，`libs` 叠加其上。

`basctl start` 的整链路也做过真实端到端验证：用一份含 `<ServerOptions>` / `maxHeapSize` /
两个 `<Webapp>`（其中一个带 `libs`）的 `server.xml` 执行 `basctl start <xml> <farm>`，
生成的 spec 依次带上 tomcat 发行包、引擎 jar、引擎 jar 清单里的 scala、farm 的 `<Jar>`、
`[runtime]` 与两段 `[subapp]`；`jstart resolve` 通过后后台启动成功，两个上下文各自返回
本应用首页，`SERVER_PID` 与 `servers/<name>/logs` 软链就位，`basctl status` 能列出
pid 与端口（详见 [start.md](start.md)）。
