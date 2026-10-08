# setline 的配置与启用（设计）

`server.xml` 里的 `<setline>` 声明**本这份 `BAS_HOME` 怎么接入本机的 setline**（元素出现即启用、
不出现即禁用）。setline 的**进程**不归 basctl：它由 systemd / 容器入口 / 手工拉起来，basctl 只往
它的写接口推路由。

这样三份东西各自只有一个真源：

| 事实 | 真源 |
|---|---|
| 用不用 setline、路由写进哪一格 | `conf/server.xml` 的 `<setline hostname>` |
| 入口在哪（地址与端口） | `conf/server.xml` 的 `<setline endpoint>`（命令行 `--endpoint` 可覆盖单次调用） |
| 进程起停在谁手里 | 拉起它的那个（systemd unit / 容器入口 / 手工） |

入口地址的取用顺序固定为 `--endpoint` > `<setline endpoint>`，只有一处在解析它
（`bas.endpoint.resolveSetlineEndpoint`），所以 `doctor` 说通、`--sync` 说连不上这类自相矛盾不
会出现。**没有缺省**：**配了 `<setline>` 就必须写 `endpoint`**（缺了是配置错误，解析 `server.xml`
时就报）；没配 `<setline>` 就不启用 setline，`start` / `stop` / `status` 也完全不碰它，不会因为
"没有地址"报错。`--endpoint` 留给两种场合：这份配置不启用 setline、只想渲染或对账一次，以及临时
覆盖配置里的地址。

## `<setline>` 元素

```xml
<bas version="0.14.0">
  <!-- ... repositories / engines / hosts / farms / webapps ... -->
  <setline hostname="alice.localhost" endpoint="127.0.0.1:8080"/>
</bas>
```

| 属性 | 必填 | 缺省 | 说明 |
|---|---|---|---|
| `hostname` | 否 | `localhost` | 路由命名空间。setline 按请求 `Host`（去端口、转小写）精确匹配，所以访问地址是 `http://<hostname>:<入口端口>/...`；显式写 `*` 表示匹配任意 Host（用 IP 或任意域名访问都走这一组路由） |
| `endpoint` | **是**（元素出现时） | 无 | 本 `BAS_HOME` **往外拨**的入口地址，写法与 setline 的 `listen` 同构：`8080` / `127.0.0.1:8080` / `*:8080`（`*` 只表示"监听所有地址"，拨的时候落到回环）。缺了是配置错误，解析时就报；`hostname` 才是可以省的那个 |

关于 `endpoint` 这个名字：它和 setline 自己配置里的 `listen` **不是同一个值**——`listen` 是绑哪个
socket（`*:8080` 合法），`endpoint` 是往哪拨（`*` 拨不通，只能是具体地址）。容器里就是两个值：
setline 绑 `*:8080`，basctl 拨 `127.0.0.1:8080`。叫 `listen` 会把这两件事混成一件。

元素也不放 `admin-token`（那是 setline 自己的配置）、不放健康检查、连接超时、`maxConnections`
这类调参——它们属于代理本身，不是拓扑。

`hostname` 只接受域名允许的字符（小写字母、数字、`-`、`.`）或 `*`，写坏了直接报错：路由写进谁家
的命名空间必须看得见。缺省 `localhost` 是因为浏览器把 `*.localhost` 都解析到回环；命令行访问
需要 `curl --resolve alice.localhost:8080:127.0.0.1` 或写 hosts，或用 `hostname="*"`。

**启用判定**：`<setline>` 出现即启用；不出现即禁用，等价于 `setline_enabled=false`。判定在
basctl 内部完成（它本来就解析 `server.xml`），**不引入 shell 变量**——`bas.sh` 里再放一个
`setline_enabled` 会变成第二处真源。

禁用时**什么都不要求**：`start` / `stop` 不推路由也不报缺地址，`status` / `doctor` 连 setline 那
一节都不显示（`doctor` 记为 `skip`）。"没启用"与"配置写坏了"是两件事，前者不该让人看见任何提醒。

## 入口地址（配置 / 命令行）

| 来源 | 优先级 | 说明 |
|---|---|---|
| `--endpoint=<addr>` | 最高 | 只对本次调用有效：渲染写进 setline 的 `listen`，对账 / 状态用它拨号 |
| `<setline endpoint>` | 高（元素出现时必填） | 本 `BAS_HOME` 声明拨哪扇门；缺了或写法非法，解析 `server.xml` 时就报错 |
| （都没有） | —— | 只有在"配置里没有 `<setline>`"时才会走到：不启用 setline，也就不需要地址；渲染或对账得用 `--endpoint` 指一次，否则报 `No setline entry address` |

