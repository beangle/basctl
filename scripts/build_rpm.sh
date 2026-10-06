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

mkdir -p usr/bin
cp -f "$BASCTL_HOME/target/basctl" usr/bin/basctl
strip --strip-unneeded usr/bin/basctl
chmod 0755 usr/bin/basctl
chmod -R 0755 .

# 运行时依赖：curl 负责下载（pull / war 直链）；jstart 由 make/start/resolve/run 使用，
# 但不作为硬依赖，否则只想用 init/banner/pull 的机器装不上。
DEPEND="curl"

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
Parse conf/server.xml into runnable container instances: resolve webapps,
generate jstart launch specs, start/stop instances, pull configs and render
the local setline proxy config. make/start/resolve/run additionally need
jstart on PATH.
Main designer: Duan TiHua

%changelog
$(printf '%b' "$changes")

%files
EOF

# 定位为命令而非系统服务：只安装 /usr/bin/basctl，无 systemd 单元、
# 无 %pre/%post/%preun 服务启停脚本、无独立用户
find "$DESTDIR/$PKGDIR" ! -type d | \
  sed 's|'"$DESTDIR"'/'"$PKGDIR"'|/|' >> basctl.spec

echo >> basctl.spec
mkdir -p "$RPMDIR"
echo "%define _rpmdir $RPMDIR" >> basctl.spec
fakeroot rpmbuild --quiet --buildroot="$DESTDIR/$PKGDIR" -bb --target "$ARCH" \
  --define '_binary_payload w9.xzdio' basctl.spec

popd > /dev/null
mv "$RPMDIR/$ARCH/basctl-$VERSION-$REVISION.$ARCH.rpm" "$DESTDIR/$RPMFILE"

rm -rf "$RPMDIR" "$DESTDIR/$PKGDIR" "$DESTDIR/basctl.spec"

echo "Built: $DESTDIR/$RPMFILE"
