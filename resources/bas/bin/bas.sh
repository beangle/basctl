#!/bin/bash
# bas 控制入口：本地命令交给 basctl，远端通道交给 basagent。
# 脚本本身随 basctl 发布，升级 basctl 后用 `basctl init --force` 刷新。
set -o pipefail

PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ -x "$BAS_HOME/bin/setenv.sh" ]; then
  . "$BAS_HOME/bin/setenv.sh"
fi

conf="$BAS_HOME/conf/server.xml"

require_basagent() {
  if ! command -v "$basagent_cmd" >/dev/null 2>&1; then
    echo "Cannot run $basagent_cmd; install basagent or set beangle_basagent." >&2
    return 1
  fi
}

usage() {
  echo "Usage: bas.sh <command> [args]"
  echo "commands:"
  echo "  version     Show logo, versions and local hosts  (basctl banner)"
  echo "  status      Running instances from server.info    (basctl status)"
  echo "  resolve     Resolve webapp deps only, no start   (basctl resolve <farm|server|all>)"
  echo "  start       Start instances via jstart           (basctl start <farm|server|all>)"
  echo "  stop        Stop instances started by start      (basctl stop <farm|server|all>)"
  echo "  run         Run one webapp in embedded mode      (basctl run --engine=<type>-<ver> <war>)"
  echo "  logs        Tail an instance console log          (basctl logs <farm.server> [-n N] [-f])"
  echo "  setline     Push the routes to setline         (basctl setline [--sync])"
  echo "  restart     resolve, then stop + start"
  echo "  pull         Fetch and update conf/server.xml   (basagent pull)"
  exit 1
}

cmd="${1:-status}"
case "$cmd" in
  version)  exec "$basctl_cmd" banner "$conf" ;;
  status)   exec "$basctl_cmd" status ;;
  resolve)  exec "$basctl_cmd" resolve "$conf" "${@:2}" ;;
  start)    exec "$BAS_HOME/bin/start.sh" "${@:2}" ;;
  stop)     exec "$BAS_HOME/bin/stop.sh" "${@:2}" ;;
  run)      exec "$basctl_cmd" run --workdir="$BAS_HOME" "${@:2}" ;;
  logs)     exec "$basctl_cmd" logs "$conf" "${@:2}" ;;
  setline)  exec "$basctl_cmd" setline "$conf" "${@:2}" ;;
  restart)  exec "$BAS_HOME/bin/restart.sh" "${@:2}" ;;
  pull)        require_basagent || exit 1; exec "$basagent_cmd" pull "$BAS_HOME" ;;
  *)        usage ;;
esac
