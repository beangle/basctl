#!/bin/bash
# Debian/Ubuntu 打包脚本。需在 Debian 系系统运行，或安装 dpkg：apt install dpkg-dev fakeroot
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export BASCTL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BASCTL_HOME"

set -e -o pipefail
# shellcheck source=build_common.sh
source "$SCRIPT_DIR/build_common.sh"

ferror(){
  echo "==========================================================" >&2
  echo "$1" >&2
  echo "$2" >&2
  echo "==========================================================" >&2
  exit 1
}

E=0
LIST=""
fcheck(){
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck dpkg-deb
fcheck fakeroot
fcheck strip
fcheck dub
if [ $E -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

basctl_prepare_release_build

MAINTAINER="duantihua <duantihua@163.com>"
VERSION=$(basctl_package_version)
REVISION="1"
[[ -n "$1" ]] && REVISION="$1"
DESTDIR="$BASCTL_HOME/target"
ARCH="amd64"
DEBFILE="basctl_${VERSION}-${REVISION}_${ARCH}.deb"
PKGDIR="$DESTDIR/basctl_${VERSION}-${REVISION}_${ARCH}"

rm -f "$DESTDIR/$DEBFILE"
rm -rf "$PKGDIR"

mkdir -p "$PKGDIR"
pushd "$PKGDIR" > /dev/null

# 定位为命令而非系统服务：仅安装 /usr/bin/basctl，无 systemd 单元、无默认配置
mkdir -p usr/bin
cp -f "$BASCTL_HOME/target/basctl" usr/bin/basctl
strip --strip-unneeded usr/bin/basctl
chmod 0755 usr/bin/basctl

# DEBIAN 控制文件
mkdir -p DEBIAN

# control
cat > DEBIAN/control << EOF
Package: basctl
Version: ${VERSION}-${REVISION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Homepage: https://github.com/beangle/basctl
Depends: curl
Description: Beangle Bas Server control-plane CLI
 Parse conf/server.xml into runnable container instances: resolve webapps,
 generate jstart launch specs, start/stop instances, pull configs and render
 the local setline proxy config. make/start/resolve/run additionally need
 jstart on PATH.
 .
 Main designer: Duan TiHua
EOF

# CLI 工具：无 conffiles，也无需 preinst/postinst/prerm/postrm（无服务、无用户、无配置）

popd > /dev/null

# 构建 deb 包（-Zxz 压缩，不支持则用默认）
fakeroot dpkg-deb --build -Zxz "$PKGDIR" "$DESTDIR/$DEBFILE" 2>/dev/null || \
fakeroot dpkg-deb --build "$PKGDIR" "$DESTDIR/$DEBFILE"

rm -rf "$PKGDIR"

echo "Built: $DESTDIR/$DEBFILE"
