# 容器入口（`make` 的 creator 模式）

`basctl make <type> [协议参数...]` 是 jstart war 运行协议的**容器入口**（creator）：
它准备 webapp（解压 war、推导 docBase），把容器的**最终启动命令**写进 `--entry-out`
文件后退出，jstart 读到该文件再 exec（进程变为容器，无父子等待）。

它**不是给用户直接运行的命令**，而是 `basctl start` 生成的 spec 里 `[engine] init` 的
取值；与 `make [server.xml] <pattern>`（只生成持久部署布局与 spec，不启动）的对照见
[README](README.md)。

它由原 `engine` 模块（Java）迁移而来，用 D 重写并复用 basctl 的
解压/渲染/文件能力，因此运行入口不再需要启动一个 JVM：

| 原 Java 入口 | basctl 命令 |
|---|---|
| `org.beangle.bas.engine.EngineCreator`（公共解析/解压/argv） | `bas.enginecreator` 的公共函数 |
| `org.beangle.bas.engine.tomcat.EmbedCreator` | `basctl make tomcat` |
| `org.beangle.bas.engine.undertow.EmbedCreator` | `basctl make undertow` |
| `org.beangle.bas.engine.tomcat.ServerCreator` | `basctl make tomcat-server` |

creator 只写启动命令，容器运行时入口仍在 Java 侧：`tomcat` / `undertow` / `jetty` 分别是
`org.beangle.bas.engine.{tomcat,undertow,jetty}.Bootstrap`，`tomcat-server` 是
`org.apache.catalina.startup.Bootstrap`。

## jstart 协议

单个 webapp 时 jstart 按下述协议运行 init 命令（`[engine] init = <命令>`）：

```text
<init> --base=<dir> --entry=<war|dir> \
       --engine-classpath-file=<file> --app-classpath-file=<file> \
       --local-repo=<dir> --entry-out=<file> [--app-jvm-arg=<opt>]... [args...]
```

- `--base`：组件 base（pid、`webapps/`、`engines/` 都在其下），jstart 必传；
- `--entry`：war 文件或已解压 webapp 目录；
- `--engine-classpath-file`：jstart 写出的引擎依赖 classpath 文件（避免命令行过长）；
  `tomcat-server` 据此找发行包 zip，并把引擎 jar 复制进 `lib/`（提供 juli 实现的
  `beangle-bas-juli` 除外——它放 Catalina 系统 classpath 并顶替 `bin/tomcat-juli.jar`；
  只有 `tomcat-server` 需要 juli，`*-embed` 的日志由应用自带）；
- `--app-classpath-file`：jstart 写出的应用依赖 classpath 文件，**只在单应用模式出现**
  （`*-embed`，以及 `[app] entry` 的单应用 `tomcat-server`）；入口把它和解压后的
  `WEB-INF` 一起拼进最终 classpath；
- **多应用（`[subapp <id>]`）没有 `--app-classpath-file`**：jstart 既不写
  `<base>/engine-app.classpath` 也不传该参数，应用依赖不进 JVM classpath，由各
  `<Context>` 的 `DependencyClassLoader` 按 `-Dbas.repo` 从本地仓库解析；
- `--local-repo`：本地仓库地址，入口转成 `-Dbas.repo=`（容器内 `DependencyClassLoader`
  据此解析 war 内依赖清单）；
- `--entry-out`：最终 argv 的写出文件（NUL 分隔），jstart 读到后 exec。

最终命令参数总长超过 4000 时不直接写 argv，而是折叠成 `java @<entry-out>.args`
（java 参数文件，每行一个参数），避免超长 classpath 触发 `E2BIG`。

## 如何调用 `[engine] init`

`init` 是一条**命令行**（不是 java 类）：把引擎类型直接写在 basctl 之后即可，其余协议
参数（`--base=` / `--entry=` / 两个 classpath 文件 / `--local-repo` / `--entry-out`，以及
`[args]` 透传的参数）由 jstart 每次调用时追加在后。basctl 路径含空格时用引号包起来。

### 在 launch spec 里声明

