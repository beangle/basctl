# 实例运行信息 `server.info`

每个实例在 `servers/<farm.server>/server.info` 记一份运行信息：**它是谁、进程号多少、实际监听
哪个端口、跑了哪些 webapp、对外暴露哪些 url**。`basctl status` 与 setline 的路由对账都读它，不再
各自去猜（`ss`/`netstat` 反查端口）或重新解析 `server.xml`。

**状态：已落地**（basctl 的 `start` / `stop` / `status`，见文末「实现说明」）。

## 为什么要有这个文件

- **对账只需要"现状"**：路由对账要的是"此刻谁活着、在哪个端口、占哪些 url"。重新解析
  `server.xml` 会引入歧义——配置可能已经被改了，而跑着的实例还是启动时那一份。运行信息记录的是
  **实例启动时的样子**，这正是对账要的语义。
- **端口不再是猜出来的**：由 basctl 分配（见下）并记录，`status` 不必依赖 `ss`/`netstat`
  （Windows 开发环境同样可用）。
- **单一现状来源**：pid 只是其中一行；`status` / `stop` 要的端口、webapp、对外 url 都在这里，
  读者不必再去 `ss` / `netstat` 反查端口，也不必重新解析 `server.xml`。

## 位置与生命周期

路径：`$BAS_HOME/servers/<farm.server>/server.info`（与 `error`、`logs` 同目录）。

实例目录由 basctl **以 0700 创建**（父目录 `servers/` 仍是普通 umask 语义）：运行信息里有 pid 与
端口，不宜让同组用户写。jstart 随后接管同一个目录，权限已经收好，不会再报"group/world accessible"。

| 时机 | 动作 |
|---|---|
| `basctl start` 分配端口后 | 写入第一段：`[server]` 的 `id` / `engine` / `http.port` / `started` + 各 `[webapp]`（此时**没有 `pid`**，同时兼作端口预留） |
| `basctl start` 确认实例存活后 | 补写 `pid` |
| 启动失败 | 删除该文件（不留半个实例） |
| `basctl stop` 正常停止后 | 删除该文件 |
| 崩溃 / `kill -9` | 文件残留；pid 不存活即为 stale，由读者判定，不在文件里记状态 |

文件本身**不记录状态**（starting / running / stale）：状态一律由 pid 是否存在、是否存活推导，
少一个需要同步的字段。

## 格式

- UTF-8、LF 换行；`[section]` 分节，`key = value` 键值；`;` 或 `#` 开头的行与空行忽略。
- 键一律小写，`=` 两侧空格可有可无；值不做转义，**不允许换行**。
- 同一分节内**同名键重复出现即列表**（目前只有 `url`），顺序即声明顺序，重复值去重。
- 不认识的键与分节**保留但不解释**（读方忽略），便于以后加字段而不破坏旧版 basctl。

### 键

`[server]`

| 键 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 实例标识，等于目录名 `<farm.server>`（即 `server.qualifiedName`） |
| `pid` | 否 | 实例进程 pid；**启动完成前不写**。jstart `exec` 后 pid 不变，因此它就是应用进程的 pid |
| `engine` | 是 | 容器类型与版本，`<type>-<version>`（见下） |
| `http.port` | 是 | 实际监听端口；由 basctl 分配或取自 `<server http>`，启动前即已知 |
| `started` | 是 | 启动时间，`yyyy-MM-ddTHH:mm:ss±HH:MM`（**本机时区**） |

`[webapp <id>]`（一个 webapp 一节，`<id>` 与 spec 里 `[subapp <id>]` 的 id 同源，由 context path 推导）

| 键 | 必填 | 说明 |
|---|---|---|
| `uri` | 是 | 应用坐标（`gav://`、`http(s)://` 或本地路径，与 `<webapp uri>` 一致） |
| `context` | 是 | 容器内的上下文路径；ROOT 记作 `/`（`<webapp path>` 未声明或为 `/`） |
| `url` | 否 | 对外暴露的 URL 前缀，可重复；对应 `<webapp><url path="..."/></webapp>`，缺省回退 `context` |

