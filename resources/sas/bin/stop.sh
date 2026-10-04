#!/bin/bash
# 停止 `start.sh` 启动的实例：直接交给 `basctl stop`（逐个 jstart stop 对应的 spec）。
PRGDIR=$(dirname "$0")
export SAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$SAS_HOME/bin/env.sh"

if [ $# -eq 0 ]; then
  echo "Usage:stop.sh server_name or farm_name"
  exit 1
fi

exec "$basctl_cmd" stop "$SAS_HOME/conf/server.xml" "$@"