```ini
[app]
entry = org.beangle.otk:beangle-otk-ws:war:0.0.29

[engine]
init = basctl make tomcat             # 路径含空格时写 '/opt/my dir/basctl' make tomcat
# init 之外的行是引擎 jar 清单（同 [libs] 语法）；jstart 解析后写成
# <base>/engine-deps.classpath，并以 --engine-classpath-file= 交给 creator
org.apache.tomcat.embed:tomcat-embed-core:11.0.26
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.26
org.beangle.bas:beangle-bas-engine:0.14.0

[args]
--port=8080
--path=/
```

`[engine]` 段里除 `init` 外的行是引擎 jar 清单，jstart 解析后写进
`--engine-classpath-file`；入口据此拼 classpath，**不需要**把引擎 jar 放在 basctl 自己的
classpath 上。

这些行由 `basctl start` 按 [resources/engines.ini](../resources/engines.ini) 的默认集
（`{version}` / `{bas}` 分别由 `<engine version>` / `<bas version>` 展开）与
`<engine><jar>` 合并而成：GA（`groupId:artifactId`）相同则覆盖，否则追加。例如
`<engine>` 里写 `<jar uri="gav://ch.qos.logback:logback-core:1.6.3"/>` 可给 embed 容器
补上应用日志实现。手工写 spec 时把合并结果原样列出即可。

两个开关属性（`tomcat-server` 之外的 embed 引擎也能写）：

- `websocket-support`（缺省 `true`）：`false` 时跳过 `engines.ini` 里的
  `<type>.websocket` 补充集，不再引入 `tomcat-embed-websocket` /
  `undertow-websockets` / `jetty-ee10-websocket-*` 等构件。`tomcat-server` 的
  WebSocket 随发行包提供，该属性对它无效果。
- `jsp-support`（缺省 `false`）：仅 `tomcat-server` 消费——控制精简 jasper/ecj
  与 `conf/web.xml` 里的 JSP servlet；嵌入式引擎固定屏蔽 Jasper SCI，写它无效果。

### 运行与确认

```sh
jstart run app.jstart            # 运行：init 准备环境 → jstart exec 容器
jstart run --print app.jstart    # 只打印最终启动命令，不 exec
```

`basctl start` 会自动按 `server.xml` 生成 spec（`[engine] init` 按 `<engine type>` 写成
当前 basctl 的同名 `make <type>`，可用 `bas_basctl` 覆盖路径），再委托 `jstart run`。

### 必要参数

jstart 单 webapp 时按此调用（多 webapp 见《多 webapp》一节，没有 `--entry` 等）：

```text
<init> --base=<dir> --entry=<war|dir> \
       --engine-classpath-file=<file> --app-classpath-file=<file> \
       --local-repo=<dir> --entry-out=<file> [--app-jvm-arg=<opt>]... [args...]
```

| 参数 | 必填 | 由谁提供 | 说明 |
|---|---|---|---|
| `--base=<dir>` | 是 | jstart | 组件 base（`webapps/`、`engines/`、pid 都在其下）；creator 转成 `-Dbas.home=` |
| `--entry=<war\|dir>` | 单应用必填 | jstart | war 文件或已解压目录；多 webapp 不传 |
| `--entry-out=<file>` | 是 | jstart | 最终 argv（NUL 分隔）的写出文件，jstart 读到后 exec |
| `--engine-classpath-file=<file>` | 是 | jstart | 引擎 jar 清单（`[engine]` 段除 init 外）的解析结果；`tomcat-server` 也用它找发行包 zip、把 jar 复制进 `lib/` |
| `--app-classpath-file=<file>` | 单应用有 | jstart | 应用依赖 classpath，与 `WEB-INF` 一起拼进最终 classpath |
| `--local-repo=<dir>` | 否 | jstart | 本地仓库，creator 转成 `-Dbas.repo=` |
| `--app-jvm-arg=<opt>` | 否（可重复） | jstart | `[runtime]` 与 `-D`/`-X` 参数，进最终命令的 JVM 位置 |
| `--port=` `--path=` `--jsp=` `--listener=` `--docBase=` `--Dk=v` 及其它 | 否 | spec `[args]` / 命令行透传 | 容器参数，由 creator 消费或转发 |
| `--dist=<tomcat.zip>` | 否 | spec `[args]` | `tomcat-server` 的发行包；缺省取引擎 classpath 上第一个 `.zip` |
| `--main=<class>` | 否 | spec `[args]` | 覆盖容器入口类 |

