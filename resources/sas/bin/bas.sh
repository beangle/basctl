#!/bin/bash
# bas 控制入口：命令转发给 basctl（控制面/运行器）与各子脚本。
# 脚本本身随 basctl 发布，升级 basctl 后用 `basctl init --force` 刷新。
set -o pipefail

PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ -x "$BAS_HOME/bin/setenv.sh" ]; then
  . "$BAS_HOME/bin/setenv.sh"
fi

# basctl 作为子进程运行，setenv.sh 里未 export 的变量要显式导出
export bas_remote_url

conf="$BAS_HOME/conf/server.xml"

usage() {
  echo "Usage: bas.sh <command> [args]"
  echo "commands:"
  echo "  version     Show version and local hosts         (basctl version)"
  echo "  status      Show running servers                 (basctl status)"
  echo "  resolve     Resolve webapp deps only, no start   (basctl resolve <farm|server|all>)"
  echo "  start       Start instances via jstart           (basctl start <farm|server|all>)"
  echo "  stop        Stop instances started by start      (basctl stop <farm|server|all>)"
  echo "  run         Run one webapp in embedded mode      (basctl run <war|gav|url>)"
  echo "  restart     resolve, then stop + start"
  echo "  pull        Fetch and update conf/server.xml    (basctl pull)"
  exit 1
}

cmd="${1:-status}"
case "$cmd" in
  version)  exec "$basctl_cmd" version ;;
  status)   exec "$basctl_cmd" status ;;
  resolve)  exec "$basctl_cmd" resolve "$conf" "${@:2}" ;;
  start)    exec "$BAS_HOME/bin/start.sh" "${@:2}" ;;
  stop)     exec "$BAS_HOME/bin/stop.sh" "${@:2}" ;;
  run)      exec "$basctl_cmd" run --workdir="$BAS_HOME" "${@:2}" ;;
  restart)  exec "$BAS_HOME/bin/restart.sh" "${@:2}" ;;
  pull)     exec "$basctl_cmd" pull "$BAS_HOME" ;;
  *)        usage ;;
esac
