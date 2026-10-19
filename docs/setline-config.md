# setline 的配置与启用（设计）

`server.xml` 里的 `<setline>` 声明**本这份 `BAS_HOME` 怎么接入本机的 setline**（元素出现即启用、
不出现即禁用）。setline 的**进程**不归 basctl：它由 systemd / 容器入口 / 手工拉起来，basctl 只往
它的写接口推路由。

这样三份东西各自只有一个真源：

| 事实 | 真源 |
|---|---|
| 用不用 setline、路由写进哪一格 | `conf/server.xml` 的 `<setline hostname>` |
| 管理口在哪个端口 | `conf/server.xml` 的 `<setline port>` |
| 进程起停在谁手里 | 拉起它的那个（systemd unit / 容器入口 / 手工） |

管理口端口只有 `<setline port>` 一处来源，解析也只有一处
（`bas.endpoint.resolveSetlinePort`），所以 `doctor` 说通、`setline` 说连不上这类自相矛盾不
会出现。**没有缺省、也没有命令行覆盖**（`--endpoint` 已删：配置里写着端口，再给一个只对本次调用
有效的旋钮，就是第二个真源，还是看不见的那种）。**配了 `<setline>` 就必须写 `port`**（缺了是
配置错误，解析 `server.xml` 时就报）；没配 `<setline>` 就不启用 setline，`start` / `stop` /
`status` 也完全不碰它，不会因为"没有端口"报错；显式跑 `basctl setline` 才报一句"这份配置没启用
setline，没东西可推"。

## `<setline>` 元素

```xml
<bas version="0.14.0">
  <!-- ... repositories / engines / hosts / farms / webapps ... -->
  <setline hostname="alice.localhost" port="10080"/>
</bas>
```

| 属性 | 必填 | 缺省 | 说明 |
|---|---|---|---|
| `hostname` | 否 | `*` | 路由命名空间。setline 按请求 `Host`（去端口、转小写）精确匹配，所以访问地址是 `http://<hostname>:<setline 的 listen 端口>/...`；缺省 `*` 表示匹配任意 Host（用 IP 或任意域名访问都走这一组路由） |
| `port` | **是**（元素出现时） | 无 | 本 `BAS_HOME` 要推路由的 setline 管理口（`adminListen`）**端口**，如 `10080`。只写端口不写 host：管理口的写接口只认回环来的连接（对端与 Host 都是回环），basctl 拨的固定是 `127.0.0.1:<port>`，写别的地址进去必然被拒。缺了是配置错误，解析时就报；`hostname` 才是可以省的那个 |

关于 `port` 这个名字：它和 setline 自己配置里的 `listen` **不是同一个值**——`listen` 是对外接
业务的端口（浏览器与 peer 走它，basctl 不碰），`port` 是管理口的端口。容器里就是两个值：setline
用 `*:8080` 接业务、管理口 `127.0.0.1:10080`，basctl 拨后者的端口。叫 `listen` 会把这两件事混成
一件。

元素也不放健康检查、连接超时、`maxConnections` 这类调参——它们属于代理本身，不是拓扑；setline
自己那份配置也不归 basctl 生成（那是拥有 setline 进程的那个人的事）。

`hostname` 只接受域名允许的字符（小写字母、数字、`-`、`.`）或 `*`，写坏了直接报错：路由写进谁家
的命名空间必须看得见。缺省 `*` 让 IP 和任意域名访问都能命中；多份 `BAS_HOME` 共享一个 setline
时各写自己的域名，显式域名需要 DNS 或 `curl --resolve alice.localhost:<listen 端口>:127.0.0.1`。

**启用判定**：`<setline>` 出现即启用；不出现即禁用，等价于 `setline_enabled=false`。判定在
basctl 内部完成（它本来就解析 `server.xml`），**不引入 shell 变量**——`bas.sh` 里再放一个
`setline_enabled` 会变成第二处真源。

禁用时**什么都不要求**：`start` / `stop` 不推路由也不报缺地址，`status` / `doctor` 连 setline 那
一节都不显示（`doctor` 记为 `skip`）。"没启用"与"配置写坏了"是两件事，前者不该让人看见任何提醒。

## 管理口端口（只写在配置里）

| 情况 | 说明 |
|---|---|
| `<setline port>` | 本 `BAS_HOME` 声明拨哪个管理口（setline 的 `adminListen`）；缺了或写法非法，解析 `server.xml` 时就报错 |
| 没有 `<setline>` | 不启用 setline，也就不需要端口：`start` / `stop` / `status` 一个字都不提；显式 `basctl setline` 报"没启用，没东西可推" |

