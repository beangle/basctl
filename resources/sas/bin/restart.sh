#!/bin/bash
# 重启 = resolve（失败即中止，避免停掉却起不来）+ stop + start。
PRGDIR=$(dirname "$0")
export SAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$SAS_HOME/bin/env.sh"

if [ -f "$SAS_HOME/bin/setenv.sh" ]; then
  . "$SAS_HOME/bin/setenv.sh"
fi

if ! "$basctl_cmd" resolve "$SAS_HOME/conf/server.xml" "$@"; then
  echo "resolve failed,restart was aborted."
  exit 1
fi

"$SAS_HOME/bin/stop.sh" "$@"
exec "$SAS_HOME/bin/start.sh" "$@"
