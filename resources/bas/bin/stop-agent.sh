#!/bin/bash
# 停止 start-agent.sh 启动的 agent；只处理 agent/agent.pid 指向的 basctl agent。
set -o pipefail

PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ $# -ne 0 ]; then
  echo "Usage:stop-agent.sh"
  exit 1
fi

conf="$BAS_HOME/conf/server.xml"
state_dir="$BAS_HOME/agent"
pid_file="$state_dir/agent.pid"

pid_is_agent() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  case "$(ps -p "$pid" -o args= 2>/dev/null)" in
    *agent*"$conf"*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -f "$pid_file" ]; then
  echo "agent is not running (no $pid_file)"
  exit 0
fi

pid=$(cat "$pid_file" 2>/dev/null || true)
if ! pid_is_agent "$pid"; then
  rm -f "$pid_file"
  echo "agent is not running (removed stale $pid_file)"
  exit 0
fi

kill "$pid"
for _ in {1..15}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    echo "agent stopped (pid=$pid)"
    exit 0
  fi
  sleep 1
done

echo "agent did not stop within 15s (pid=$pid)" >&2
exit 1
