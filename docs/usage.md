# 使用

`basctl` 是本地控制面命令行：安装后准备 `conf/server.xml`，再 `doctor` / `start`。常驻远端客户端
`basagent` 单独见 [basagent.md](basagent.md)；没有 basagent 时 basctl 仍可完整本地使用。

## 安装

```sh
# 源码构建（需要 ldc2 >= 1.32、dub >= 1.34）
dub build -c basctl --build=release-nobounds --compiler=ldc2    # 产物 target/basctl

# 或者打成系统包（同时包含 basctl / basagent；basagent 的使用见 basagent.md）
scripts/build_deb.sh        # Debian 系
scripts/build_rpm.sh        # Fedora / RHEL 系
```

系统包会创建 `bas` 账号、`/var/lib/bas`、`/var/log/bas`，把控制脚本装到 `/var/lib/bas`。
打包细节见 [scripts/README.md](../scripts/README.md)。

## 五分钟上手（本机独立使用）

系统包已经铺好 `/var/lib/bas/bin` 与 `/var/lib/bas/conf`；源码或其它目录先执行 `basctl init`
铺脚本（不生成 `basctl.env`）。

```sh
basctl init /opt/bas
export BAS_HOME=/opt/bas

# 手工写 $BAS_HOME/conf/server.xml（格式见 resources/bas-1.0.0.xsd）
basctl doctor
basctl start all
basctl status
basctl stop all
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

## 接入 bashub

需要从 bashub 拉取 `server.xml`、让控制台看到本机并执行远端指令时，安装并配置 `basagent`；
配置、启动、通道原语和排障见 [basagent.md](basagent.md)。basctl 本身不调用 `basagent`，
`start` / `stop` 也不隐式拉取配置。

## 命令一览

| 命令 | 说明 |
|---|---|
| `basctl version` | 打印 `basctl <版本>`（单行纯文本，便于脚本取值） |
| `basctl banner [server.xml]` | 操作者横幅：logo + bas 引擎版本（取自 `<bas version>`）+ basctl 版本 + 本机地址；`bas.sh version` 调它。图形为纯 ASCII，只在交互终端出现，重定向到日志/管道时只剩版本行与本机地址 |
| `basctl status` | 列出 `$BAS_HOME/servers` 下运行中的实例：读 `server.info` 展示 pid、端口与各 webapp 的对外 url（引擎与启动时间只留在 `server.info` 里，不再打印）。记录 pid 已失效时，会按命令行 `-Dbas.server` + `-Dbas.home` 找回本实例的真实进程；找不到就不出现在这一节（不再打印 `stale`）。 |
| `basctl logs [server.xml] <farm.server> [-n <行数>] [-f]` | 读 `$BAS_HOME/logs/<farm.server>/console.out` 的尾部：`-n` 缺省 50 行、上限 2000；`-f` 持续跟随（Ctrl-C 退出），日志滚动后自动跟新文件。归档的旧日志在 `logs/archive/`，要查直接读文件 |
| `basctl init [--force] [--dry-run] [workdir]` | 初始化组件目录：把控制脚本铺到 `<workdir>/bin` 并建 `conf/`；**不生成 `basctl.env`**，未设置 `BAS_PRINCIPAL`/`BAS_TOKEN` 时提示使用 `/etc/bas/conf/basctl.env` |
| `basctl make [server.xml] <farm\|server\|all>` | 只准备不启动：生成 jstart spec 并 `jstart resolve` 预取依赖 |
| `basctl resolve <server.xml> [pattern...]` | 只解析 webapp，不生成实例 |
| `basctl start [server.xml] <farm\|server\|all> [--port-range=<from>-<to>]` | 为实例定端口（`<server http="0">` 时在区间内分配，缺省 `20000-29999`）、写 `server.info`、生成 jstart spec、resolve 并后台启动 |
| `basctl stop [server.xml] <farm\|server\|all> [--force] [--timeout=<sec>]` | 按 `server.info` 里的 pid 停止 `start` 启动的实例：SIGTERM 后等 `--timeout`（缺省 15 秒），`--force` 直接 SIGKILL；`server.info` 缺失时按命令行 `-Dbas.server` + `-Dbas.home` 找回本实例的残留进程并停止，`restart` 因此在 info 丢失后也能先停旧进程 |
| `basctl run --engine=<type>-<version> <app>` | 嵌入式运行单个 webapp：`--engine=tomcat-11.0.25` 同时给出容器类型与版本，生成单应用 spec 后前台 `jstart run` |
| `basctl make <type> [options]` | 容器入口（creator）：把 jstart 的 `[engine] init` 协议翻译成容器启动命令 |
| `basctl firewall [workdir]` | 按配置交互式配置 firewalld 端口 |
| `basctl proxy apply --engine=haproxy\|nginx --bundle=FILE` | 应用本地代理 ZIP：校验、安装并 reload；不访问网络，不需要 `conf/server.xml` |
| `basctl proxy status --engine=haproxy\|nginx` | 查看本地代理配置和证书文件状态 |
| `basctl doctor [server.xml]` | 检查 `java`（必需）与 `jstart`（可选提示）；必需项缺失时退出码非 0 |

## 代理配置（`basctl proxy`）

完整格式、ZIP 文件列表和 ACL/Map 选择见 [proxy.md](proxy.md)。

`basctl proxy` **只接受本地 bundle**，不下载、不依赖 `BAS_PRINCIPAL` / `BAS_TOKEN`：

```bash
sudo basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip
sudo basctl proxy apply --engine=nginx   --bundle=/tmp/proxy-bundle.zip
sudo basctl proxy status --engine=haproxy
```

`--bundle=FILE` 是 `apply` 的必填项；`--dry-run` 只打印目标路径。远程下载和触发由 basagent
负责，见 [basagent.md](basagent.md)。

## 环境自检（`basctl doctor`）

`basctl` 自己不起进程池，也不直接 exec java；`doctor` 检查本机是否有它需要的命令。

```sh
basctl doctor
basctl doctor /opt/bas/conf/server.xml
```

### 检查项

| 命令 | 要求 | 从哪找 |
|------|------|--------|
| `java` | 必需 | `$JAVA_HOME/bin/java` 优先，其次 `PATH` |
| `jstart` | 可选提示 | `beangle_jstart` 指向的命令优先，其次 `PATH` 上的 `jstart` |

`java` 缺失时退出码为 `1`；`jstart` 缺失只提示，不影响退出码。

### 输出

```text
config  /opt/bas/conf/server.xml
java    ok       /usr/bin/java (PATH)
jstart  optional not found; only commands that invoke jstart need it
doctor: all required commands are available.
```

## 组件目录初始化

`basctl init [workdir]` 把控制脚本（`env.sh`、`bas.sh`、`start.sh`、`stop.sh`、`restart.sh`）
铺到 `<workdir>/bin` 并建好 `conf/`，用于从零搭建一个 bas 组件目录。RPM/DEB 安装包已经把
同一套文件铺到标准目录 `/var/lib/bas`，不需要额外执行 `init`。标准安装中实例日志位于
`/var/log/bas`，并通过 `/var/lib/bas/logs` 符号链接保持原有路径。

**`init` 不生成 `basctl.env`。** 远程身份是主机级配置，固定放在
`/etc/bas/conf/basctl.env`（root:beangle 0640）；未设置 `BAS_PRINCIPAL`/`BAS_TOKEN` 时，
`init` 只打印提示。脚本内嵌在 basctl 里，随 basctl 版本发布，不再依赖单独的发行包：

```sh
basctl init /opt/bas           # 写入 bin/*.sh；不写 basctl.env
basctl init --force /opt/bas   # 覆盖为当前 basctl 内置的脚本
basctl init --dry-run /opt/bas # 只打印将会写入的文件
```

`bin/setenv.sh` 与 `conf/server.xml` 是用户配置，`init` 不生成。使用系统包时，升级会刷新
`bin/*.sh`；`/etc/bas/conf/basctl.env` 由安装脚本在缺失时从
`/usr/share/bas/basctl.env` 创建，不由 deb/rpm 跟踪，卸载/重装/升级都不会删除或覆盖。
源码或自定义目录默认也读 `/etc/bas/conf/basctl.env`，需要独立文件时用 `BAS_ENV_FILE`
指向自己的文件。

> **`/etc/bas/conf/basctl.env` 是主机级配置，卸载、重装、升级都不得删除或覆盖。**
> 需要迁移旧路径时由运维手工处理，程序不读取 `/var/lib/bas/conf/basctl.env`。

## 常见场景

### 开发态跑一个 war

`run` 不读 `server.xml`，一个参数给出容器与版本，前台跑起来，Ctrl-C 就退出（不写
`server.info`）：

```sh
basctl run --engine=tomcat-11.0.25  /repo/app.war
basctl run --engine=undertow-2.0.3.Final  org.beangle:app:1.0 --port=8080 --path=/app
basctl run --engine=jetty-12.1.14  /repo/app.war
basctl run --engine=tomcat-11.0.25 --print  /repo/app.war   # 只打印将要执行的 jstart 命令
```

参数、生成的 spec 与「和 `start` 的关系」见 [run.md](run.md)。

### 一机器一出口（容器）

### 开防火墙

```sh
basctl firewall /opt/bas          # 交互式地放行 server.xml 里的端口
```

## 环境变量

| 变量 | 用在哪 | 含义 |
|---|---|---|
| `BAS_HOME` | 所有命令 | 组件目录；不给就用当前工作目录。`conf/server.xml`、`servers/` 等都相对它解析 |
| `JAVA_HOME` | `doctor`、creator 写出的启动命令 | `$JAVA_HOME/bin/java` 优先于 `PATH` 上的 `java` |
| `beangle_jstart` | 用 jstart 的命令 | jstart 可执行文件路径，缺省按 `PATH` 找 `jstart` |
| `beangle_basctl` | jstart 回调 creator 时 | basctl 可执行文件路径；缺省用当前 basctl（`/proc/self/exe`），debug 构建或改名时可用它指定 |
| `M2_REPO` / `M2_REMOTE_REPO` | `run`（`--local` / `--remote` 的缺省值） | 本地 / 远端构件仓库 |

## 排错

| 现象 | 多半是 | 怎么办 |
|---|---|---|
| `Cannot find config file …` | `BAS_HOME` 不对，或 `conf/server.xml` 还没写 | `export BAS_HOME=…`，或直接用参数给配置文件路径 |
| `Route conflict on /x` | 同一个路径被**端口集合不同**的多个 webapp 认领 | 给 webapp 显式声明 `<url path="…"/>`，让每个前缀有唯一归属 |
| `Cannot run jstart …` | `jstart` 不在 `PATH` | 装 jstart，或 `export beangle_jstart=/path/to/jstart`；`basctl doctor` 会提示它是否就位（`jstart` 为可选提示，不影响 doctor 退出码，但实际调用仍会失败） |
| `status` 里看不到某个实例，但 `servers/<name>` 还在 | 进程真的不在了（崩了或手工 kill），命令行也匹配不到 | `basctl stop <name>` 清掉残留运行信息，再 `start` |
| `start` 报 `port ... is already in use` | 端口被别的进程占着（常见是未登记的残留实例） | 先 `basctl stop <name>`（会按命令行找回本实例残留进程并停掉）；报错里会带本实例残留 pid 和真正监听该端口的 pid（Linux），用 `ps -fp <pid>` 确认占用者，必要时手工停掉或换端口 |

外部命令是否就位，优先用 `basctl doctor` 自查；它的检查项与输出见下文「环境自检」。