写法就是一个端口号（`1`..`65535`）。写坏了当场报错，不会悄悄换个端口。

为什么只有端口、没有 host：管理口的写接口只认回环来源（对端与 `Host` 都必须是回环，见下），所以
`127.0.0.1` 是唯一能写通的地址——写别的进去只是把"必然 403"写进配置。为什么没有缺省、没有命令行
开关、也不读环境变量：端口是**这台机器上的一件事实**，一个真源才说得清——就是 `server.xml` 那一
行。多一个"命令行覆盖 + 环境变量 + 内置缺省"的兜底，就多一层看不见的状态：`doctor` / `status` /
`start` 各自解释一遍"到底设了没"，再配上"环境与配置不一致"的告警，比省下的那点打字数麻烦得多。
写进 `server.xml` 反而更好审：改端口时 diff 里看得见，配置进版本库时也带着它。

**多份 `BAS_HOME` 共享一个 setline** 时，`port` 填同一个端口、`hostname` 各写自己那一格——
一个端口抄 N 遍确实不美，但那是"这台机器一个出口"的直接后果，写清楚比藏起来强。

## 启用后的行为

### `start` / `stop`

- `start`：实例存活 → 对账一次（把整组路由推给管理口）；
- `stop`：实例停掉 → 再对账一次（摘除）；
- 对账输入是 `servers/*/server.info`（见 [server-info.md](server-info.md)），不是当场重解析
  `server.xml`——路由跟实例走，配置改了但实例没重启时路由不变，动态端口也只有运行信息里才有；
- `start` 还会在**启动前**用静态拓扑跑一次冲突预检：同一对外路径被端口集合不同的 webapp 认领
  就拒绝启动，把 `Route conflict` 提到"启动前"；动态端口的冲突在对账时判定；
- 对账失败（管理口没人应答、路由冲突）**只警告**（打印原因），不改 `start`/`stop` 的退出码：
  setline 没起不该挡住应用启停，下一次启停（或手工 `basctl setline`）会把路由补齐；
- `--no-setline` 可临时跳过这一次对账（一次性覆盖，不写进 `server.xml`）。

### 推送与探测

推送只有一步：`PUT /_setline/routes/all?host=<hostname>` 整组替换**当前命名空间**。basctl
不保存上次使用的 hostname，也不读取或清理其他分组；用户需要修正旧分组时直接编辑 setline 的
`setline.json`。写接口只认 TCP 对端是本机、不需要凭据，所以写成功就说明管理口上坐的确实是
我们能驱动的 setline。失败分两种说法：

| 探测结果 | 动作 |
|---|---|
| 端口没人监听 | 报错：`No setline listening on 127.0.0.1:<port>`，提示去启动 setline 服务或改 `<setline port>`（**basctl 不就地拉起**） |
| 有人监听、路由写成功 | 复用（systemd、容器入口、手工、别的 `BAS_HOME` 起的都行） |
| 有人监听、写不通 | 报错：端口上有 HTTP 但不是我们那台 setline |

### 停止与归属

- `basctl stop` **不**停 setline：它是机器级入口，可能还在服务别的系统或别的 `BAS_HOME`；
- basctl 也不再提供 `--stop`（旧版会停"就地启动的那一个"，`run/setline.pid` 随之取消）：
  谁拉起的谁负责停——systemd 用 `systemctl stop`，容器入口用 SIGTERM，手工就是自己 Ctrl-C；
- 想让某个 `BAS_HOME` 的路由消失：`basctl stop all`（对账会把该命名空间置空），不需要动进程。

## 多份 `BAS_HOME` 共享一个 setline

一台机器上多人（或多 worktree / 多环境）共用同一个入口时，各自 `server.xml` 写自己的
`hostname`，`port` 填同一个端口：

```xml
<!-- alice：~/bas/alice/conf/server.xml -->
<setline hostname="alice.localhost" port="10080"/>

<!-- bob：~/bas/bob/conf/server.xml -->
<setline hostname="bob.localhost" port="10080"/>
```

```sh
basctl start all     # 各自只写自己那一格
# 访问 http://alice.localhost:<listen 端口>/tools、http://bob.localhost:<listen 端口>/tools
```

