# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_common.sh` | 打包共用：版本号取自源码常量、`dub clean`、清空 `target/`、`dub build --build=release-nobounds` |
| `build_image.sh` | 构建容器镜像 `basctl:<版本>`（podman；三仓库源码在 Alpine 里现编译，见 [../docs/container.md](../docs/container.md)） |
| `build_deb.sh` | 构建 `.deb`（需 Debian 系或 `dpkg-deb`、`fakeroot`） |
| `build_rpm.sh` | 构建二进制 `.rpm`（需 `rpmbuild`、`fakeroot`，在 Fedora/RHEL 系运行） |
| `container/` | 镜像里的入口脚本与样例 `server.xml`（由 `build_image.sh` 收进构建上下文） |

产物统一输出到 `target/`：

- `target/basctl`：release 二进制
- `target/basctl_<v>-<r>_amd64.deb`：Debian/Ubuntu 安装包
- `target/basctl-<v>-<r>.<arch>.rpm`：Fedora/RHEL 安装包

`<v>` 取自 `src/bas/main.d` 的 `enum basctlVersion`——也就是 `basctl version` 输出的那个值，
包里只有这一处版本声明，包版本与运行时自报版本不会漂移。

`.deb`/`.rpm` 仅安装 `/usr/bin/basctl`。basctl 定位为**命令**而非系统服务（区别于 micdn 的常驻
服务打包：无 systemd 单元、无默认配置、无独立用户），运行时用宿主 `curl` 下载，`make` /
`start` / `resolve` / `run` 另需宿主 `jstart` 在 `PATH` 上。
