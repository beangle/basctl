#!/bin/bash
# RPM 打包脚本。需安装 rpm-build、fakeroot；在 Fedora/RHEL 系系统运行
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

# rpm 4.14 起才写入 SHA256HEADER；旧版 rpmbuild 只能写 SHA1 头摘要，
# 这种包会被要求 SHA256 摘要的新版 rpm 拒绝为 “does not verify: no digest”。
require_modern_rpmbuild(){
  local version
  version="$(rpmbuild --version | awk '{print $3}')"
  if [ -z "$version" ] || \
    [ "$(printf '%s\n%s\n' "$version" "4.14" | sort -V | head -n 1)" != "4.14" ]; then
    ferror "rpmbuild >= 4.14 is required (found ${version:-unknown})" \
      "A newer rpmbuild is required to emit SHA256HEADER; put it first in PATH."
  fi
}

sys_release_version(){
  local os_id
  os_id=$(source /etc/os-release && echo "$ID")
  if [ "$os_id" = "fedora" ]; then
    REVISION="1.fc$(source /etc/os-release && echo "$VERSION_ID")"
  else
    REVISION="1.el$(source /etc/os-release && echo "$VERSION_ID")"
  fi
}

E=0
LIST=""
fcheck(){
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck gzip
fcheck rpmbuild
fcheck fakeroot
fcheck strip
fcheck dub
if [ $E -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi
require_modern_rpmbuild

basctl_prepare_release_build

MAINTAINER="duantihua <duantihua@163.com>"
VENDOR="Beangle"
VERSION=$(basctl_package_version)
REVISION=""
[[ -n "$1" ]] && REVISION="$1"
if [ -z "$REVISION" ]; then
  sys_release_version
fi
DESTDIR="$BASCTL_HOME/target"
VERSION=$(sed 's/-/~/' <<<"$VERSION") # replace dash by tilde
ARCH="x86_64"

PKGDIR="basctl-${VERSION}-${REVISION}.${ARCH}"
RPMFILE="basctl-${VERSION}-${REVISION}.${ARCH}.rpm"
RPMDIR="$DESTDIR/rpmbuild"

rm -f "$DESTDIR/$RPMFILE"
rm -rf "$DESTDIR/$PKGDIR"
rm -rf "$RPMDIR"

mkdir -p "$DESTDIR/$PKGDIR"
pushd "$DESTDIR/$PKGDIR" > /dev/null

mkdir -p usr/bin usr/lib/systemd/system etc/logrotate.d
cp -f "$BASCTL_HOME/target/basctl" usr/bin/basctl
cp -f "$BASCTL_HOME/target/basagent" usr/bin/basagent
strip --strip-unneeded usr/bin/basctl
strip --strip-unneeded usr/bin/basagent
chmod 0755 usr/bin/basctl usr/bin/basagent
install -m 0644 "$BASCTL_HOME/resources/systemd/basagent.service" usr/lib/systemd/system/basagent.service
install -m 0644 "$BASCTL_HOME/resources/logrotate/bas" etc/logrotate.d/bas
basctl_stage_runtime_home "$DESTDIR/$PKGDIR"
find . -type d -exec chmod 0755 {} +

# 运行时依赖：curl 负责下载（pull / war 直链）；jstart 由 make/start/resolve/run 使用，
# 但不作为硬依赖，否则只想用 init/banner/pull 的机器装不上。basagent 的 OpenSSL 3.0
# 动态库依赖由 rpmbuild 的自动依赖生成记录。
DEPEND="curl, logrotate"

cd ..

# Generate changelog
changes=""
if [ -f "$BASCTL_HOME/CHANGELOG.md" ]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ v ]]; then
      VERSION_INFO=$(echo "$line" | sed 's/## v//')
      VERSION_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 1)
      DATE_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 2 | sed 's/[()]//g')
      # RPM %changelog 要求英文星期/月份；须 LC_ALL=C，否则中文环境会得到「三 1月…」而 rpmbuild 报错
      if [ -n "$DATE_PART" ]; then
        RPM_DATE=$(LC_ALL=C date -d "$DATE_PART" '+%a %b %d %Y' 2>/dev/null || LC_ALL=C date '+%a %b %d %Y')
      else
        RPM_DATE=$(LC_ALL=C date '+%a %b %d %Y')
      fi
      changes+="* $RPM_DATE $MAINTAINER - ${VERSION_PART}\n"
    elif [[ "$line" =~ ^- ]]; then
      changes+="  ${line}\n"
    fi
  done < "$BASCTL_HOME/CHANGELOG.md"