### 示例

**单 webapp · 嵌入式 tomcat**：`init = basctl make tomcat`，`[engine]` 列
`tomcat-embed-core` / `tomcat-embed-websocket`；`--path=/` → docBase `<base>/webapps/ROOT`。

**单 webapp · 嵌入式 jetty**：`init = basctl make jetty`，`[engine]` 列
`org.eclipse.jetty.ee10:*:{version}`（ee10 = Servlet 6/Jakarta）与
`beangle-bas-engine`；docBase 布局与 tomcat 一致。

**单 webapp · 全量 tomcat 发行包**：

```ini
[app]
entry = /repo/…/app.war

[engine]
init = basctl make tomcat-server
org.apache.tomcat:tomcat:zip:11.0.26          # 发行包（creator 取 classpath 上的 .zip）
org.beangle.bas:beangle-bas-engine:0.14.0
org.beangle.bas:beangle-bas-juli:0.14.0       # 容器日志桥接（dist 专用）

[args]
--port=8081
--path=/app
--jsp=false
```

**多 webapp · 全量 tomcat 发行包**（仍是 `make tomcat-server`；jstart 不写 `--entry`）：

```ini
[app]
base = /opt/bas/servers/platform.server1

[engine]
init = basctl make tomcat-server
org.apache.tomcat:tomcat:zip:11.0.26
org.beangle.bas:beangle-bas-engine:0.14.0
org.beangle.bas:beangle-bas-juli:0.14.0

[args]
--port=8081

[subapp cas]
entry = /repo/…/beangle-ems-cas_3-4.8.8.war
path = /cas

[subapp portal]
entry = /repo/…/beangle-ems-portal-4.8.8.war
path = /portal
libs = org.postgresql:postgresql:42.7.9
```

运行时 jstart 写 `<base>/engine-subapps.jstart`，creator 逐段解压 docBase、生成多个
`<Context>`；每个 Context 用自己的 `DependencyClassLoader`，应用依赖不进 JVM classpath。

**手工调试**（直接按协议调用 creator，看它写出什么）：

```sh
basctl make tomcat \
  --base=/opt/bas/servers/platform.server1 \
  --entry=/repo/org/beangle/otk/beangle-otk-ws/0.0.29/beangle-otk-ws-0.0.29.war \
  --engine-classpath-file=/opt/bas/servers/platform.server1/engine-deps.classpath \
  --app-classpath-file=/opt/bas/servers/platform.server1/engine-app.classpath \
  --local-repo=$HOME/.m2/repository \
  --entry-out=/tmp/entry.argv \
  --port=8080 --path=/

sed 's/\x00/\n/g' /tmp/entry.argv     # 查看写出的最终启动命令
```

## 类型

| 类型 | 容器来源 | 最终命令 |
|---|---|---|
| `tomcat` | spec 里的 `tomcat-embed-core` / `tomcat-embed-websocket` jar | `java ... -cp <引擎+应用+WEB-INF> org.beangle.bas.engine.tomcat.Bootstrap --base= --docBase= ...` |
| `undertow` | spec 里的 `undertow-*` jar | 同构，容器入口为 `org.beangle.bas.engine.undertow.Bootstrap` |
| `jetty` | spec 里的 `org.eclipse.jetty.ee10:*` jar | 同构，容器入口为 `org.beangle.bas.engine.jetty.Bootstrap` |
| `tomcat-server` | `--dist=<tomcat.zip>` 或引擎 classpath 上的 `.zip` | `java ... -Dcatalina.base=... -cp <bin/bootstrap.jar[:juli]> org.apache.catalina.startup.Bootstrap start` |

- 嵌入式模式（`tomcat` / `undertow` / `jetty`）一个实例跑一个 webapp；容器入口类可用 `--main=` 覆盖。
- `tomcat-server` 解压并**精简**发行包到 `<base>/engines/`（`.dist` 记录 zip 名 + 精简规则，
  未变则复用），把引擎 jar 复制进 `lib/`（`beangle-bas-juli` 除外：它上系统 classpath 并
  让发行包自带的 `bin/tomcat-juli.jar` 被删），生成
  `conf/{catalina.properties,web.xml,server.xml}`，再输出标准 catalina 启动命令。
  `--jsp=true|false` 控制 jasper/ecj 的保留，`--listener=class[:k=v;...]` 追加 Server 级
  Listener。

