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
state_dir="$BAS_HOME/agent"
pid_file="$state_dir/agent.pid"
log_file="$state_dir/console.out"

require_basagent() {
  if ! command -v "$basagent_cmd" >/dev/null 2>&1; then
    echo "Cannot run $basagent_cmd; install basagent or set beangle_basagent." >&2
    return 1
  fi
}

pid_is_agent() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  case "$(ps -p "$pid" -o args= 2>/dev/null)" in
    *"$basagent_cmd"*"$conf"*) return 0 ;;
    *) return 1 ;;
  esac
}

agent_start() {
  if [ $# -ne 0 ]; then
    echo "Usage: bas.sh agent-start"
    return 1
  fi
  require_basagent || return 1
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if pid_is_agent "$pid"; then
      echo "agent already running (pid=$pid)"
      return 0
    fi
    rm -f "$pid_file"
  fi
  if [ ! -f "$conf" ]; then
    echo "Cannot find $conf; run bas.sh pull or write it first." >&2
    return 1
  fi

  mkdir -p "$state_dir"
  cd "$BAS_HOME" || return 1
  nohup "$basagent_cmd" "$conf" >>"$log_file" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"

  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    echo "agent exited during startup; see $log_file" >&2
    tail -n 20 "$log_file" >&2 2>/dev/null || true
    return 1
  fi
  echo "agent started (pid=$pid)"
  echo "log: $log_file"
}

agent_stop() {
  if [ $# -ne 0 ]; then
    echo "Usage: bas.sh agent-stop"
    return 1
  fi
  if [ ! -f "$pid_file" ]; then
    echo "agent is not running (no $pid_file)"
    return 0
  fi
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if ! pid_is_agent "$pid"; then
    rm -f "$pid_file"
    echo "agent is not running (removed stale $pid_file)"
    return 0
  fi

  kill "$pid"
  for _ in {1..15}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file"
      echo "agent stopped (pid=$pid)"
      return 0
    fi
    sleep 1
  done
  echo "agent did not stop within 15s (pid=$pid)" >&2
  return 1
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
  echo "  agent-start  Start the background control agent (PID and log under agent/)"
  echo "  agent-stop   Stop the background control agent"
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
  agent-start) agent_start "${@:2}" ;;
  agent-stop)  agent_stop "${@:2}" ;;
  *)        usage ;;
esac
