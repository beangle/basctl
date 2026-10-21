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

# 远端配置：填写了任一字段时尽力刷新 conf/server.xml；空模板直接跳过，
# 失败只告警，继续用本地配置启动
if [ "${BAS_SKIP_REMOTE_PULL:-0}" != "1" ] && [ -f "$BAS_HOME/conf/basctl.conf" ]; then
  if ! "$basctl_cmd" pull --if-configured "$BAS_HOME"; then
    echo "warning: cannot refresh conf/server.xml from remote; starting with the existing file." >&2
  fi
fi

exec "$basctl_cmd" start "$BAS_HOME/conf/server.xml" "$@"
