# setline 的配置与启用（设计）

入口地址写在 `conf/server.xml` 里，出现即启用、不出现即禁用。basctl 不再固定 `8080`，也不再需要
`--setline=` 之类的参数：**配置就是开关**。

**状态**：`<setline>` 元素、`--sync`、就地启动、`--stop [--force]` 都已落地；`start` / `stop`
里的自动对账（下一节）还没挂上，暂时由 `basctl setline --sync` 手工触发。

## `<setline>` 元素

```xml
<bas version="0.14.0">
  <!-- ... repositories / engines / hosts / farms / webapps ... -->
  <setline listen="127.0.0.1:8080"/>
</bas>
```

| 属性 | 必填 | 说明 |
|---|---|---|
| `listen` | 是 | 入口地址，与 setline 配置文件里的 `listen` 同义：`8080` / `*:8080` / `127.0.0.1:8080` |

元素只有这一项：没有 `admin-token`，也不放健康检查、连接超时、`maxConnections` 这类调参——它们
是代理本身的调优或 setline 自己的配置（`adminToken` 留在 `conf/setline.json` 里），不是拓扑。

**启用判定**：`<setline>` 出现即启用；不出现即禁用，等价于 `setline_enabled=false`。这个判定在
basctl 内部完成（它本来就解析 `server.xml`），**不引入 shell 变量**——`bas.sh` 里再放一个
`setline_enabled` 会变成第二处真源。

## 启用后的行为

### `start` / `stop`

**尚未实现**：等 `start` / `stop` 接上，这一段才有意义；在那之前用 `basctl setline --sync`
手工同步。

- `start`：实例存活 → 确保入口可用（见下）→ `basctl setline --sync` 推一次路由；
- `stop`：实例停掉 → 再 `--sync` 一次（摘除）；
- `--sync` 失败**只警告**（打印原因），不改 `start`/`stop` 的退出码：setline 挂了不该挡住应用启停；
- `--no-setline` 可临时跳过（一次性覆盖，不写进 `server.xml`）。

### 就地启动 setline

探测走**写**接口而不是读接口：`PUT /__setline/routes/all` 只认本机、不需要 token，能写进去就
说明入口上坐的是我们能驱动的 setline（读接口带 `adminToken`，配了凭据时 `GET` 会回 401，
不能当探测手段）。先看端口是否空闲，不空闲才发这记写请求：

| 探测结果 | 动作 |
|---|---|
| 端口空闲 | 就地启动：`nohup setline -f <conf/setline.json>` 起进程，pid 记 `$BAS_HOME/run/setline.pid`，日志 `logs/setline.out`，随后推路由 |
| 端口在用、路由写成功 | 已有 setline 在跑（systemd、手工或另一个 BAS_HOME 起的）→ **复用**（路由已顺带推好） |
| 端口在用、写不通（连不上或非 setline） | 报错并提示：改 `<setline listen>`，或停掉占用者 |

setline 可执行文件按 `PATH` 上的 `setline` 查找，可用环境变量 `bas_setline` 覆盖（与 `bas_jstart`
同一约定）。

**已实现**：`basctl setline --sync` 先要一份 `conf/setline.json`——只在不存在时写骨架（`listen`
+ 空 `routes`），已有的不动（`adminToken` 等设置归 setline）；再按上表要入口；最后
`PUT /__setline/routes/all?host=*` 整组替换兜底命名空间的路由。路由由 setline 写回文件，重启
不丢；每次调用都是瞬时的，basctl 不常驻。

### 停止与归属

- `basctl stop` **不**停 setline：它是机器级入口，可能还在服务别的系统或别的 `BAS_HOME`；
- 要停就地启动的那个：`basctl setline --stop`（按 `$BAS_HOME/run/setline.pid`，只停自己起的实例），
  进程不退时可加 `--force` 直接 SIGKILL。

pid 放 `run/`（机器级守护进程的目录，按需创建），与按实例分目录的 `servers/<name>/` 分开：
前者属于整个 `BAS_HOME`，后者属于某个 `farm.server`；将来的对账守护进程同样用 `run/`。

**已实现**：先 SIGTERM 并等 10 秒；仍不退时提示 `--force`，不加就报错退出，加了才 SIGKILL。
pid 文件不存在或进程已不在不算错，顺手清掉陈旧的 pid 文件。

### systemd（结论）

- **默认不安装 unit、不 enable**：是否开机自启、以哪个账号跑、读哪份配置，属于运维决策，basctl
  不替机器做主。
- **外置模式被自动复用**（上表「端口在用、路由写成功」一行）：生产上把 setline 交给 systemd 完全
  可行，basctl 不需要知道是谁启动的——只要求同一地址上的写接口可用。
- 可选后续：`basctl init --setline-unit` 生成 unit 模板（指向 `$BAS_HOME/conf/setline.json`），
  仍不自动 enable。

## 文件归属（一个文件一个所有者）

| 场景 | `conf/setline.json` 的归属 |
|---|---|
| 配置了 `<setline>` | 归就地启动的 setline 进程：basctl 只在文件**不存在**时写骨架（`listen` + 空 `routes`），之后只读不写，`routes` 由 setline 自己写回 |
| 没配置（禁用） | 归 `basctl setline` 渲染（现状：纯渲染器，只写 `--output` 指定的文件） |

- setline 写回时会**重读文件、只替换 `routes`、再 tmp+rename**，所以 basctl 写的 `listen` 不会被
  覆盖，`adminToken` 这类设置也不会被 `--sync` 抹掉；反过来，运行中手改 `listen` 只改到文件，
  要重启 setline 才生效（与 `<setline listen>` 不一致时 `--sync` 会提示一句）。
- 运行期路由会持久化到该文件，所以 setline 重启后路由还在；实例已经不在时，下一次 `--sync` 会修正。

## 与 `basctl setline` 命令的关系

- 渲染仍然保留：`basctl setline [server.xml] --output=-` 用来取片段（并入别人的全局代理）。
- **用了 `<setline>` 就别再拿渲染去覆盖 `conf/setline.json`**：那个文件归 setline 进程所有，
  运行期路由由 `--sync` 维护。`--sync` 不会动已有的文件（只在文件不存在时写骨架），但渲染命令
  本身不做拦截——显式调用就是显式意图，覆盖与否由你决定。

## 安全边界

setline 的管理接口分两类，边界不同（详见 setline 的 `doc/runtime-routes-api.md`）：

| 接口 | 来源限制 | 凭据 |
|---|---|---|
| 写：`PUT` / `DELETE` 路由 | **只接受 TCP 对端是 localhost** | 无 token |
| 读：`GET /__setline/routes` | 不限来源 | `X-Setline-Token`（`adminToken`，为空则放行） |
| 状态页 / `status.json` | 不限来源 | Basic Auth，用户名 `setline`，密码 `adminToken` |

- 写路径就是 basctl 走的路（`--sync` 推路由、复用探测）：只认本机，不需要凭据，因此
  `server.xml` 里不放 token。
- 读路径保留 token，是因为路由表将来要开放给同网段的服务进程读取——例如把拓扑渲染成
  haproxy / nginx 配置的同步程序（roadmap 的 R6）。`listen` 绑 `*` 时必须设置 `adminToken`，
  否则路由表对外可读；只绑回环时留空即可，开发默认就是这么用的。
