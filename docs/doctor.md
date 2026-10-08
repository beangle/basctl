# 环境自检（`basctl doctor`）

`basctl` 自己不起进程池，也不直接 exec java，而是把命令交给别的程序；`doctor` 就是一条
「这些东西在这台机器上都有吗」的检查命令。

```sh
basctl doctor                       # 检查 $BAS_HOME/conf/server.xml 语境下的依赖
basctl doctor /opt/bas/conf/server.xml
```

## 检查哪些命令

| 命令 | 什么时候需要 | 从哪找 |
|------|--------------|--------|
| `java` | `make` / `start` / `run` 都要（creator 写出的启动命令与 jstart 最终 exec 的都是 java） | `$JAVA_HOME/bin/java` 优先，其次 `PATH` |
| `jstart` | `start` / `make` / `resolve` 用它解析下载构件 | `beangle_jstart` 指向的命令优先，其次 `PATH` 上的 `jstart` |
| `setline` | **只有** `server.xml` 里声明了 `<setline>` 才检查；检的是**入口可达**，不是命令存在 | 入口地址取自 `<setline endpoint>`（元素必填，`doctor` 没有命令行覆盖），有人监听即 `ok` |

`<setline>` 的判定与 [setline-config.md](setline-config.md) 一致：出现即启用，没有独立的开关。
没启用时这一行是 `skip`，`start` / `stop` / `status` 也完全不碰 setline。配置文件不存在或解析
失败时按「未启用 setline」处理（不因此报错），说明会打在 `config` 行上。

`setline` 这一行检的是**服务**而不是可执行文件：setline 是机器级服务（systemd / 容器入口 /
手工拉起），basctl 只往它的写接口推路由，从不调用它的可执行文件。

## 输出与退出码

```
config  /opt/bas/conf/server.xml (<setline hostname="alice.localhost">)
java     ok      /usr/lib/jvm/java-17-openjdk/bin/java (JAVA_HOME)
jstart   ok      /usr/local/bin/jstart (PATH)
setline  ok      127.0.0.1:8080 (server.xml)
doctor: all required commands are available.
```

- 每行给出命令名、状态（`ok` / `MISSING` / `skip`）与解析出的绝对路径（setline 一行是入口地址）及来源
  （setline 的来源是 `server.xml`，一眼看出地址是从哪来的）；
- 没启用 setline 时它是 `skip`，不算缺失；
- 启用 setline 但入口没人应答时，`setline` 报 `MISSING` 并提示去起服务或改地址；
- **缺少必需项时退出码为 1**，脚本可以据此在启动前拦一道。

`doctor` 只检查「就位没就位」，**不校验版本**：java / jstart / 容器的版本策略分别
属于各自的发布节奏，basctl 掺和只会制造漂移（版本语义见 [../README.md](../README.md) 的
「版本语义」）。

它也不写任何文件、不改配置，可以在任何目录反复跑。

## 为什么不接进 `start`

`start` 已经在缺件时给出明确报错（`basctl` 调 jstart 失败、jstart 找不到 java），再加一道
「先跑 doctor、缺件就拒绝启动」的开关只增加一个旋钮而没有新信息。`doctor` 保持成独立命令，
由人在初始化或排障时跑（见 [usage.md](usage.md) 的「组件目录初始化」）。

## 打包

`.deb` / `.rpm` **不声明**对 `java` / `jstart` 的硬依赖，也不声明对 setline 服务的依赖：安装方式太多
（系统包、`sdkman`、手工放置），硬依赖会挡住「先装 basctl、再按需补命令」的用法。包只保证
`/usr/bin/basctl` 就位，缺件由 `doctor` 在运行时提示。详见 [../scripts/README.md](../scripts/README.md)。
