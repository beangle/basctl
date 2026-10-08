# 容器化：一机器一出口

把 `basctl` + `jstart` + `setline` + JRE 打成一个镜像，容器里无论有多少 farm / server /
webapp，对外只暴露 `setline` 那一个端口。

```sh
docker run -d --name bas -p 8080:8080 \
  -v ~/bas-work:/var/lib/bas \
  basctl:0.0.1
```

## 为什么出口只有一个

setline 的设计是「回环后端 + 单一 listen」：后端固定 `127.0.0.1:<port>`，入口按路径前缀转发。
容器里每个 server 的 http 端口都只绑在容器内，实例的增删只改路由表，不改端口映射——这正是
setline 最贴的形态：

- 端口映射永远是一行：`-p 8080:8080`；
- 容器内增删 server / webapp 不需要动编排层；
- k8s 视角：setline 当 pod 内的 sidecar / 入口，Service、Ingress、探针都只面对它。

所以容器里的 `conf/server.xml` 有两处约定：

1. `<setline hostname="localhost" endpoint="127.0.0.1:8080"/>`——声明路由命名空间与入口地址。
   出口**监听地址**由入口脚本给（`BAS_SETLINE_LISTEN`，缺省 `*:8080`）：容器里必须监听所有地址，
   写 `127.0.0.1` 在容器外访问不到，端口与 `-p` 的右边一致。绑的是 `*:8080`、拨的是
   `127.0.0.1:8080`，所以这里不写 `listen`（那是 setline 配置里的），`endpoint` 写拨的那一面。
   入口脚本铺这份样例时会按实际端口改写 `endpoint`；自己挂载 `conf/server.xml` 时，端口对不上
   它会警告一句；
2. `<server http="0"/>`（或不写 http）——端口交给 basctl 在容器内分配（缺省
   `20000-29999`），由 [server.info](server-info.md) 记下来供 setline 对账，不会被 publish。

只做端口映射、不配 `<setline>` 也是可以的，但那就退化成「每个 server 端口都得自己 publish」，
入口脚本会明确警告一句。

## 镜像内容

| 层 | 内容 |
|---|---|
| 构建阶段 | `alpine:3.23` + apk 的 `ldc` / `dub` / `build-base`，在镜像内编译三份源码 |
| 运行阶段 | `alpine:3.23` + `openjdk25-jre`（+ `tzdata`、`fontconfig`、`font-dejavu`）、`curl`、`bash`、`bzip2`、`su-exec` |
| 二进制 | `/usr/bin/basctl`、`/usr/bin/jstart`、`/usr/bin/setline`，D 运行库收在 `/usr/lib/bas/`（`LD_LIBRARY_PATH`） |
| 样例配置 | `/opt/bas/server.xml`（挂载的 `BAS_HOME` 里没有 `conf/server.xml` 时才铺一份） |

**为什么在镜像里编译，而不是搬宿主二进制**：宿主 `ldc` 产出的 `libphobos2-ldc-shared.so` 链接
宿主 glibc（且宿主 glibc 往往比基础镜像新），搬进 Alpine 会以
`GLIBC_ABI_DT_RELR not found` 之类的方式起不来。多阶段 + musl 让二进制与运行环境用同一套
libc——这条路由 micdn 先走过（`micdn/Dockerfile`、`docs/container_build.md`）。

**JRE 为什么是 25**：bas 0.14.0 的引擎构件（`beangle-bas-engine`、`beangle-bas-juli`）按
class file 版本 69 发布，21 的 JVM 只认到 65，实例会在 `Bootstrap` 静态初始化时抛
`UnsupportedClassVersionError`，表现为 `basctl start` 报告实例启动失败。Alpine 3.23 的
`openjdk25` 是 25.0.4，与构建引擎用的宿主工具链同版本；降版本前先看一眼引擎构件的字节码
版本。

**为什么不是 headless**：webapp 里的图形验证码走 Java2D，需要 `libfontmanager.so`，
`-headless` 包不含它，context 初始化时会以 `no fontmanager in system library path` 失败，
`basctl start` 只报「实例启动失败」而看不出所以然。因此取完整的 `openjdk25-jre`，并装
`fontconfig` + `font-dejavu` 让 JVM 真能找到字体。

## 构建

```sh
./scripts/build_image.sh          # 产物 basctl:<basctlVersion>
```

三个仓库的源码由脚本收进 `target/image-context/`：basctl 用当前工作副本，jstart / setline 缺省
取同级的 `../jstart`、`../setline` 工作副本（开发态常用，可能领先于已推送的提交），没有才
`git clone`（`JSTART_REF` / `SETLINE_REF` 可指定分支或标签）。镜像标签取自
`src/bas/main.d` 的 `basctlVersion`——与 deb / rpm 同源，也就是 `basctl version` 的输出。

构建依赖两个宿主缓存卷，脚本自动挂上：

- `$HOME/.dub` → `/root/.dub`（dub 依赖，构建前在宿主机 `dub fetch` 取好，`SKIP_DUB_FETCH=1` 可跳过）；
- `$HOME/.cache/alpine-apk` → `/var/cache/apk`（apk 包缓存，`ALPINE_APK_CACHE` 可改）。

所以**不要**直接 `podman build .`：构建上下文是脚本准备的，直接构建既缺源码也缺缓存挂载。

## 运行

```sh
mkdir -p ~/bas-work/conf
cp scripts/container/server.xml ~/bas-work/conf/server.xml   # 从样例改起
docker run -d --name bas -p 8080:8080 -v ~/bas-work:/var/lib/bas basctl:0.0.1
docker logs -f bas
```

