# 使用

从零到一个跑起来的 bas：安装 basctl → 准备组件目录（系统包已预置 `/var/lib/bas`）→ 选择接入
bashub 或本机独立配置 → `doctor` → `start`。
命令背后的模型与边界见 [features.md](features.md)，各功能的细节在专文里（「命令一览」与各处
链接）。

## 安装

```sh
# 源码构建（需要 ldc2 >= 1.32、dub >= 1.34）
dub build -c basctl --build=release-nobounds --compiler=ldc2    # 产物 target/basctl
dub build -c basagent --build=release-nobounds --compiler=ldc2  # 产物 target/basagent

# 或者打成系统包（安装 /usr/bin/basctl、/usr/bin/basagent 与 basagent.service）
scripts/build_deb.sh        # Debian 系
scripts/build_rpm.sh        # Fedora / RHEL 系

# 或者用「一机器一出口」的容器镜像（basctl + jstart + setline + JRE）
docker run -d --name bas -p 8080:8080 -v ~/bas-work:/var/lib/bas basctl:0.0.1
```

打包与镜像细节见 [scripts/README.md](../scripts/README.md)、[container.md](container.md)。
系统包会创建 `bas:beangle` 账号、`/var/lib/bas`、`/var/log/bas`，把控制脚本与
`conf/basctl.conf` 模板装到 `/var/lib/bas`，并启用 `basagent.service`；basagent 不允许以
root 运行。

## 五分钟上手

先选一种运行方式：由 bashub 管配置，或只在本机独立使用。系统包已经铺好
`/var/lib/bas/bin` 与 `/var/lib/bas/conf`；从源码安装或使用其它目录时，才需要先执行
`basctl init`。

### 方式一：接入 bashub（推荐）

bashub 是配置与实例的远端权威：`bas.sh pull` 从它拉取 `conf/server.xml`，常驻 `basagent`
把本机现状报回去，并接收日志 / 启停指令。先在 bashub 里为这台机器建好 Profile，再填写本地配置：

```sh
# 1. 系统包已预置控制脚本与 basctl.conf 模板；源码安装或其它目录执行：
# sudo -u bas -H basctl init /var/lib/bas

# 2. 填写模板（已按 0600 安装、含字段说明）
sudo -u bas -H "${EDITOR:-vi}" /var/lib/bas/conf/basctl.conf
```

模板结构如下，把三个空值填成 bashub 中这台机器对应的值：

```ini
[remote]
url = https://hub.example.com
profile = openurp.prod
token = 9f8e7d6c5b4a39281706f5e4d3c2b1a0
```

```sh
# 3. 显式拉取控制台生成的 server.xml，再自查、启动
sudo -u bas -H /var/lib/bas/bin/bas.sh pull
sudo -u bas -H basctl doctor
sudo -u bas -H basctl start all
sudo -u bas -H basctl status

# 4. 手工报一次，确认控制台能看见这台机器
sudo -u bas -H basagent report /var/lib/bas/conf/server.xml

# 5. 启动常驻通道（RPM/DEB 已安装并 enable 该服务）
sudo systemctl start basagent.service
sudo -u bas -H tail -f /var/log/bas/agent/console.out
```

把 `url` / `profile` / `token` 换成 bashub 中这台机器对应 Profile 的值：`profile` 必须是
`org.name`，`token` 就是 `Profile.key`。三项齐全才会启用 `pull` 与汇报通道；缺项时按未接入
处理，不影响本地 `start` / `stop`。`bin/start.sh` / `bin/restart.sh` 只读本地配置，不会隐式
拉取；需要更新时显式执行 `bin/bas.sh pull`。字段说明见下方「远程配置」，失败行为见
[channel.md](channel.md)。

### 方式二：不接 bashub，单独使用

只需要 `conf/server.xml`；`init` 生成的空 `conf/basctl.conf` 不影响本地命令：

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

需要把本机多个实例汇总到一个入口时，再在 `server.xml` 加 `<setline port="10080"/>`。
setline 与 bashub 通道互不依赖，配置、部署与安全边界统一见 [setline.md](setline.md)。

## 命令一览

