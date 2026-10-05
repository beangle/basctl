#!/bin/bash
# 按 farm/server 启动实例：刷新远端配置后交给 `basctl start`，
# 由 basctl 生成 launch spec 并委托 jstart 后台运行容器。
PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ $# -eq 0 ]; then
  echo "Usage:start.sh server_name or farm_name"
  exit 1
fi

if [ -f "$BAS_HOME/bin/setenv.sh" ]; then
  . "$BAS_HOME/bin/setenv.sh"
fi

# basctl 作为子进程运行，setenv.sh 里未 export 的变量要显式导出
export bas_remote_url

# 远端配置：非离线时先刷新 conf/server.xml（与旧行为一致，取不到即中止启动）
if [ -n "$bas_remote_url" ] && [ "$bas_remote_connect" != "offline" ]; then
  if ! "$basctl_cmd" pull "$BAS_HOME"; then
    echo "cannot get server.xml,startup was aborted."
    exit 1
  fi
fi

exec "$basctl_cmd" start "$BAS_HOME/conf/server.xml" "$@"