`engine` 由 `<engine type>` 与 `<engine version>` 拼成，形如 `tomcat-server-11.0.26`、
`tomcat-11.0.25`、`undertow-2.0.3.Final`、`jetty-12.1.14`——与 `basctl run --engine=<type>-<version>`
同形（`EngineRef` 的解析规则）。

### 示例

```ini
; servers/platform.server1/server.info —— basctl 写入，请勿手工修改
[server]
id = platform.server1
engine = tomcat-server-11.0.26
http.port = 20001
started = 2026-10-07T10:12:33+08:00
pid = 23145

[webapp portal]
uri = gav://org.beangle.ems:beangle-ems-portal:4.20.13
context = /portal
url = /portal

[webapp otk]
uri = gav://org.beangle.otk:beangle-otk-ws:war:0.0.30
context = /
url = /context1
url = /context2
```

## 端口分配（`<server http="0">` 时）

`<server http>` 有值时按该端口启动；为 `0`（或缺省）时由 basctl 在**端口区间**内挑一个空闲端口，
用 `--port=<n>` 传给应用（与静态端口同一个参数，引擎不需要区分），并写进 `server.info` 的
`http.port`。应用不自己选端口，`status` 与对账也不需要反查。

**缺省区间 `20000-29999`**，理由：

- 高于特权端口（1024 以上），不需要 root；
- 低于 Linux 缺省的临时端口范围 `32768-60999`（`net.ipv4.ip_local_port_range`），避免本机出站
  连接占用我们分配出去的端口；
- 避开 k8s NodePort（30000-32767），容器里跑也不冲突；
- 避开常见开发端口（8000/8080/9000 等）。

区间属于**机器相关的环境**，不是拓扑的一部分，因此用 `--port-range=<from>-<to>` 指定（缺省
`20000-29999`），不写进 `server.xml`，也不设环境变量——一个旋钮就够。

**算法**（探测与落盘都在 `$BAS_HOME/servers/.ports.lock` 的 `flock` 内完成）：

1. 本实例上次 `server.info` 记录的端口仍在区间内且空闲时**优先复用**——重启后端口稳定，书签和
   `setline` 路由都不用重新记；
2. 否则在区间内**顺序找第一个空闲端口**（可预测，便于人工排查）；
3. "空闲" = 没有任何存活实例的 `server.info` 记着它，且能独占 `bind` 一次（随即释放）。

锁只覆盖"探测 + 写第一段"，不覆盖 JVM 启动过程：并发 `basctl start` 不会重号，也不会长时间占锁。
`bind` 探测与真正的 bind 之间仍有理论上的竞争窗口，属可接受（dev/单机场景），且失败会在启动日志里
直接体现。启动失败必须删除文件，否则这个端口会被永久算作占用。

判定"某个端口已经被别的实例占着"时看两点：别的实例的 `server.info` 记着它（进程活着，或文件
还没有 `pid`——那是一次正在进行中的启动预留），或本机已经有人在监听（`bind` 探测）。自己上次的
端口不参与判定，它正是第 1 步要复用的候选。

没有 `pid` 的预留文件久留不下，说明 basctl 自己在启动过程中被杀了（正常路径都会撤销）；那个端口
重跑该实例的 `basctl start` 就会收回来——它只影响同一份 `BAS_HOME` 的区间分配，不占系统意义上的
端口（预留期间没人监听）。

`--port-range` 只出现在 `basctl start` 上，`stop` / `status` / `setline` 都不需要它——端口已经记在
运行信息里了。

## 与 jstart 的分工（jstart 只负责 `run`）

jstart 只负责"解析 + 准备 + exec"，实例身份与停止交给 basctl（R8，已落地）：

- **jstart 不写 pid 文件**：pid 的记录归 basctl（写进本文件）。
- **jstart 不提供 `stop`**：`--timeout` / `--force` 一并去掉；`run` 原有的"同一实例在运行就
  拒绝启动"也随之消失——幂等由 basctl 读 `server.info` 判断。
