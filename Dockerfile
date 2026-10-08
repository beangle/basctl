# syntax=docker/dockerfile:1
# basctl 容器镜像：basctl + jstart + setline + JRE，一台机器一个出口（见 docs/container.md）。
#
# 三份源码属于三个独立仓库，构建上下文由 scripts/build_image.sh 准备（basctl/ + jstart/ +
# setline/），因此不要直接 `podman build .`——用 `./scripts/build_image.sh`。
#
# 为什么在镜像里编译：宿主机的 ldc 产物链接宿主的 glibc，直接搬进基础镜像会因为 glibc 版本比
# 镜像新而以 `GLIBC_ABI_DT_RELR not found` 之类的方式起不来。多阶段 + musl 让二进制与运行环境
# 用同一套 libc（与 micdn 同一条路）。

FROM alpine:3.23 AS builder
ENV DUB_HOME=/root/.dub

# /var/cache/apk 由 scripts/build_image.sh 挂载宿主机目录（缺省 ~/.cache/alpine-apk），与
# ~/.dub 同理；别改成 `apk add --no-cache`（它会清空缓存，与持久挂载冲突）。
RUN set -eux; \
  sed -i \
    -e 's|https://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    -e 's|http://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    /etc/apk/repositories; \
  apk add --cache-packages \
    ldc \
    dub \
    build-base \
    binutils \
    zlib-dev \
    openssl-dev \
    git \
    ca-certificates \
    curl \
    bash

WORKDIR /build

# dub 依赖先由宿主机跑 `dub fetch`，再用 -v $HOME/.dub:/root/.dub 带进来；这里不再 RUN dub fetch，
# 否则依赖会被写进镜像层，体积暴涨。

COPY basctl/dub.json basctl/dub.selections.json ./basctl/
COPY basctl/src ./basctl/src
COPY basctl/resources ./basctl/resources
RUN cd basctl \
    && dub build --build=release-nobounds --compiler=ldc2 \
    && strip --strip-unneeded target/basctl

COPY jstart/dub.json ./jstart/
COPY jstart/source ./jstart/source
RUN cd jstart \
    && dub build --build=release-nobounds --compiler=ldc2 \
    && strip --strip-unneeded target/jstart

COPY setline/dub.json setline/dub.selections.json ./setline/
COPY setline/src ./setline/src
RUN cd setline \
    && dub build --build=release-nobounds --compiler=ldc2 \
    && strip --strip-unneeded target/setline

# musl：跳过 libc 与动态加载器（它们在运行镜像里已有且必须配套），其余 .so
# （libphobos2-ldc-shared / libdruntime-ldc-shared 等）收进 /pack。
RUN mkdir -p /pack; \
    for bin in basctl jstart setline; do \
      for f in $(ldd /build/$bin/target/$bin | awk '/=>/ {print $3}' | sort -u); do \
        [ -f "$f" ] || continue; \
        b=$(basename "$f"); \
        case "$b" in \
          libc.so*|ld-linux*|ld-musl*|libc.musl*) ;; \
          *) cp -L "$f" /pack/ ;; \
        esac; \
      done; \
    done

# --- 运行态 ---

FROM alpine:3.23

# jstart / basctl 运行期要用的外部命令：curl（下载构件）、/bin/sh（spec 里的命令行）、
# bash（bin/*.sh 控制脚本）、tar/gzip（busybox 自带，jstart 解压原生包）、bzip2（增量补丁）。
#
# JRE 取 25：bas 0.14.0 的引擎构件（beangle-bas-engine / beangle-bas-juli）按 class file
# 版本 69 发布，21 会在启动时抛 UnsupportedClassVersionError。Alpine 3.23 的 25.0.4 与宿主
# 工具链同版本，换成 21 之前先确认引擎构件的字节码版本。
#
# 用 openjdk25-jre 而不是 -headless：webapp 里的图形验证码走 Java2D，需要 libfontmanager.so，
# headless 包不含它（会以 `no fontmanager in system library path` 让 context 初始化失败）；
# fontconfig + font-dejavu 提供字体，否则字体列表为空、验证码照样起不来。
RUN set -eux; \
  sed -i \
    -e 's|https://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    -e 's|http://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    /etc/apk/repositories; \
  apk add --cache-packages \
    ca-certificates \
    curl \
    bash \
    bzip2 \
    tzdata \
    su-exec \
    openjdk25-jre \
    fontconfig \
    font-dejavu \
    && addgroup -S beangle \
    && adduser -S -D -G beangle -h /var/lib/bas -s /bin/sh bas \
    && mkdir -p /var/lib/bas /opt/bas \
    && java -version

COPY --from=builder /pack/ /usr/lib/bas/
COPY --from=builder /build/basctl/target/basctl /usr/bin/basctl
COPY --from=builder /build/jstart/target/jstart /usr/bin/jstart
COPY --from=builder /build/setline/target/setline /usr/bin/setline

# BAS_HOME 也是 bas 用户的家目录：jstart 的本地仓库落在 $BAS_HOME/.m2/repository，卷一挂就自带缓存。
ENV LD_LIBRARY_PATH=/usr/lib/bas \
    BAS_HOME=/var/lib/bas

# 入口脚本与随镜像分发的样例配置（只在卷里没有 conf/server.xml 时铺进去）
COPY container/entrypoint.sh /entrypoint.sh
COPY container/server.xml /opt/bas/server.xml

RUN chmod 755 /usr/bin/basctl /usr/bin/jstart /usr/bin/setline /entrypoint.sh \
    && chown -R bas:beangle /var/lib/bas /opt/bas

WORKDIR /var/lib/bas

# 出口端口：容器里 <setline listen> 必须写 `*:<port>` / `0.0.0.0:<port>`，回环地址在容器外访问不到。
EXPOSE 8080

# 不设 HEALTHCHECK：podman 以 OCI 格式提交时会忽略该指令；探活交给编排层（k8s probe 等）。
ENTRYPOINT ["/entrypoint.sh"]
