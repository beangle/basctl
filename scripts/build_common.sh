#!/bin/bash
# 打包脚本共用：版本号与 release 构建。

# 包版本号：以源码里的编译期常量为唯一来源（即 `basctl version` 的输出）。
# 不读 git tag / dub.json，避免包版本与运行时自报版本漂移。
basctl_package_version() {
  local root="${BASCTL_HOME:?BASCTL_HOME not set}"
  local ver
  ver="$(sed -n 's/^enum basctlVersion = "\([^"]*\)";.*$/\1/p' "$root/src/bas/versioninfo.d" | head -n 1)"
  if [ -z "$ver" ]; then
    echo "==========================================================" >&2
    echo "Could not determine version from src/bas/versioninfo.d" >&2
    echo '（期望找到：enum basctlVersion = "x.y.z";）' >&2
    echo "==========================================================" >&2
    exit 1
  fi
  printf '%s' "$ver"
}

basctl_prepare_release_build() {
  local root="${BASCTL_HOME:?BASCTL_HOME not set}"
  cd "$root" || exit 1
  echo "basctl: dub clean ..."
  if command -v dub >/dev/null 2>&1; then
    dub clean || true
  fi
  echo "basctl: removing target/ ..."
  rm -rf "$root/target"
  mkdir -p "$root/target"
  echo "basctl: dub build -c basctl --build=release-nobounds --compiler=ldc2"
  dub build -c basctl --build=release-nobounds --compiler=ldc2
  echo "basagent: dub build -c basagent --build=release-nobounds --compiler=ldc2"
  dub build -c basagent --build=release-nobounds --compiler=ldc2
}

# 把标准 BAS_HOME 的控制树装入包根目录：系统包安装后 /var/lib/bas 可直接使用，无需再跑 init。
# basctl.conf 保持 0600；调用方负责把它登记为配置文件，并在安装后把 bin/conf 交给 bas:beangle。
basctl_stage_runtime_home() {
  local root="${BASCTL_HOME:?BASCTL_HOME not set}"
  local pkgroot="$1"
  local bindir="$pkgroot/var/lib/bas/bin"
  local confdir="$pkgroot/var/lib/bas/conf"
  install -d -m 0755 "$bindir" "$confdir"
  for script in env.sh bas.sh start.sh stop.sh restart.sh; do
    install -m 0755 "$root/resources/bas/bin/$script" "$bindir/$script"
  done
  install -m 0600 "$root/resources/bas/init/basctl.conf" "$confdir/basctl.conf"
}