- `run` 保持 exec 语义：exec 之后进程就是应用本身，pid 不变，所以 basctl 拿到的 pid 就是应用 pid。

| 位置 | 变化 |
|---|---|
| `basctl stop` | 不调 `jstart stop`；按 `server.info` 的 pid 发 SIGTERM，`--timeout` 超时后报错，`--force` 直接 SIGKILL |
| `basctl start` | 幂等判断读 `server.info`（pid 存活即视为已运行） |
| jstart 自身 | 已去掉 `app.pid` 与 `stop` 子命令；这是破坏性变更，记在 jstart 的 CHANGELOG |

### 写入要求

- **原子替换**：先写同目录临时文件再 `rename`，避免读者看到写了一半的文件；补写 `pid` 时同样整
  文件重写，不做就地修改。
- **唯一写者**：同一实例的运行信息只由 basctl 写；jstart 与引擎的产物（`engine-*.classpath`、
  `engine-entry.argv`、`webapps/`）各自独立，互不覆盖。

## 与旧 pid 文件的关系

更早的 basctl 在 `servers/<name>/SERVER_PID` 里只记一行 pid。本文件把它整体取代，**不保留兼容
读取**：多一条只在少数机器上才走的路径，还要处理"两处 pid 不一致"，得不偿失。由旧版 basctl
启动、升级时仍在运行的实例，升级后 `status` 不再列出；重新 `start` / `stop` 即可回到本文件。

## 实现说明

| 位置 | 职责 |
|---|---|
| `src/bas/serverinfo.d` | 模型、INI 读写、原子替换 |
| `src/bas/portalloc.d` | 端口区间、`flock` 内的"探测 + 预留"、顺序挑选与复用 |
| `src/bas/starter.d` | `start` 写运行信息（含补 pid）、`stop` 按 pid 停止、`describeInstance` 从配置推导内容 |
| `src/bas/main.d` | `status` 按运行信息展示（`port` / `engine` / `started` / 各 webapp 的 `url`）；配了 `<setline>` 时另起一节报入口状态 |
| `src/bas/setline.d` | `runningPlan`：由运行信息（而非 `server.xml`）算路由与冲突 |
| `src/bas/setlineproc.d` | 把现状推给 setline：`--sync` / `--watch`、`start` / `stop` 之后的对账 |

启动时先写第一段（无 `pid`，兼作端口预留）发生在解析 webapp **之前**：动态端口必须先定下来，
随后生成的 spec 才能带上 `--port=`。准备失败（webapp 解析不出来、引擎依赖缺件）时撤销预留，避免
这个端口被永久占着。

`stop` 的动作顺序：读 pid → 进程不在就直接清掉陈旧信息（重复 `stop` 不会越做越乱）→ 核对身份 →
SIGTERM 并等 `--timeout`（缺省 15 秒）→ 仍在则报错退出（`--force` 才 SIGKILL）。**身份核对**
（`pidLooksLikeInstance`）看 Linux 的 `/proc/<pid>/cmdline` 里有没有 `-Dbas.server=<name>`
（jstart 把长参数写进 `@argfile` 时，跟着这个文件再看一层，见 `src/bas/serverstatus.d`）：
pid 会被系统回收，照着一个陈旧 pid 发信号可能伤及无辜；判定不了时（非 Linux、读不到 cmdline）
不拦。`--force` 跳过核对，直接 SIGKILL，留作逃生门。

`status` 对 pid 已不在的实例打印 `name(stale pid=... port=...)`：信息还在说明它崩溃或被
`kill -9` 了；`status` 只读，不清理（清理交给 `stop`，或者用 `--force` 直接杀）。

`stop` 按 `server.xml` 选实例，所以**已经从配置里删掉**的实例它选不到：那种情况下直接删掉
`servers/<name>/`（连同 `server.info`）即可。
