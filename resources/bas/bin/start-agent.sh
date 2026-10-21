#!/bin/bash
# 后台启动控制通道 agent：PID 与输出集中在 agent/ 目录。
set -o pipefail

PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ -f "$BAS_HOME/bin/setenv.sh" ]; then
  . "$BAS_HOME/bin/setenv.sh"
fi

if [ $# -ne 0 ]; then
  echo "Usage:start-agent.sh"
  exit 1
fi

if ! command -v "$basctl_cmd" >/dev/null 2>&1; then
  echo "Cannot run $basctl_cmd; install basctl or set beangle_basctl." >&2
  exit 1
fi

conf="$BAS_HOME/conf/server.xml"
state_dir="$BAS_HOME/agent"
pid_file="$state_dir/agent.pid"
log_file="$state_dir/console.out"

pid_is_agent() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  case "$(ps -p "$pid" -o args= 2>/dev/null)" in
    *agent*"$conf"*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -f "$pid_file" ]; then
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if pid_is_agent "$pid"; then
    echo "agent already running (pid=$pid)"
    exit 0
  fi
  rm -f "$pid_file"
fi

if [ ! -f "$conf" ]; then
  echo "Cannot find $conf; write it or run basctl pull first." >&2
  exit 1
fi

# 与 start.sh 对齐：配置了远端时先尽力刷新；失败只告警，不挡住启动。
if [ "${BAS_SKIP_REMOTE_PULL:-0}" != "1" ] && [ -f "$BAS_HOME/conf/basctl.conf" ]; then
  if ! "$basctl_cmd" pull --if-configured "$BAS_HOME"; then
    echo "warning: cannot refresh conf/server.xml from remote; starting with the existing file." >&2
  fi
fi

mkdir -p "$state_dir"
cd "$BAS_HOME" || exit 1
nohup "$basctl_cmd" agent "$conf" >>"$log_file" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$pid_file"

sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$pid_file"
  echo "agent exited during startup; see $log_file" >&2
  tail -n 20 "$log_file" >&2 2>/dev/null || true
  exit 1
fi

echo "agent started (pid=$pid)"
echo "log: $log_file"