fi
if [ -z "$changes" ]; then
  DATE=$(LC_ALL=C date '+%a %b %d %Y')
  changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
  changes+="  - basctl binary package\n"
fi

cat > basctl.spec <<EOF
Name: basctl
Version: ${VERSION}
Release: ${REVISION}
Summary: Beangle Bas Server control-plane CLI
Group: Applications/System
License: GPL-3.0-or-later
URL: https://github.com/beangle/basctl
Vendor: ${VENDOR}
Packager: ${MAINTAINER}
ExclusiveArch: ${ARCH}
Requires: ${DEPEND}
Provides: basctl(${ARCH}) = ${VERSION}-${REVISION}

%description
Basctl parses conf/server.xml into runnable container instances: resolve
webapps, generate jstart launch specs, start/stop instances and render the
local setline proxy config. Basagent adds explicit config pull plus the
outbound WebSocket report/control channel. make/start/resolve/run additionally
need jstart on PATH.
Main designer: Duan TiHua

%pre
getent group beangle >/dev/null || groupadd -r beangle
getent passwd bas >/dev/null || useradd -r -g beangle -d /var/lib/bas -s /bin/bash \
  -c "Beangle bas service" bas
exit 0

%post
mkdir -p /var/lib/bas /var/lib/bas/conf /var/log/bas /var/log/bas/agent
# basctl.conf 是用户配置：只在缺失时从模板生成，升级/重装/卸载都不覆盖或删除。
if [ ! -f /var/lib/bas/conf/basctl.conf ]; then
  install -m 0600 /usr/share/basctl/basctl.conf /var/lib/bas/conf/basctl.conf
fi
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
if [ "\$1" = "2" ]; then
  systemctl try-restart basagent.service >/dev/null 2>&1 || :
fi
exit 0

%preun
if [ "\$1" = "0" ]; then
  systemctl stop basagent.service >/dev/null 2>&1 || :
  systemctl disable basagent.service >/dev/null 2>&1 || :
fi
exit 0

%postun
systemctl daemon-reload >/dev/null 2>&1 || :
exit 0

%changelog
$(printf '%b' "$changes")

%files
EOF

# basagent 以专用账号 bas:beangle 由 systemd 常驻；logrotate 单独作为配置文件安装。
find "$DESTDIR/$PKGDIR" ! -type d | \
  grep -v -e '/etc/logrotate.d/bas$' | \
  sed 's|'"$DESTDIR"'/'"$PKGDIR"'|/|' >> basctl.spec
# %ghost：文件由 %post 生成、属于用户，rpm 卸载时不删除；升级/重装保留原值。
echo '%ghost %config(noreplace) /var/lib/bas/conf/basctl.conf' >> basctl.spec
echo '%config(noreplace) /etc/logrotate.d/bas' >> basctl.spec

echo >> basctl.spec
mkdir -p "$RPMDIR"
echo "%define _rpmdir $RPMDIR" >> basctl.spec
fakeroot rpmbuild --quiet --buildroot="$DESTDIR/$PKGDIR" -bb --target "$ARCH" \
  --define '_binary_payload w9.xzdio' \
  --define '_binary_filedigest_algorithm 8' \
  --define '_source_filedigest_algorithm 8' basctl.spec

popd > /dev/null
mv "$RPMDIR/$ARCH/basctl-$VERSION-$REVISION.$ARCH.rpm" "$DESTDIR/$RPMFILE"

rm -rf "$RPMDIR" "$DESTDIR/$PKGDIR" "$DESTDIR/basctl.spec"

RPMVERIFY="$(LC_ALL=C rpm -Kv "$DESTDIR/$RPMFILE" 2>&1 || true)"
if ! grep -q 'Header SHA256 digest: OK' <<<"$RPMVERIFY"; then
  ferror "Generated RPM has no SHA256 header digest" "$RPMVERIFY"
fi

echo "Built: $DESTDIR/$RPMFILE"
