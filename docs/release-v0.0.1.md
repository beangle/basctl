# Release v0.0.1

发布日期：2026-11-07

首个公开版本。`basctl` 把一份 `conf/server.xml` 转成可运行的 Beangle Bas Server
实例，并把构件解析、下载和进程启动交给同栈的 `jstart`；`basagent` 在同一个版本中提供
配置拉取和出站控制通道。两者都是 D 语言实现的原生可执行文件，随同一发行包发布。

## 版本范围

### 配置与解析

- 根元素为 `<bas>`，元素与属性统一小写连字符；格式由 `resources/bas-1.0.0.xsd` 定义，
  发布副本位于 <http://beangle.github.io/schema/bas-1.0.0.xsd>。
- 解析 farm / server / webapp，webapp 支持 `gav://`、`http(s)://` 和本地路径。
- 支持 release / snapshot 仓库及仓库 token；未配置的仓库参数交给 jstart 的默认策略。
- 引擎类型为 `tomcat-server`、`tomcat`、`undertow`、`jetty` 和 `native`；容器默认依赖集
  内嵌在 `resources/engines.ini`，`<engine><jar>` 按 GA 合并覆盖。

### 命令行

| 命令 | 能力 |
|---|---|
| `basctl version` / `banner` | 输出纯文本版本或带 logo、bas 引擎版本和本机地址的横幅 |
| `basctl init` | 把控制脚本铺到 `<workdir>/bin`，缺少 `conf/basctl.conf` 时生成 `0600` 模板 |
| `basctl make` | 批量生成实例目录和 jstart spec 并预取依赖；或作为 jstart `[engine] init` creator |
| `basctl resolve` | 只解析 webapp，不生成实例、不启动进程 |
| `basctl start` / `stop` | 定端口、写 `server.info`、生成 spec 并后台启动；按 pid 优雅停止 |
| `basctl status` / `logs` | 从运行信息列出实例；查看或持续跟随实例日志 |
| `basctl run` | 用 `--engine=<type>-<version>` 前台运行单个 webapp |
| `basctl doctor` | 检查必需的 `java` 和可选的 `jstart` |
| `basctl firewall` | 按配置中的端口生成或应用 firewalld 规则 |

### 运行态

- 每个实例在 `servers/<farm.server>/` 下拥有独立目录、launch spec、日志链接和
  `server.info`。
- `<server http="0">` 时在 `20000-29999` 区间内顺序寻找空闲端口，并在
  `servers/.ports.lock` 的 `flock` 内完成探测与预留；缺省端口可被
  `--port-range` 覆盖。
- `stop` 先发 SIGTERM，`--timeout` 后仍存活则报错，`--force` 直接 SIGKILL；运行信息
  丢失时可按 `-Dbas.server` 与 `-Dbas.home` 找回残留实例。
- 日志读取支持 `-n`（缺省 50，上限 2000）与 `-f`，日志滚动后自动切换到新文件。

### jstart 与容器

- `start` / `make` / `resolve` / `run` 调用宿主 `jstart`；`jstart` 负责构件解析、下载、
  校验和最终 exec。
- 多应用实例生成 `launch.jstart`；creator 模式由 `basctl make <type>` 准备 webapp、
  解压 war、推导 docBase，并按 `[engine] init` 协议写回最终 argv。
- native 引擎把 `tar.gz` 解到实例目录，按权限位定位可执行文件后交给 jstart exec。
- 命令行超过平台限制时使用 `jstart.argv` / `jstart.args` 参数文件交接。

### basagent

- `basagent pull` 显式拉取远端 `server.xml`，旧配置保留为 `server_old.xml`。
- `basagent report` 连接一次控制台，发送 `hello`、主机与 bas 现状后退出。
- 不带子命令时常驻：连接出站 WebSocket，按固定原语处理日志读取、立即上报和实例启停；
  断线后自动重连，并提供同组 agent 的 master 选举与迁移。
- 地址、Project 和 token 统一来自 `basctl.conf` 的 `[remote]`，三项齐全才启用；
  `basagent.service` 以 `bas:beangle` 运行，控制实例启停时使用 `KillMode=process`。

### 打包与测试

- `scripts/build_deb.sh` 与 `scripts/build_rpm.sh` 生成同一包的 deb / rpm，内含
  `/usr/bin/basctl`、`/usr/bin/basagent`、systemd unit、logrotate 配置和标准
  `/var/lib/bas` 控制树。
- `scripts/build_image.sh` 构建包含 `basctl`、`basagent`、`jstart` 和 `setline` 的容器镜像。
- AUR 包定义在上游之外维护；Arch 构建使用 `ldc`、`dub`，包版本与
  `src/bas/versioninfo.d` 的 `basctlVersion` 一致。
- `dub test --compiler=ldc2`：157 个用例通过；release 构建产物为
  `target/basctl` 与 `target/basagent`。

## 环境要求

- Linux x86_64，`ldc2 >= 1.32`、`dub >= 1.34`（源码构建）。
- `make` / `resolve` / `start` / `run` 需要 `jstart` 在 `PATH` 上，或用
  `beangle_jstart` 指定路径；`doctor` 把它作为可选提示。
- `java` 为 `doctor` 的必需项；实际运行 Java 容器时还需要对应版本的 JRE。
- `basagent` 的动态构建依赖 OpenSSL 3.x；`basctl` 不链接 OpenSSL 或 vibe。

## 已知限制

- 不作为应用进程的 supervisor：实例退出后不会自动拉起，需要编排层或 systemd 负责。
- 不做传递依赖解析：运行期依赖由 jstart launch spec 与构件内的依赖描述完整给出。
- native 引擎只接受 `tar.gz` / `tgz` 发行包；其他打包类型不实现。
- 首个版本以 Linux x86_64 为发行目标，Windows 代码路径不提供官方二进制。

## 安装

```sh
# 源码构建
dub build -c basctl --build=release-nobounds --compiler=ldc2
dub build -c basagent --build=release-nobounds --compiler=ldc2

# Arch Linux AUR
yay -S basctl

# Debian / Fedora 包
scripts/build_deb.sh
scripts/build_rpm.sh
```

完整功能说明见 [features.md](features.md)、[usage.md](usage.md) 与
[scripts/README.md](../scripts/README.md)。
