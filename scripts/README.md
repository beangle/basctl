# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_common.sh` | 打包共用：版本号取自源码常量、`dub clean`、清空 `target/`，分别构建 `basctl` 与 `basagent` |
| `build_image.sh` | 构建容器镜像 `basctl:<版本>`（podman；三仓库源码在 Alpine 里现编译，见 [../docs/container.md](../docs/container.md)） |
| `build_deb.sh` | 构建 `.deb`（需 Debian 系或 `dpkg-deb`、`fakeroot`） |
| `build_rpm.sh` | 构建二进制 `.rpm`（需 `rpmbuild >= 4.14`、`fakeroot`） |
| `container/` | 镜像里的入口脚本与样例 `server.xml`（由 `build_image.sh` 收进构建上下文） |

产物统一输出到 `target/`：

- `target/basctl`：本地控制面 release 二进制（不链接 OpenSSL / vibe）
- `target/basagent`：远端通道与拉取 release 二进制（OpenSSL 3.0）
- `target/basctl_<v>-<r>_amd64.deb`：Debian/Ubuntu 安装包
- `target/basctl-<v>-<r>.<arch>.rpm`：Fedora/RHEL 安装包

`<v>` 取自 `src/bas/versioninfo.d` 的 `enum basctlVersion`——也就是 `basctl version` 输出的那个值，
包里只有这一处版本声明，包版本与运行时自报版本不会漂移。

`.deb`/`.rpm` 同时安装 `/usr/bin/basctl`、`/usr/bin/basagent`、`basagent.service`、
`/etc/logrotate.d/bas`，并在 `/var/lib/bas` 预置 `bin/*.sh` 与 `conf/basctl.conf` 模板，仍是一个
安装包。`basctl.conf` 登记为配置文件/noreplace，升级时保留已有内容。`basctl` 是本地命令；
`basagent` 由 systemd 以专用账号 `bas:beangle` 常驻，主目录固定为 `/var/lib/bas`，日志写在
`/var/log/bas/agent/console.out`。
运行时用宿主 `curl` 下载，`make` / `start` / `resolve` / `run` 另需宿主 `jstart` 在 `PATH` 上。
只有 `basagent` 二进制链接 OpenSSL 3.0；因为两者同包，RPM 的自动依赖会把
`libssl.so.3` / `libcrypto.so.3` 记在整个安装包上，但只运行 `basctl` 时不会加载它们。

升级安装包会刷新标准控制脚本、`daemon-reload` 并 `try-restart` 正在运行的 `basagent`；
`basctl.conf`、`server.xml` 和日志目录不会被覆盖。
