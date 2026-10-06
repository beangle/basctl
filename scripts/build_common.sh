#!/bin/bash
# 打包脚本共用：版本号与 release 构建。

# 包版本号：以源码里的编译期常量为唯一来源（即 `basctl version` 的输出）。
# 不读 git tag / dub.json，避免包版本与运行时自报版本漂移。
basctl_package_version() {
  local root="${BASCTL_HOME:?BASCTL_HOME not set}"
  local ver
  ver="$(sed -n 's/^enum basctlVersion = "\([^"]*\)";.*$/\1/p' "$root/src/bas/main.d" | head -n 1)"
  if [ -z "$ver" ]; then
    echo "==========================================================" >&2
    echo "Could not determine version from src/bas/main.d" >&2
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
  echo "basctl: dub build --build=release-nobounds --compiler=ldc2"
  dub build --build=release-nobounds --compiler=ldc2
}
