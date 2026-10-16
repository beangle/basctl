#!/bin/sh
# basctl 容器入口：把「一机器一出口」串成守护形态。
#
# 谁拥有进程谁负责起停：容器里 setline 归入口脚本（写 conf/setline.json → `setline -f` 常驻
# → 停信号时收尾），裸机上归 systemd；basctl 只管把实例的路由推到它的管理口上。
#
# 1. 准备 BAS_HOME（卷可能是刚建好的空目录、属主是 root，先补目录与属主）；
# 2. 清掉上一轮容器留下的运行信息——新进程空间里那些 pid 已经没有意义；
# 3. 写 setline 自己的配置（两个监听，只在卷里没有时）并把它拉起来；basctl 只推路由；
# 4. `basctl start all`：定端口、拉起实例，并把实例路由推给 setline；
# 5. 收到 SIGTERM / SIGINT 后先优雅停实例（超时再 --force），再停 setline，退出码 0。

set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BAS_HOME="${BAS_HOME:-/var/lib/bas}"
# 优雅退出的秒数：编排层（podman/docker stop）的默认宽限期是 10 秒，缺省值要留在它之内，
# 超时后自己 --force，别留残留进程。
STOP_TIMEOUT="${BAS_STOP_TIMEOUT:-8}"
# 出口监听地址：容器里必须监听所有地址（写 127.0.0.1 在容器外访问不到），端口与 `-p` 的右边一致。
SETLINE_LISTEN="${BAS_SETLINE_LISTEN:-*:8080}"
# 管理口：setline 的写接口只在管理口上，basctl 拨的就是它（server.xml 里 <setline port>）。
# 容器内部地址，不对外 publish，所以缺省绑回环——和裸机上一样。
SETLINE_ADMIN_LISTEN="${BAS_SETLINE_ADMIN_LISTEN:-127.0.0.1:10080}"
# server.xml 里只写端口（管理口只认回环，地址没有可配的余地）。
SETLINE_ADMIN_PORT="${SETLINE_ADMIN_LISTEN##*:}"
SERVER_XML="$BAS_HOME/conf/server.xml"
SETLINE_CONF="$BAS_HOME/conf/setline.json"
# HOME 也指到 BAS_HOME：jstart 的本地仓库缺省是 $HOME/.m2/repository，这样卷一挂就自带构件缓存，
# 不会去写容器里 root 的家目录（bas 用户也写不进去）。
export BAS_HOME HOME="$BAS_HOME"

log() { echo "[entrypoint] $*"; }

# 控制脚本（bin/*.sh）拒绝以 root 运行，所以除改属主外的每一个 basctl 调用都降权到 bas。
as_bas() {
  if [ "$(id -u)" = 0 ] && command -v su-exec >/dev/null 2>&1; then
    su-exec bas "$@"
  else
    "$@"
  fi
}

mkdir -p "$BAS_HOME"
chown -R bas:beangle "$BAS_HOME" 2>/dev/null || true

if [ ! -f "$SERVER_XML" ]; then
  cp /opt/bas/server.xml "$SERVER_XML"
  # 样例里写的是缺省管理口；BAS_SETLINE_ADMIN_LISTEN 改了就把这里一起改掉，两边始终一致。
  sed -i "s#port=\"10080\"#port=\"$SETLINE_ADMIN_PORT\"#" "$SERVER_XML"
  log "no $SERVER_XML; installed the sample config (mount $BAS_HOME to use your own)"
elif ! grep -Fq "port=\"$SETLINE_ADMIN_PORT\"" "$SERVER_XML"; then
  log "WARNING: $SERVER_XML 的 <setline port> 看起来不是 $SETLINE_ADMIN_LISTEN"
  log "         （BAS_SETLINE_ADMIN_LISTEN=$SETLINE_ADMIN_LISTEN）——basctl 会按配置里的端口推路由"
fi

# 铺控制脚本：缺哪个补哪个，已存在的一律保留（用户可能改过）。
as_bas basctl init "$BAS_HOME"

for info in "$BAS_HOME"/servers/*/server.info; do
  [ -e "$info" ] || continue
  rm -f "$info"
  log "removed stale run info $info"
done

setline_pid=""
stopping=0

stop_all() {
  [ "$stopping" = 1 ] && return
  stopping=1
  log "stopping instances (timeout ${STOP_TIMEOUT}s)"
  if ! as_bas basctl stop all --timeout="$STOP_TIMEOUT"; then
    log "graceful stop did not finish, forcing"
    as_bas basctl stop all --force || log "force stop reported errors"
  fi
  if [ -n "$setline_pid" ] && kill -0 "$setline_pid" 2>/dev/null; then
    log "stopping setline (pid=$setline_pid)"
    kill -TERM "$setline_pid" 2>/dev/null || true
    waited=0
    while kill -0 "$setline_pid" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -KILL "$setline_pid" 2>/dev/null || true
  fi
}

trap 'stop_all; exit 0' TERM INT

if grep -q "<setline" "$SERVER_XML"; then
  if [ ! -f "$SETLINE_CONF" ]; then
    # setline 自己那份配置（两个监听）归入口脚本，因为它拥有这个进程；basctl 不生成它、也不碰
    # 它的端口。routes 先留空，由 `basctl start all` 之后的路由对账推给管理口。
    cat >"$SETLINE_CONF" <<EOF
{
  "listen": "$SETLINE_LISTEN",
  "adminListen": "$SETLINE_ADMIN_LISTEN",
  "routes": {}
}
EOF
    chown bas:beangle "$SETLINE_CONF" 2>/dev/null || true
    log "wrote $SETLINE_CONF (listen=$SETLINE_LISTEN, adminListen=$SETLINE_ADMIN_LISTEN)"
  fi
  mkdir -p "$BAS_HOME/logs"
  setline -f "$SETLINE_CONF" >>"$BAS_HOME/logs/setline.out" 2>&1 &
  setline_pid=$!
  log "setline started (pid=$setline_pid, listen=$SETLINE_LISTEN, admin=$SETLINE_ADMIN_LISTEN, log=$BAS_HOME/logs/setline.out)"
  sleep 1
  if ! kill -0 "$setline_pid" 2>/dev/null; then
    log "setline exited during startup; see $BAS_HOME/logs/setline.out"
    exit 1
  fi
else
  log "WARNING: no <setline> in $SERVER_XML; publish every server port instead of one entry"
fi

if ! as_bas basctl start all; then
  log "start failed; see $BAS_HOME/logs"
  stop_all
  exit 1
fi

log "started; entry config $SERVER_XML; send SIGTERM (podman stop) to stop"
# `wait` 会被信号打断，sleep 在后台起是为了让 trap 能及时跑起来（POSIX sh 没有别的办法）
while :; do
  sleep 5 &
  wait $!
done
