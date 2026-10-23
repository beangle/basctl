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

mkdir -p usr/bin lib/systemd/system etc/logrotate.d
cp -f "$BASCTL_HOME/target/basctl" usr/bin/basctl
cp -f "$BASCTL_HOME/target/basagent" usr/bin/basagent
strip --strip-unneeded usr/bin/basctl
strip --strip-unneeded usr/bin/basagent
chmod 0755 usr/bin/basctl usr/bin/basagent
install -m 0644 "$BASCTL_HOME/resources/systemd/basagent.service" lib/systemd/system/basagent.service
install -m 0644 "$BASCTL_HOME/resources/logrotate/bas" etc/logrotate.d/bas
basctl_stage_runtime_home "$DESTDIR/$PKGDIR"
# DEB 的 conffiles 要求文件在包内；remove 会保留它，只有 purge 才删除。
install -d -m 0755 "$DESTDIR/$PKGDIR/var/lib/bas/conf"
install -m 0600 "$BASCTL_HOME/resources/bas/init/basctl.conf" "$DESTDIR/$PKGDIR/var/lib/bas/conf/basctl.conf"

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
Depends: curl, logrotate
Description: Beangle Bas Server control-plane CLI and agent
 Basctl parses conf/server.xml into runnable container instances: resolve
 webapps, generate jstart launch specs, start/stop instances and render the
 local setline proxy config. Basagent adds explicit config pull plus the
 outbound WebSocket report/control channel. make/start/resolve/run additionally
 need jstart on PATH.
 .
 Main designer: Duan TiHua
EOF

# basagent 以专用账号 bas:beangle 由 systemd 常驻。
cat > DEBIAN/conffiles << 'EOF'
/var/lib/bas/conf/basctl.conf
/etc/logrotate.d/bas
EOF

cat > DEBIAN/preinst << 'EOF'
#!/bin/sh
set -e

getent group beangle >/dev/null || groupadd -r beangle
getent passwd bas >/dev/null || useradd -r -g beangle -d /var/lib/bas -s /bin/bash \
  -c "Beangle bas service" bas
exit 0
EOF

cat > DEBIAN/postinst << 'EOF'
#!/bin/sh
set -e

mkdir -p /var/lib/bas /var/log/bas /var/log/bas/agent
chown bas:beangle /var/lib/bas /var/log/bas /var/log/bas/agent
chown -R bas:beangle /var/lib/bas/bin /var/lib/bas/conf
chmod 0750 /var/lib/bas /var/lib/bas/bin /var/lib/bas/conf /var/log/bas
chmod 0755 /var/lib/bas/bin/*.sh
chmod 0600 /var/lib/bas/conf/basctl.conf
chmod 0700 /var/log/bas/agent
if [ ! -e /var/lib/bas/logs ]; then
  ln -s /var/log/bas /var/lib/bas/logs
fi
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable basagent.service >/dev/null 2>&1 || :
if [ "$1" = "configure" ] && [ -n "$2" ]; then
  systemctl try-restart basagent.service >/dev/null 2>&1 || :
fi
exit 0
EOF

cat > DEBIAN/prerm << 'EOF'
#!/bin/sh
set -e

if [ "$1" = "remove" ]; then
  systemctl stop basagent.service >/dev/null 2>&1 || :
  systemctl disable basagent.service >/dev/null 2>&1 || :
fi
exit 0
EOF

cat > DEBIAN/postrm << 'EOF'
#!/bin/sh
set -e

systemctl daemon-reload >/dev/null 2>&1 || :
exit 0
EOF

chmod 0755 DEBIAN/preinst DEBIAN/postinst DEBIAN/prerm DEBIAN/postrm

popd > /dev/null

# 构建 deb 包（-Zxz 压缩，不支持则用默认）
fakeroot dpkg-deb --build -Zxz "$PKGDIR" "$DESTDIR/$DEBFILE" 2>/dev/null || \
fakeroot dpkg-deb --build "$PKGDIR" "$DESTDIR/$DEBFILE"

rm -rf "$PKGDIR"

echo "Built: $DESTDIR/$DEBFILE"
