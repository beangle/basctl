# 使用

从零到一个跑起来的 bas：安装 basctl → 准备 `conf/server.xml` → `init` → `doctor` → `start`。
命令背后的模型与边界见 [features.md](features.md)，各功能的细节在专文里（「命令一览」与各处
链接）。

## 安装

```sh
# 源码构建（需要 ldc2 >= 1.32、dub >= 1.34）
dub build --build=release-nobounds --compiler=ldc2     # 产物 target/basctl

# 或者打成系统包（只安装 /usr/bin/basctl，不硬依赖 java / jstart / setline）
scripts/build_deb.sh        # Debian 系
scripts/build_rpm.sh        # Fedora / RHEL 系

# 或者用「一机器一出口」的容器镜像（basctl + jstart + setline + JRE）
docker run -d --name bas -p 8080:8080 -v ~/bas-work:/var/lib/bas basctl:0.0.1
```

打包与镜像细节见 [scripts/README.md](../scripts/README.md)、[container.md](container.md)。

## 五分钟上手

```sh
# 1. 铺控制脚本与 conf/ 目录（唯一来源是 basctl 自身，升级后重跑 --force 即可）
basctl init /opt/bas

# 2. 写 conf/server.xml（格式见 resources/bas-1.0.0.xsd；仓库根有一份带注释的样例）
export BAS_HOME=/opt/bas

# 3. 自查外部命令（java / jstart；启用 setline 时还有入口可达性）
basctl doctor

# 4. 起实例：先 make 预取依赖也不是必须的，start 会自己做
basctl start all                     # 或 basctl start platform / basctl start platform.server1
basctl status

# 5. 停
basctl stop all                      # 优雅 SIGTERM，--timeout=<sec>（缺省 15）/ --force 可调
```

最小 `conf/server.xml`：

```xml
<bas xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
     xsi:noNamespaceSchemaLocation="http://beangle.github.io/schema/bas-1.0.0.xsd"
     version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat-server" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="platform" engine="tomcat">
      <server name="server1" http="8081"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://org.beangle.ems:beangle-ems-portal:4.17.2" run-at="platform" path="/portal"/>
  </webapps>
</bas>
```

`<server http="0">`（或不写 `http`）表示动态端口：`start` 会在 `--port-range`（缺省
`20000-29999`）内挑一个空闲端口，记进 `servers/<name>/server.info`（见
[server-info.md](server-info.md)）。

## 命令一览

