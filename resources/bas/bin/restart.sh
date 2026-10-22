#!/bin/bash
# 重启 = resolve（失败即中止，避免停掉却起不来）+ stop + start。
PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ -f "$BAS_HOME/bin/setenv.sh" ]; then
  . "$BAS_HOME/bin/setenv.sh"
fi

if ! "$basctl_cmd" resolve "$BAS_HOME/conf/server.xml" "$@"; then
  echo "resolve failed,restart was aborted."
  exit 1
fi

"$BAS_HOME/bin/stop.sh" "$@"
exec "$BAS_HOME/bin/start.sh" "$@"