| 命令 | 说明 |
|---|---|
| `basctl version` | 打印 `basctl <版本>`（单行纯文本，便于脚本取值） |
| `basctl banner [server.xml]` | 操作者横幅：logo + bas 引擎版本（取自 `<bas version>`）+ basctl 版本 + 本机地址；`bas.sh version` 调它。图形为纯 ASCII，只在交互终端出现，重定向到日志/管道时只剩版本行与本机地址 |
| `basctl status` | 列出 `$BAS_HOME/servers` 下运行中的实例：读 `server.info` 展示 pid、端口与各 webapp 的对外 url（引擎与启动时间只留在 `server.info` 里，不再打印）；pid 已不在的显示为 `stale`。配了 `<setline>` 时另起一节报名命空间、管理口地址与通不通（`up` / `down`），并读一次 `GET /_setline/routes`（本机来源免凭据）给出 route 列（缺 / 端口对不上 / 多 / `routes in sync`） |
| `basctl logs [server.xml] <farm.server> [-n <行数>] [-f]` | 读 `$BAS_HOME/logs/<farm.server>/console.out` 的尾部：`-n` 缺省 50 行、上限 2000；`-f` 持续跟随（Ctrl-C 退出），日志滚动后自动跟新文件。归档的旧日志在 `logs/archive/`，要查直接读文件 |
| `basctl init [--force] [--dry-run] [workdir]` | 初始化组件目录：把控制脚本铺到 `<workdir>/bin`，并生成带注释的 `conf/basctl.conf` 模板（已存在则不覆盖） |
| `basctl make [server.xml] <farm\|server\|all>` | 只准备不启动：生成 jstart spec 并 `jstart resolve` 预取依赖 |
| `basctl resolve <server.xml> [pattern...]` | 只解析 webapp，不生成实例 |
| `basctl start [server.xml] <farm\|server\|all> [--port-range=<from>-<to>] [--no-setline]` | 为实例定端口（`<server http="0">` 时在区间内分配，缺省 `20000-29999`）、写 `server.info`、生成 jstart spec、resolve 并后台启动；配了 `<setline>` 时启动后对账路由（`--no-setline` 跳过） |
| `basctl stop [server.xml] <farm\|server\|all> [--force] [--timeout=<sec>] [--no-setline]` | 按 `server.info` 里的 pid 停止 `start` 启动的实例：SIGTERM 后等 `--timeout`（缺省 15 秒），`--force` 直接 SIGKILL；`server.info` 缺失时按命令行 `-Dbas.server` + `-Dbas.home` 找回本实例的残留进程并停止，`restart` 因此在 info 丢失后也能先停旧进程；配了 `<setline>` 时停完对账路由（`--no-setline` 跳过） |
| `basctl run --engine=<type>-<version> <app>` | 嵌入式运行单个 webapp：`--engine=tomcat-11.0.25` 同时给出容器类型与版本，生成单应用 spec 后前台 `jstart run` |
| `basctl setline [server.xml]` | 把**运行中实例**（`server.info`，含动态端口）的路由整组推给已在跑的 setline（管理口端口只从 `<setline port>` 来，无缺省、无命令行覆盖；没人应答就报错，basctl 不拉起它、也不生成 setline 的配置；配置里没有 `<setline>` 就报"没启用 setline"）；与 `basctl start` / `stop` 之后的自动对账同一条路 |
| `basctl setline --sync` | 同上（显式写法，便于脚本与记忆）；只推一次，推完即退出，没有常驻模式——路由变化的时机就是实例的启停 |
| `basctl make <type> [options]` | 容器入口（creator）：把 jstart 的 `[engine] init` 协议翻译成容器启动命令 |
| `basctl firewall [workdir]` | 按配置交互式配置 firewalld 端口 |
| `bas.sh pull` | 按 `conf/basctl.conf` 的 `[remote]` 拉取 `conf/server.xml`（底层调用 `basagent pull`）：地址为 `<url>/api/bashub/config/<profile>/server`，请求用 `Authorization: Bearer <profile>:<token>`；旧配置备份为 `server_old.xml`。未配置 `[remote]` 时告警并以 0 退出，配置无效或下载失败时非 0 |
| `basagent report [server.xml]` | 连一次控制台（bashub）报一次主机与实例现状后退出；地址与凭证都取同目录 `basctl.conf` 的 `[remote]`，报上去了退出码才是 0。见 [channel.md](channel.md) |
| `basagent [server.xml]` | 常驻：连上控制台后周期上报、回保活、执行固定指令（取日志 / 启停实例），断线自动重连；远程 `service:start` / `service:restart` 执行前会先拉取一次配置，`stop` 不拉取 |
| `systemctl start/stop/restart basagent.service` | 管理系统级常驻 agent；运行账号固定为 `bas:beangle`。单元设置 `KillMode=process`：停止、重启或升级 agent 只结束 agent 自己，不会停掉实例（包括控制台 `service:start` 拉起的那些） |
| `basctl doctor [server.xml]` | 检查 `java`（必需）、`jstart`（可选提示），以及启用 setline 时管理口通不通；必需项缺失时退出码非 0，见 [doctor.md](doctor.md) |

