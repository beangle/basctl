#!/bin/bash
# 停止 `start.sh` 启动的实例：直接交给 `basctl stop`（按 servers/<name>/server.info 里的 pid 停）。
PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ $# -eq 0 ]; then
  echo "Usage:stop.sh server_name or farm_name"
  exit 1
fi

exec "$basctl_cmd" stop "$BAS_HOME/conf/server.xml" "$@"