## 多 webapp（`[subapp <id>]`）

一个 `tomcat-server` 引擎可在同一 JVM 里部署多个 webapp（每个一个 `<Context>`）。此时 jstart
不传 `--entry`/`--path`/`--app-classpath-file`，而是把每个 webapp 写进 `--base` 下的约定文件
`engine-subapps.jstart`（launch spec 片段，一段一个 `[subapp <id>]`）——因此多应用下
**没有** `<base>/engine-app.classpath`，应用依赖全部交给各 Context 的 `DependencyClassLoader`：

jstart 多应用时的调用（与单应用的区别是**没有** `--entry`/`--path`/`--app-classpath-file`）：

```text
<init> --base=<dir> --engine-classpath-file=<file> --local-repo=<dir> \
       --entry-out=<file> [--app-jvm-arg=<opt>]... [args...]
```

计划文件（`<base>/engine-subapps.jstart`，由 jstart 写、creator 读）内容形如：

```ini
[subapp portal]
entry = /repo/org/beangle/otk/beangle-otk-ws/0.0.29/beangle-otk-ws-0.0.29.war
path = /portal
libs = org.postgresql:postgresql:42.7.9,org.slf4j:slf4j-api:2.0.19

[subapp admin]
entry = /repo/org/beangle/ems/beangle-ems-cas_3/4.8.8/beangle-ems-cas_3-4.8.8.war
path = /admin
```

- 入口按 `base` + 每段的 `path` 逐个推导 docBase（`<base>/webapps/<name>`）并解压 war，
  目录型 entry 直接作为 docBase；
- `libs`（逗号分隔 gav）原样写进该 `<Context>` 的 `ExtendableWebappLoader.libs`，容器内
  `DependencyClassLoader` 会把它叠加在该 war 的 `META-INF/beangle/dependencies` 之上
  （同名 `g:a` 以 `libs` 为准）；
- 每个 Context 用自己的 `DependencyClassLoader`，应用依赖**不进** JVM classpath（最终命令
  只用 `<bin/bootstrap.jar>`），各 webapp 的依赖互不干扰；
- `[subapp]` 的 id、归一化后的 context path 与 docBase 目录名都必须唯一（`/a/b` 与
  `/a#b` 的 context path 不同，docBase 却是同一个 `webapps/a#b`），否则入口报错；
- 只有 `tomcat-server` 支持多应用；`tomcat` / `undertow` / `jetty` 的容器 main 只接受单个
  `--docBase`，遇到多应用直接报错。

## docBase 布局（归入口负责）

入口按 `--base` + `--path` 推导 docBase 并解压 war；jstart 不镜像容器布局：

| 参数 | 布局 |
|---|---|
| `--path` 缺省或 `/` | `<base>/webapps/ROOT` |
| `--path=/a/b` | `<base>/webapps/a#b`（先归一化：去尾 `/`、折叠 `//`） |
| `--docBase=<dir>` | 直接使用该目录 |

entry 是目录时不复制、不解压，直接作为 docBase；两种情况下都会补齐空的
`WEB-INF/classes`（容器启动时要探测 classpath 上的目录资源）。

## 说明

- 入口通过 `JAVA_HOME/bin/java`（兜底 PATH 上的 `java`）启动容器；`--app-jvm-arg=` 与
  `[runtime]`/`-D`/`-X` 参数由 jstart 透传，写进最终命令的 JVM 参数位置；
- `--local-repo` 转成 `-Dbas.repo=`，`base` 转成 `-Dbas.home=`，供容器内
  `DependencyClassLoader` 解析每个 webapp 的依赖清单；
- 单应用与多应用（`[subapp <id>]`）都由本入口处理：无 `--entry` 且 `<base>/engine-subapps.jstart`
  存在即判定为多应用（单应用运行会删除该文件）。嵌入式类型不支持多应用。
