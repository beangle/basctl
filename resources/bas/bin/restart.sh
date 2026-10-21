#!/bin/bash
# 重启 = resolve（失败即中止，避免停掉却起不来）+ stop + start。
PRGDIR=$(dirname "$0")
export BAS_HOME=$(cd "$PRGDIR/../" >/dev/null; pwd)
. "$BAS_HOME/bin/env.sh"

if [ -f "$BAS_HOME/bin/setenv.sh" ]; then
  . "$BAS_HOME/bin/setenv.sh"
fi

# 先尽力拉取新配置（空模板跳过），再 resolve；拉取失败时仍用现有 server.xml 做停机前检查。
if [ -f "$BAS_HOME/conf/basctl.conf" ]; then
  if ! "$basctl_cmd" pull --if-configured "$BAS_HOME"; then
    echo "warning: cannot refresh conf/server.xml from remote; restart continues with the existing file." >&2
  fi
fi

if ! "$basctl_cmd" resolve "$BAS_HOME/conf/server.xml" "$@"; then
  echo "resolve failed,restart was aborted."
  exit 1
fi

"$BAS_HOME/bin/stop.sh" "$@"
BAS_SKIP_REMOTE_PULL=1 exec "$BAS_HOME/bin/start.sh" "$@"