写法两处一致（与 setline 配置里的 `listen` 同构）：`8080` / `*:8080` / `127.0.0.1:8080`；探测与
推送时 `*` / `0.0.0.0` 走回环。写坏了当场报错，不会悄悄换个地址。

为什么没有缺省、也不再读环境变量：地址是**这台机器上的一件事实**，只有两个真源才说得清——配置
（长期声明）与命令行（本次覆盖）。多一个"环境变量 + 内置缺省"的兜底，就多一层看不见的状态：
`doctor` / `status` / `--sync` / `start` 各自解释一遍"到底设了没"，再配上"环境与配置不一致"的
告警，比省下的那点打字数麻烦得多。写进 `server.xml` 反而更好审：改端口时 diff 里看得见，配置
进版本库时也带着它。

**多份 `BAS_HOME` 共享一个 setline** 时，`endpoint` 填同一个地址、`hostname` 各写自己那一格——
一份端口抄 N 遍确实不美，但那是"这台机器一个出口"的直接后果，写清楚比藏起来强。

## 启用后的行为

### `start` / `stop`

- `start`：实例存活 → 对账一次（把整组路由推给入口）；
- `stop`：实例停掉 → 再对账一次（摘除）；
- 对账输入是 `servers/*/server.info`（见 [server-info.md](server-info.md)），不是当场重解析
  `server.xml`——路由跟实例走，配置改了但实例没重启时路由不变，动态端口也只有运行信息里才有；
- `start` 还会在**启动前**用静态拓扑跑一次冲突预检：同一对外路径被端口集合不同的 webapp 认领
  就拒绝启动，把 `Route conflict` 从"生成配置时"提前到"启动前"；动态端口的冲突在对账时判定；
- 对账失败（入口没人应答、路由冲突）**只警告**（打印原因），不改 `start`/`stop` 的退出码：
  setline 没起不该挡住应用启停，下一个 `--sync` / `--watch` 会补上；
- `--no-setline` 可临时跳过这一次对账（一次性覆盖，不写进 `server.xml`）。

### 推送与探测

推送只有一个请求：`PUT /__setline/routes/all?host=<hostname>`——幂等，只替换**这个命名空间**，
别的分组不受影响（setline 侧是 `replaceRoutes`）。它是**写**接口，只认 TCP 对端是本机、不需要
token，所以写成功就说明入口上坐的确实是我们能驱动的 setline。失败分两种说法：

| 探测结果 | 动作 |
|---|---|
| 端口没人监听 | 报错：`No setline listening on <addr>`，提示去启动 setline 服务或改 `<setline endpoint>`（**basctl 不就地拉起**） |
| 有人监听、路由写成功 | 复用（systemd、容器入口、手工、别的 `BAS_HOME` 起的都行） |
| 有人监听、写不通 | 报错：端口上有 HTTP 但不是我们那台 setline |

### 停止与归属

- `basctl stop` **不**停 setline：它是机器级入口，可能还在服务别的系统或别的 `BAS_HOME`；
- basctl 也不再提供 `--stop`（旧版会停"就地启动的那一个"，`run/setline.pid` 随之取消）：
  谁拉起的谁负责停——systemd 用 `systemctl stop`，容器入口用 SIGTERM，手工就是自己 Ctrl-C；
- 想让某个 `BAS_HOME` 的路由消失：`basctl stop all`（对账会把该命名空间置空），不需要动进程。

## 多份 `BAS_HOME` 共享一个 setline

一台机器上多人（或多 worktree / 多环境）共用同一个入口时，各自 `server.xml` 写自己的
`hostname`，`endpoint` 填同一个地址：

```xml
<!-- alice：~/bas/alice/conf/server.xml -->
<setline hostname="alice.localhost" endpoint="127.0.0.1:8080"/>

<!-- bob：~/bas/bob/conf/server.xml -->
<setline hostname="bob.localhost" endpoint="127.0.0.1:8080"/>
```

```sh
basctl start all     # 各自只写自己那一格
# 访问 http://alice.localhost:8080/tools、http://bob.localhost:8080/tools
```

两边的前缀撞了也不要紧：冲突检测与路由替换都以命名空间为边界。**别用 `*` 做分组**——`*` 是
"任意 Host"的兜底命名空间，两个 `BAS_HOME` 都用它就会互相整组覆盖。