卷（`BAS_HOME`，缺省 `/var/lib/bas`）里放的是整套运行态：`conf/server.xml`、
`conf/setline.json`、`servers/*/server.info`、`logs/`，以及 jstart 的本地仓库
`$BAS_HOME/.m2/repository`（入口脚本把 `HOME` 指到 `BAS_HOME`，所以构件缓存随卷一起持久化，
重建容器不用重新下载）。容器里没有 `conf/server.xml` 时入口脚本铺一份样例并打日志。

### 用 podman（rootless）跑的注意点

```sh
podman run -d --name bas --userns=keep-id --init -p 8080:8080 \
  -v ~/bas-work:/var/lib/bas \
  -v ~/.m2/repository:/var/lib/bas/.m2/repository \
  localhost/basctl:0.0.1
```

- **`--userns=keep-id`**：不加时容器里是 root，入口脚本那句 `chown -R bas:beangle` 会把宿主
  卷的文件属主改成容器的 subuid，宿主机上就不好管了；加了以后容器进程就是宿主 uid，`chown`
  失败但 `as_bas` 的降权分支自动跳过，功能不受影响（`podman exec … su-exec` 在 keep-id 下会
  报 `setgroups: Operation not permitted`，直接 `podman exec bas-test basctl status` 即可）。
- **挂宿主 `~/.m2/repository`**：引擎构件（`beangle-bas-engine`、`beangle-bas-juli`）目前是
  本地 install 的，公共仓库上没有，不挂的话 `jstart fetch` 会以
  `Cannot fetch org.beangle.bas:…` 让 `basctl start` 失败。挂上后这个仓库同时当缓存用。
- 端口右侧是容器内的 setline 端口，与 `BAS_SETLINE_LISTEN`（缺省 `*:8080`）一致；rootless
  podman 只允许映射 >=1024 的宿主端口。

## 入口脚本做什么

`scripts/container/entrypoint.sh` 不引入新机制，只是把 `basctl` 已有的能力串成守护形态：

1. `mkdir` + `chown` 修好卷的属主（绑定目录常常是 root 的），之后所有 `basctl` 调用用
   `su-exec` 降权到 `bas` 用户（`bin/*.sh` 拒绝 root 运行）；
2. 没有 `conf/server.xml` 就铺样例；
3. `basctl init "$BAS_HOME"` 补齐 `bin/*.sh` 控制脚本（已存在的保留）；
4. 删掉 `servers/*/server.info`——**新容器 = 新进程空间**，上一轮的 pid 已经指不到任何人，
   留着会让路由和 `status` 指向别的进程；
5. setline：容器入口**自己拉起它**（容器里 setline 的进程归入口脚本）——卷里没有
   `conf/setline.json` 时先 `basctl setline --endpoint=$BAS_SETLINE_LISTEN` 渲染一份（这里给绑的
   形态 `*:8080`，和写进文件的 `listen` 一致），再 `setline -f conf/setline.json` 常驻，日志
   `logs/setline.out`；basctl 推路由拨的是 `conf/server.xml` 里 `<setline endpoint>` 的地址；
6. `basctl start all`：定端口、写运行信息、resolve、后台拉起实例，并把整组路由推给 setline；
7. 前台等信号，收到 SIGTERM / SIGINT 后：`basctl stop all --timeout=$BAS_STOP_TIMEOUT`
   （缺省 8 秒，超时就 `--force`）→ 给 setline 发 SIGTERM（超时 SIGKILL，容器里它没有配置
   需要保全）→ 退出码 0。

`basctl start all` 里任一实例起不来时，入口脚本会 `stop all` 收尾并以非 0 退出——交给编排层
决定重启还是告警，不带着半拉状态继续跑。

## 信号与退出

- `docker stop` / `podman stop` 给 PID 1（入口脚本）发 SIGTERM，脚本优雅停实例、停 setline 后
  退出 0；编排层的默认宽限期是 10 秒，所以 `BAS_STOP_TIMEOUT` 缺省 8 秒，超时自己 `--force`，
  不给编排层留 SIGKILL 的机会。
- 容器进程退出后，PID 命名空间里的残留进程由运行时清理，不需要额外兜底。
- 建议加 `--init`：应用进程是 `basctl start` 用 `nohup` 拉起的，容器起来后会挂到 PID 1 下，
  `--init` 让 tini 负责回收（不加以外的差别只是极少数僵尸进程表项）。

## 非目标

- **容器内不做 supervisor**：某个实例崩了不会自动重启，也没有 `HEALTHCHECK`（podman 以 OCI
  格式提交时会忽略它）。要看「容器到底活着吗」用编排层的探针，要自动重启用编排层的重启策略；
- **不做 host 分组**：一个容器一份 `BAS_HOME`、一个出口（多份 `BAS_HOME` 共享一个 setline 的
  做法见 [setline-config.md](setline-config.md)）；
- **不把 `server.xml` 塞进环境变量**：配置仍然只有 `conf/server.xml` 一个来源，容器只负责挂卷。

## 验收

以下四条要在真有 webapp 的环境里跑一遍才算数（镜像构建本身只到「编译通过、`java -version`
正常」，脚本产出的标签是 `basctl:0.0.1`），实测步骤见本文件「运行」：

- [x] `docker run -p 8080:8080` 后，容器内全部 webapp 都能从宿主机 8080 访问
      （2026-10-07 用 bas-0.14.0 样例在 podman 上验过：`/tools/about` 经 setline 回 200）
- [ ] 容器内增删 server 不需要改 docker 端口映射
- [x] SIGTERM 干净退出，无残留 java 进程（优雅 8 秒 → `--force`）
- [x] 运行期路由能写回卷里的 `conf/setline.json`
