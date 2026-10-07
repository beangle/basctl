#!/bin/sh
# 构建 basctl 容器镜像（Alpine / musl 多阶段），见 docs/container.md。
#
# 镜像里装 basctl + jstart + setline + JRE，而这是三个独立仓库：脚本先把三份源码收进一个临时
# 构建上下文（target/image-context/），再交给 podman 构建——镜像里现编译现用，不搬运宿主二进制
# （宿主 ldc 产物链接宿主 glibc，搬进 Alpine 会因为 glibc 太旧起不来）。
#
# 用法：
#   ./scripts/build_image.sh
#
# 环境变量：
#   JSTART_DIR / SETLINE_DIR   兄弟仓库的工作副本（缺省 ../jstart、../setline）
#   JSTART_REF / SETLINE_REF   副本不存在时 git clone 的分支或标签（缺省仓库默认分支）
#   SKIP_DUB_FETCH=1           跳过宿主机 dub fetch
#   ALPINE_APK_CACHE=路径      apk 缓存目录（缺省 $HOME/.cache/alpine-apk）
#   IMAGE=名字                 镜像名（缺省 basctl）；标签固定为 basctl 的版本号，不给改
#   PODMAN_BUILD_EXTRA=…       额外的 podman build 选项（如 --no-cache），别用来改 -t

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASCTL_HOME="$ROOT"
export BASCTL_HOME
. "$ROOT/scripts/build_common.sh"

# 标签与 deb / rpm 同源：src/bas/main.d 的 basctlVersion，也就是 `basctl version` 的输出。
VERSION="$(basctl_package_version)"
IMAGE="${IMAGE:-basctl}"
CTX="$ROOT/target/image-context"

stage() { # stage <目标目录> <源目录> <要收的顶层条目>...
  dst="$1"
  src="$2"
  shift 2
  mkdir -p "$dst"
  for entry in "$@"; do
    if [ ! -e "$src/$entry" ]; then
      echo "build_image: missing $src/$entry" >&2
      exit 1
    fi
    cp -a "$src/$entry" "$dst/"
  done
}

clone_sibling() { # clone_sibling <仓库地址> <分支或标签> <目标目录>
  if [ -n "$2" ]; then
    git clone --depth 1 --branch "$2" "$1" "$3"
  else
    git clone --depth 1 "$1" "$3"
  fi
}

echo "build_image: version $VERSION (from src/bas/main.d)"
echo "build_image: staging context $CTX"
rm -rf "$CTX"
mkdir -p "$CTX"

# basctl 自己：只收构建需要的部分（dub 清单 + 源码 + 内嵌资源）
stage "$CTX/basctl" "$ROOT" dub.json dub.selections.json src resources

# 兄弟仓库：优先用同级工作副本（开发态常常领先于已推送的提交），没有才去 clone
JSTART_DIR="${JSTART_DIR:-$ROOT/../jstart}"
if [ -d "$JSTART_DIR/source" ]; then
  echo "build_image: jstart from $JSTART_DIR"
  stage "$CTX/jstart" "$JSTART_DIR" dub.json source
else
  echo "build_image: jstart from github (${JSTART_REF:-default branch})"
  clone_sibling https://github.com/beangle/jstart.git "${JSTART_REF:-}" "$CTX/jstart"
fi

SETLINE_DIR="${SETLINE_DIR:-$ROOT/../setline}"
if [ -d "$SETLINE_DIR/src" ]; then
  echo "build_image: setline from $SETLINE_DIR"
  stage "$CTX/setline" "$SETLINE_DIR" dub.json dub.selections.json src
else
  echo "build_image: setline from github (${SETLINE_REF:-default branch})"
  clone_sibling https://github.com/beangle/setline.git "${SETLINE_REF:-}" "$CTX/setline"
fi

cp "$ROOT/Dockerfile" "$CTX/Dockerfile"
mkdir -p "$CTX/container"
cp "$ROOT/scripts/container/entrypoint.sh" "$ROOT/scripts/container/server.xml" "$CTX/container/"

# dub 依赖先在宿主机取好（下面以卷挂进构建容器），否则构建会把整包依赖写进镜像层
if [ "${SKIP_DUB_FETCH:-0}" != "1" ]; then
  if command -v dub >/dev/null 2>&1; then
    for dir in "$CTX/basctl" "$CTX/jstart" "$CTX/setline"; do
      echo "build_image: dub fetch in $dir"
      (cd "$dir" && dub fetch)
    done
  else
    echo "build_image: dub not in PATH, skipping dub fetch (set SKIP_DUB_FETCH=1 to silence)" >&2
  fi
else
  echo "build_image: SKIP_DUB_FETCH=1, skipping dub fetch"
fi

DUB_VOL="-v ${HOME}/.dub:/root/.dub"
APK_CACHE="${ALPINE_APK_CACHE:-$HOME/.cache/alpine-apk}"
mkdir -p "$APK_CACHE"
echo "build_image: apk cache $APK_CACHE -> /var/cache/apk"
echo "build_image: building $IMAGE:$VERSION"

# shellcheck disable=SC2086
exec podman build --squash \
  $DUB_VOL \
  -v "$APK_CACHE:/var/cache/apk" \
  -f "$CTX/Dockerfile" \
  -t "$IMAGE:$VERSION" \
  $PODMAN_BUILD_EXTRA \
  "$CTX"