刻意不做的事：分组键只来自 `server.xml`，不提供 `--group` 这类命令行/环境开关（同 R5 的结论——
它会变成一个没有配置来源的旋钮）。

### systemd（外置服务）

```ini
# /etc/systemd/system/setline.service
[Unit]
Description=setline HTTP path router
After=network-online.target

[Service]
ExecStart=/usr/local/bin/setline -f /etc/setline/setline.json
Restart=always
User=setline
# 写接口只认本机，接口不需要对外暴露；listen 在配置文件里给（生产上绑 * 时记得配 adminToken）

[Install]
WantedBy=multi-user.target
```

对账进程（每个 `BAS_HOME` 一个）也可以交给 systemd：

```ini
# /etc/systemd/system/basctl-setline-watch@.service
[Service]
ExecStart=/usr/local/bin/basctl setline --watch --interval=5
Environment=BAS_HOME=/opt/bas/%i
Restart=always
```

它不是应用 supervisor，只把 `server.info` 的现状同步成路由；`setline` 服务本身是不是开机自启、
以哪个账号跑，属于运维决策，basctl 不替机器做主（也不安装 unit）。容器形态见
[container.md](container.md)。

## 文件归属（一个文件一个所有者）

| 场景 | `conf/setline.json` 的归属 |
|---|---|
| 外置服务（systemd / 容器） | 归该服务（如 `/etc/setline/setline.json` 或卷里的 `$BAS_HOME/conf/setline.json`）：basctl 只**读**——推路由走 HTTP，不碰文件；容器入口在文件不存在时渲染一份骨架 |
| 单机自管（手工跑 setline） | 归 `basctl setline` 渲染（`--output` 指定，缺省 `$BAS_HOME/conf/setline.json`），运行时 `routes` 由 setline 自己写回 |

- setline 写回时会**重读文件、只替换 `routes`、再 tmp+rename**，所以渲染写的 `listen` 不会被
  覆盖，`adminToken` 这类设置也不会被推路由抹掉；
- 运行期路由会持久化到该文件，所以 setline 重启后路由还在；实例已经不在时，下一次 `--sync` 会修正。

## 与 `basctl setline` 命令的关系

三个子模式（详见 [setline.md](setline.md)）：

- 渲染：`basctl setline [server.xml]`（`--output=-` 取片段；`--endpoint` 覆盖入口地址，渲染进
  文件的 `listen` 用它）；
- `--sync`：把「现状」的路由推一次给已经在跑的 setline；
- `--watch`：常驻做同一件事；
- `status` 的 route 列：读一次路由表（`GET /__setline/routes`）与「现状」对照，报缺 / 端口对不上 /
  多 / 全对上。这是 basctl 唯一读 setline 的地方——只读，走的是 setline 对本机免凭据的那个入口，
  所以不需要任何配置。

**用了外置 setline 就别再拿渲染去覆盖它的配置文件**：那个文件归服务所有，运行期路由由
`--sync` 维护。渲染命令本身不做拦截——显式调用就是显式意图。

## 安全边界

setline 的管理接口分两类，边界不同（详见 setline 的 `doc/runtime-routes-api.md`）：

| 接口 | 来源限制 | 凭据 |
|---|---|---|
| 写：`PUT` / `DELETE` 路由 | **只接受 TCP 对端是 localhost** | 无 token |
| 读：`GET /__setline/routes` | **本机免凭据**；其它来源不限 | 非本机：`X-Setline-Token`（`adminToken`，为空则放行） |
| 状态页 / `status.json` | **本机免凭据**；其它来源不限 | 非本机：Basic Auth，用户名 `setline`，密码 `adminToken` |

- 写路径就是 basctl 推路由走的路（`--sync` / `--watch`）：只认本机，不需要凭据；`status` 的 route
  列读路由表，读同样**对本机免凭据**——读写同一条门，所以 `server.xml` 里没有、也不需要 token。
  只有非本机来源的读才看 `adminToken`（那是留给同网段服务进程的路径，见 R6）。
- 读路径保留 token，是因为路由表将来要开放给同网段的服务进程读取——例如把拓扑渲染成
  haproxy / nginx 配置的同步程序（见 [features.md](features.md) 的边界与未定项）；本机来源不在这条
  规则里，读写一样免凭据。
  setline 的 `listen` 绑 `*` 时必须设置 `adminToken`，否则非本机的读也放行；只绑回环时留空即可。