## 组件目录初始化

`basctl init [workdir]` 把控制脚本（`env.sh`、`bas.sh`、`start.sh`、`stop.sh`、`restart.sh`）
铺到 `<workdir>/bin` 并建好 `conf/`，用于从零搭建一个
bas 组件目录。RPM/DEB 安装包已经把同一套文件铺到标准目录 `/var/lib/bas`，不需要额外执行
`init`。常驻 agent 由系统级 systemd 管理，不再生成 `agent/agent.pid` 或
`agent/console.out`；标准安装中实例日志位于 `/var/log/bas`，并通过
`/var/lib/bas/logs` 符号链接保持原有路径。若
`conf/basctl.conf` 不存在，还会生成一份带注释、`[remote]` 三项留空的模板，权限为 `0600`。
脚本与模板都内嵌在 basctl 里，随 basctl 版本发布，不再依赖单独的发行包：

```sh
basctl init /opt/bas           # 写入 bin/*.sh 与 basctl.conf 模板（已存在的文件保留）
basctl init --force /opt/bas   # 覆盖为当前 basctl 内置的脚本（仍不覆盖 basctl.conf）
basctl init --dry-run /opt/bas # 只打印将会写入的文件
```

`conf/basctl.conf` 一旦存在就永不覆盖，`--force` 也只作用于脚本；`bin/setenv.sh` 与
`conf/server.xml` 是用户配置，`init` 不生成。使用系统包时，升级会刷新 `bin/*.sh`，并保留已有
的 `basctl.conf`；非系统包目录仍可在升级 basctl 后重跑 `basctl init --force`。不再有单独的
发行包 zip（原 `bas.sh update` 已移除）。

**替换 basagent 不会停实例。** `basctl start` 拉起的实例本来就是独立进程；控制台
`service:start` 拉起的实例会继承 `basagent.service` 的 cgroup，因此单元设置为
`KillMode=process`，停止/重启/升级 agent 只结束 agent 自己。装的是旧单元时，先更新
`/usr/lib/systemd/system/basagent.service` 并 `systemctl daemon-reload`，再替换二进制；
直接用新包升级时 `%post` 会先 `daemon-reload` 再 `try-restart`，实例不受影响。

## 远程配置 `conf/basctl.conf`

控制台连接只从 `conf/basctl.conf` 读取，不再使用 `bas_remote_*` 环境变量，也不靠 `ip:` 请求头
识别机器。文件是简单 INI，只识别 `[remote]` 段；格式见上面的「接入 bashub」示例。

| 字段 | 必填 | 说明 |
|---|---|---|
| `url` | 是 | bashub 根地址（有反向代理前缀就连前缀一起写，不要带 `/api/bashub`），生产必须使用 `https://`；`http://` 只允许 `localhost` / `127.0.0.1` / `[::1]` |
| `profile` | 是 | bashub 里的配置名，必须是 `org.name` |
| `token` | 是 | 该 Profile 的 `key`（bashub 配置详情里可查看/重置） |

运行历史采样由 bashub 控制：agent 不保存采样间隔或时间窗口，只在收到 hub 下发的
`report:health` 时即时返回实例的 `id` / `state`。采样频率与时间窗口配置在 bashub 的
`hub.xml`，修改后无需调整各生产机上的 `basctl.conf`。

在线页的详细 OS、磁盘和 webapps 信息不参与周期采样：agent 首次连接时发一次完整快照，
之后由控制台点击“刷新详情”下发 `report:now` 按需获取。

- `pull` 请求 `<url>/api/bashub/config/<profile>/server`，并发送
  `Authorization: Bearer <profile>:<token>`。token 不对返回 401，Profile 不存在返回 404。
- `basagent report` / 常驻 agent 使用同一组地址与 token：拼出
  `<url>/api/bashub/monitor/agents/<profile>/channel`，再把 `http(s)` 换成 `ws(s)` 建立出站
  WebSocket。只有 `https` 才能换成 `wss`，`http` 只保留给回环调试；TLS 使用系统 CA 校验证书，
  自签或主机名不匹配会直接失败。