| 命令 | 说明 |
|---|---|
| `basctl version` | 打印 `basctl <版本>`（单行纯文本，便于脚本取值） |
| `basctl banner [server.xml]` | 操作者横幅：logo + bas 引擎版本（取自 `<bas version>`）+ basctl 版本 + 本机地址；`bas.sh version` 调它。图形为纯 ASCII，只在交互终端出现，重定向到日志/管道时只剩版本行与本机地址 |
| `basctl status` | 列出 `$BAS_HOME/servers` 下运行中的实例：读 `server.info` 展示 pid、端口、引擎、启动时间与各 webapp 的对外 url；pid 已不在的显示为 `stale`。配了 `<setline>` 时另起一节报名命空间、入口地址与通不通（`up` / `down`），并读一次 `GET /__setline/routes`（setline 对本机免凭据）给出 route 列（缺 / 端口对不上 / 多 / `routes in sync`） |
| `basctl init [--force] [--dry-run] [workdir]` | 初始化组件目录：把控制脚本铺到 `<workdir>/bin`，并建 `conf/` |
| `basctl make [server.xml] <farm\|server\|all>` | 只准备不启动：生成 jstart spec 并 `jstart resolve` 预取依赖 |
| `basctl resolve <server.xml> [pattern...]` | 只解析 webapp，不生成实例 |
| `basctl start [server.xml] <farm\|server\|all> [--port-range=<from>-<to>] [--no-setline]` | 为实例定端口（`<server http="0">` 时在区间内分配，缺省 `20000-29999`）、写 `server.info`、生成 jstart spec、resolve 并后台启动；配了 `<setline>` 时启动后对账路由（`--no-setline` 跳过） |
| `basctl stop [server.xml] <farm\|server\|all> [--force] [--timeout=<sec>] [--no-setline]` | 按 `server.info` 里的 pid 停止 `start` 启动的实例：SIGTERM 后等 `--timeout`（缺省 15 秒），`--force` 直接 SIGKILL；配了 `<setline>` 时停完对账路由（`--no-setline` 跳过） |
| `basctl run --engine=<type>-<version> <app>` | 嵌入式运行单个 webapp：`--engine=tomcat-11.0.25` 同时给出容器类型与版本，生成单应用 spec 后前台 `jstart run` |
| `basctl setline [server.xml] [--output=<file>] [--endpoint=<addr>]` | 把 `server.xml` 的静态拓扑渲染成 setline 配置（缺省写 `conf/setline.json` 并提示位置）：一个入口地址按路径前缀转发到各 server 的 http 端口，同一 webapp 的多实例自动成为端口列表；路由写在 `<setline hostname>` 命名空间下，入口地址按 `--endpoint` > `<setline endpoint>` 取，见 [setline.md](setline.md) |
| `basctl setline --sync` | 按运行中的实例（`server.info`，含动态端口）推整组路由给已在跑的 setline（入口地址取 `<setline endpoint>`，无缺省；入口没人应答就报错，basctl 不拉起它）；与 `basctl start` / `stop` 之后的自动对账同一条路 |
| `basctl setline --watch [--interval=<sec>]` | 常驻轮询对账（缺省每 5 秒；路由无变化就不推），直到 Ctrl-C；适合交给 systemd |
| `basctl make <type> [options]` | 容器入口（creator）：把 jstart 的 `[engine] init` 协议翻译成容器启动命令 |
| `basctl firewall [workdir]` | 按配置交互式配置 firewalld 端口 |
| `basctl pull [--remote=<url>] [workdir]` | 从控制端拉取 `conf/server.xml`（请求带 `ip:` 头，旧配置备份为 `server_old.xml`） |
| `basctl doctor [server.xml]` | 检查 `java` / `jstart`（以及启用 setline 时入口通不通）是否就位，缺件时退出码非 0，见 [doctor.md](doctor.md) |

## 组件目录初始化

`basctl init [workdir]` 把控制脚本（`env.sh`、`bas.sh`、`start.sh`、`stop.sh`、`restart.sh`）
铺到 `<workdir>/bin` 并建好 `conf/`，用于从零搭建一个 bas 组件目录。脚本内嵌在 basctl 里，
随 basctl 版本发布，不再依赖单独的发行包：

```sh
basctl init /opt/bas           # 写入 /opt/bas/bin/*.sh（已存在的脚本保留）
basctl init --force /opt/bas   # 覆盖为当前 basctl 内置的脚本
basctl init --dry-run /opt/bas # 只打印将会写入的文件
```

`bin/setenv.sh` 与 `conf/server.xml` 是用户配置（分别由用户与 `basctl pull` 维护），`init` 不
生成也不改动它们。这是脚本唯一的安装/升级途径：升级 `basctl` 后重跑 `basctl init --force`，
不再有单独的发行包 zip（原 `bas.sh update` 已移除）。

## 常见场景

### 开发态跑一个 war

`run` 不读 `server.xml`，一个参数给出容器与版本，前台跑起来，Ctrl-C 就退出（不写
`server.info`、不注册到 setline）：

```sh
basctl run --engine=tomcat-11.0.25  /repo/app.war
basctl run --engine=undertow-2.0.3.Final  org.beangle:app:1.0 --port=8080 --path=/app
basctl run --engine=jetty-12.1.14  /repo/app.war
basctl run --engine=tomcat-11.0.25 --print  /repo/app.war   # 只打印将要执行的 jstart 命令
```

参数、生成的 spec 与「和 `start` 的关系」见 [run.md](run.md)。

### 启用本地代理与自动对账

在 `conf/server.xml` 里加一个 `<setline>` 即启用（出现即启用，没有独立开关）：

```xml
<setline hostname="localhost" endpoint="127.0.0.1:8080"/>
```