两边的前缀撞了也不要紧：冲突检测与路由替换都以命名空间为边界。缺省分组 `*` 适合只有一份
`BAS_HOME` 接入 setline 的机器；多份共享时必须显式写域名，否则都会落进 `*` 而互相整组覆盖。

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
# 写接口只在管理口上且只认本机；listen / adminListen 都在这个配置文件里给，
# adminListen 留缺省（127.0.0.1:10080）就够——basctl 拨的就是它。

[Install]
WantedBy=multi-user.target
```

**不为对账单独立 unit**：路由变化的时机已经有三处（`start`、`stop`、手工 `basctl setline`），
再挂一个常驻轮询进程只会多一份要维护的东西——它想覆盖的"外部把实例弄没了"这种情况，`basctl
status` 的 route 列会直接报出来，跑一次 `basctl setline` 即可。`setline` 服务本身是不是开机
自启、以哪个账号跑，属于运维决策，basctl 不替机器做主（也不安装 unit）。容器形态见
[container.md](container.md)。

## 文件归属（一个文件一个所有者）

| 场景 | `conf/setline.json` 的归属 |
|---|---|
| 外置服务（systemd / 容器） | 归该服务（如 `/etc/setline/setline.json` 或卷里的 `$BAS_HOME/conf/setline.json`）：两个监听由它自己写，basctl 不碰文件——推路由走 HTTP |
| 单机自管（手工跑 setline） | 同上：谁拉起 setline 谁写这份配置（容器里就是入口脚本）。basctl 没有渲染模式了，它只推路由 |

- setline 写回时会**重读文件、只替换 `routes`、再 tmp+rename**，所以它自己的 `listen` /
  `adminListen` / 调参不会被推路由抹掉；
- 运行期路由会持久化到该文件，所以 setline 重启后路由还在；实例已经不在时，下一次推送会修正。

## 与 `basctl setline` 命令的关系

一个动作（详见 [setline.md](setline.md)）：

- `basctl setline`（`--sync` 是同一次动作的显式写法）：把「现状」的路由推一次给已经在跑的
  setline，推完即退出。`start` / `stop` 之后也会各自跑一次，所以日常不必手工敲；
- `status` 的 route 列：读一次路由表（`GET /_setline/routes`）与「现状」对照，报缺 / 端口对不上 /
  多 / 全对上。这是 basctl 唯一读 setline 的地方——只读，走本机来源免凭据的路径，所以不需要任何
  配置。

**setline 的配置文件没有 basctl 的份**：它归拥有 setline 进程的那个（systemd unit / 容器入口 /
你自己），basctl 不生成、不读取、不覆盖，只按 `<setline port>` 拨它的管理口。

## 安全边界

setline 的管理接口分两类，边界不同（详见 setline 的 `doc/runtime-routes-api.md`）：

| 接口 | 来源限制 | 凭据 |
|---|---|---|
| 写：`PUT` / `DELETE` 路由 | 只在**管理口**上，且只接受本机（回环对端 + 回环 Host） | 无凭据 |
| 读：`GET /_setline/routes` | 本机，或来源地址在 `peerReaders` 里 | 无凭据 |
| 状态页 / `status.json` | 只在管理口上；本机，或 `peerReaders` 里的地址 | 无凭据 |

- 写路径就是 basctl 推路由走的路（`basctl setline`，以及 `start` / `stop` 之后的那次对账）：
  只认本机，不需要凭据；`status` 的 route 列读路由表，本机来源一律放行——**读写都不需要 token**，
  所以 `server.xml` 里写的是端口，不是秘密。
- 管理口缺省绑回环（`127.0.0.1:10080`），于是"只有本机能改流量走向"是 TCP 层的事实，不靠凭据；
  这也是配置里只写端口的原因：basctl 拨的就是回环，地址没有可配的余地。`peerReaders` 反过来是给
  别的机器读**这台** setline 用的（例如同网段渲染 haproxy 配置的进程）——那台机器不在名单里就
  回 403，basctl 自己发起的读永远来自回环，不受这条限制。
- setline 不持有任何凭据，`peerReaders` 是**地址名单**（只认字面量地址，不认主机名/CIDR）——跨机
  读的路径因此是"两台机器的地址对齐"，不是"两边同步一个秘密"。路由表要开放给同网段的同步程序
  （例如渲染 haproxy / nginx 配置的进程，见 [features.md](features.md) 的边界与未定项）时，
  把那台机器的地址加进去即可。