- `start.sh` / `restart.sh` **不会**隐式拉取，只读当前 `conf/server.xml`。需要远端更新时显式执行
  `bin/bas.sh pull`；远程 `service:start` / `service:restart` 由 agent 在动作前拉取一次，拉取失败
  则动作失败；`service:stop` 始终按当前运行信息停机，不会被拉取挡住。
- `server.xml` 里仍可写 `${bas_remote_url}` / `${bas_remote_token}`，解析时会用
  `basctl.conf` 的 `remote.url` / `remote.token` 展开，而不是读取环境变量。SNAPSHOT
  下载另有自己的 `token`：bashub 会把 Profile 的 micdn `<auth download-key>` 写入
  `<snapshot-repo token="...">`；没有配置 key 时不写 `token`，按匿名下载处理。
  SNAPSHOT 仓库仍会先被检查并尝试下载最新构建，再与 `BAS_HOME/webapps` 下的同名 war
  比较修改时间；仓库暂时不可用（例如返回 401）时静默使用本地文件，不向启动终端输出
  下载失败。
- 同一个 `<repository>` / `<snapshot-repo>` 有多个 `remote` 时，`token` 可写成与地址
  等长的逗号列表（如 `token="key1,key2"`）；basctl 会合并成
  `--remote=key1@url1,url2` 交给 jstart。空段表示对应仓库匿名，凭证不会跨仓库复用。
- 文件含凭证；`init` 生成的模板已是 `0600`，手工创建时也建议 `chmod 600 conf/basctl.conf`。

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

### 一机器一出口（容器）

容器里 `server.xml` 写 `<setline port="10080"/>`、`<server http="0"/>` 即可：
容器内无论多少实例，对外只有 setline 那一个端口，增删 server 不用改端口映射。构建、运行与
信号处理见 [container.md](container.md)。

### 拉配置与开防火墙

```sh
/opt/bas/bin/bas.sh pull          # 读取 /opt/bas/conf/basctl.conf
basctl firewall /opt/bas          # 交互式地放行 server.xml 里的端口
```

## 环境变量

| 变量 | 用在哪 | 含义 |
|---|---|---|
| `BAS_HOME` | 所有命令 | 组件目录；不给就用当前工作目录。`conf/server.xml`、`servers/` 等都相对它解析 |
| `JAVA_HOME` | `doctor`、creator 写出的启动命令 | `$JAVA_HOME/bin/java` 优先于 `PATH` 上的 `java` |
| `beangle_jstart` | 用 jstart 的命令 | jstart 可执行文件路径，缺省按 `PATH` 找 `jstart` |
| `beangle_basctl` | jstart 回调 creator 时 | basctl 可执行文件路径；缺省用当前 basctl（`/proc/self/exe`），由 basagent 生成 spec 时取同目录的 basctl，debug 构建或改名时可用它指定 |
| `beangle_basagent` | `bas.sh pull` | basagent 可执行文件路径，缺省按 `PATH` 找 `basagent` |
| `M2_REPO` / `M2_REMOTE_REPO` | `run`（`--local` / `--remote` 的缺省值） | 本地 / 远端构件仓库 |

## 排错

| 现象 | 多半是 | 怎么办 |
|---|---|---|
| `Cannot find config file …` | `BAS_HOME` 不对，或 `conf/server.xml` 还没写 | `export BAS_HOME=…`，或直接用参数给配置文件路径 |
| `Route conflict on /x` | 同一个路径被**端口集合不同**的多个 webapp 认领 | 给 webapp 显式声明 `<url path="…"/>`，让每个前缀有唯一归属 |
| `No setline listening on …`（推送 / `start`） | setline 没在跑，或管理口端口不对 | 看 `<setline port>`（那是 setline 的 `adminListen` 端口）；basctl 不会替你拉起 setline |
| `Cannot run jstart …` | `jstart` 不在 `PATH` | 装 jstart，或 `export beangle_jstart=/path/to/jstart`；`basctl doctor` 会提示它是否就位（`jstart` 为可选提示，不影响 doctor 退出码，但实际调用仍会失败） |
| `status` 里某个实例是 `stale` | 进程已不在（崩了或手工 kill） | `basctl stop <name>` 清掉运行信息，再 `start`；对账会把它的路由摘掉 |
| 容器外访问不到 | 出口端口没映射，或 setline 的 `listen` 绑成了 `127.0.0.1` | `-p 8080:8080` 且容器内 `listen` 绑 `*:8080`（入口脚本默认如此），见 [container.md](container.md) |

外部命令是否就位，优先用 `basctl doctor` 自查；它的输出与退出码见 [doctor.md](doctor.md)。
