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
| `tool/Aes.scala` | `aes.d`（纯 D AES-128/ECB/PKCS5） | 完成 |
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
| `basctl aes <key> <plain\|encoded>` | `tool.Aes.main` |
| `basctl firewall [workdir]` | `tool.Firewall.main` |

## 尚未迁移 / 已知差异

- **Proxy 全链路**：按约定不迁移（含 `Container` 的 backend 生成与 `Webapp.entryPoint`）。
- `ShellEnv.toXml`（整份 `server.xml` 再渲染）未实现；当前只需读取配置。
- `Container.runnableWebapps`（按 `entryPoint` 过滤）未实现，其依赖 Proxy。

## 真实 jstart 端到端验证

以 `~/workspace/beangle/jstart` 的构建产物为外部命令（`sas_jstart=/path/to/jstart`），
用 `make` / `resolve` 验证了 `Resolver` 各条分支（`dub test` 33 项全绿）：

| 场景 | server.xml 写法 | 结果 |
|---|---|---|
| gav webapp（jar→war） | `uri="gav://org.beangle.ems:beangle-ems-cas_3:war:4.8.8"` | `jstart fetch` 命中本地仓库，docBase 指向 war，`unpackWAR="false"` |
| 强制解包 | 同上 + `unpack="true"` | 解包到 `servers/<srv>/webapps/<path>`，docBase 改为该目录 |
| gav 无依赖 war（`resolveSupport` 默认 true） | 临时仓库中自造的最小 war | `jstart resolve` 退出 0，实例正常生成 |
| 依赖解析失败 | 不存在的 gav | 打印 `Cannot resolve <srv>`，`servers/<srv>/error` 写入 gav；`make` 退出码 0（与 Scala `Maker` 一致） |
| http(s) 直链 | 中央仓库一个 jar 直链 | 经 `curl` 落到 `$SAS_HOME/webapps/`，docBase 指向该文件 |
| SNAPSHOT 本地覆盖 | `SnapshotRepo` + `$SAS_HOME/webapps/<file>` 中较新的同名 war | docBase 改用本地覆盖的 war |
| `<Webapp libs>` | `libs="org.postgresql:postgresql:42.7.9"` | 逐个 `jstart fetch`，失败仅告警不阻断（与 Scala 一致） |
