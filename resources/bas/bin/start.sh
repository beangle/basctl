#!/bin/bash
# 按 farm/server 启动实例：只读本地配置，由 basctl 生成 launch spec 并启动容器。
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

exec "$basctl_cmd" start "$BAS_HOME/conf/server.xml" "$@"