- `hostname` 是路由命名空间（缺省 `localhost`，`*` 表示任意 Host）——同一台机器上多份
  `BAS_HOME` 共享一个 setline 时各占一格；`endpoint` 是这份 `BAS_HOME` 往外拨的入口地址，
  **必填**（没有缺省：端口是这台机器上的事实，写进配置才看得见）。
- setline 进程本身不归 basctl 管（由 systemd / 容器入口拉起），basctl 只推路由：

```sh
basctl setline              # 渲染 conf/setline.json
setline -f conf/setline.json   # 由 systemd / 容器入口负责常驻
basctl start platform       # 起完自动对账；--no-setline 可跳过
basctl setline --sync       # 也可以手工对一次
basctl setline --watch      # 或常驻轮询（systemd unit 示例见 setline-config.md）
```

细节、多 `BAS_HOME` 共享、安全边界见 [setline.md](setline.md) 与
[setline-config.md](setline-config.md)。

### 一机器一出口（容器）

容器里 `server.xml` 写 `<setline endpoint="127.0.0.1:8080"/>`、`<server http="0"/>` 即可：
容器内无论多少实例，对外只有 setline 那一个端口，增删 server 不用改端口映射。构建、运行与
信号处理见 [container.md](container.md)。

### 拉配置与开防火墙

```sh
basctl pull --remote=http://ctrl.internal:8080 /opt/bas   # 缺省取 $bas_remote_url
basctl firewall /opt/bas                                  # 交互式地放行 server.xml 里的端口
```

## 环境变量

| 变量 | 用在哪 | 含义 |
|---|---|---|
| `BAS_HOME` | 所有命令 | 组件目录；不给就用当前工作目录。`conf/server.xml`、`servers/` 等都相对它解析 |
| `JAVA_HOME` | `doctor`、creator 写出的启动命令 | `$JAVA_HOME/bin/java` 优先于 `PATH` 上的 `java` |
| `beangle_jstart` | 用 jstart 的命令 | jstart 可执行文件路径，缺省按 `PATH` 找 `jstart` |
| `beangle_basctl` | jstart 回调 creator 时 | basctl 可执行文件路径；缺省用自身（`/proc/self/exe`），debug 构建或改名时可用它指定 |
| `bas_remote_url` | `pull`、`server.xml` 的 `${bas_remote_url}` | 控制端地址 / 构件远端仓库地址 |
| `bas_remote_token` | `server.xml` 的 `${bas_remote_token}` | 远端仓库 token |
| `M2_REPO` / `M2_REMOTE_REPO` | `run`（`--local` / `--remote` 的缺省值） | 本地 / 远端构件仓库 |
| `micdn_token` | 传给 jstart 的下载 token | 由 `server.xml` 的 token 临时设置，命令结束后恢复原值 |

## 排错

| 现象 | 多半是 | 怎么办 |
|---|---|---|
| `Cannot find config file …` | `BAS_HOME` 不对，或 `conf/server.xml` 还没写 | `export BAS_HOME=…`，或直接用参数给配置文件路径 |
| `Route conflict on /x` | 同一个路径被**端口集合不同**的多个 webapp 认领 | 给 webapp 显式声明 `<url path="…"/>`，让每个前缀有唯一归属 |
| `no answer on …`（`--sync` / `start`） | setline 没在跑，或入口地址不对 | 看 `<setline endpoint>`；basctl 不会替你拉起 setline |
| `Cannot run jstart …` | `jstart` 不在 `PATH` | 装 jstart，或 `export beangle_jstart=/path/to/jstart`；`basctl doctor` 会直接告诉你缺哪个 |
| `status` 里某个实例是 `stale` | 进程已不在（崩了或手工 kill） | `basctl stop <name>` 清掉运行信息，再 `start`；对账会把它的路由摘掉 |
| 容器外访问不到 | 出口端口没映射，或 `endpoint` 写成了 `127.0.0.1` | `-p 8080:8080` 且容器内 `listen` 绑 `*:8080`（入口脚本默认如此），见 [container.md](container.md) |

外部命令是否就位，优先用 `basctl doctor` 自查；它的输出与退出码见 [doctor.md](doctor.md)。
