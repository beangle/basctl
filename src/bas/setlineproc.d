/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/**
 * setline 的运行期路由同步：解析入口、探测、推送、对账。
 *
 * setline 是**机器级服务**（systemd / 容器入口 / 手工拉起），basctl 不拉它也不停它，所以这里
 * 没有 pid 文件、没有就地启动：只做「入口在哪 / 在不在 / 把本 BAS_HOME 的整组路由推进自己的
 * 命名空间」三件事——进程归谁起，谁负责停。
 *
 * 管理口端口由 {@link bas.endpoint.resolveSetlinePort} 统一解析（只认 `server.xml` 的
 * `<setline port>`，没有缺省、没有命令行覆盖）；命名空间来自
 * `server.xml` 的 `<setline hostname>`（缺省 `localhost`）。一台机器上共享同一个 setline 的多份
 * `BAS_HOME` 靠命名空间各占一格——`PUT /_setline/routes/all?host=<ns>` 只替换自己那一格。
 *
 * 管理口（`<setline port>`）是 setline 的写接口所在：它只在管理口上，而管理口缺省绑回环，
 * 于是"只有本机能改流量走向"是 TCP 层的事实。读接口（`GET /_setline/routes`）只在 `status` 的
 * route 列里用一次（{@link fetchRouteTable}），同样从 localhost 发——setline 的读接口对回环来源
 * 一律放行，不需要任何凭据。写永远拨回环，所以配置里只有端口（见 {@link bas.endpoint}）。
 */
module bas.setlineproc;

import bas.endpoint : adminAddress, portFree;
import bas.setline : SetlineRoute, renderRouteMap;

import std.conv : to;
import std.format : format;
import std.process : Config, execute;
import std.stdio : stderr, writeln;
import std.string : lastIndexOf, strip;

/** 路由推送结果：写成功 / 有应答被拒 / 连不上。 */
enum RouteSync {
  synced,
  rejected,
  unreachable
}

/**
 * 把本 `BAS_HOME` 的整组路由推给 setline，返回 0 表示已推到位。
 *
 * 入口没在跑**不**就地拉起：setline 的起停归 systemd / 容器入口，basctl 越俎代庖会让「谁拥有
 * 进程」说不清。推不上去不影响应用本身（`start` / `stop` 只警告，见 `bas.starter`），这里把原因
 * 写清楚，让人去把服务起起来。`quiet` 只影响成功时的输出，对账路径用它避免周期刷屏。
 */
int syncRoutesToSetline(const(SetlineRoute)[] routes, ushort port, string hostname,
    bool quiet = false) {
  if (portFree(port)) {
    stderr.writeln("No setline listening on " ~ adminAddress(port)
        ~ "; start the setline service (basctl does not launch it), or point"
        ~ " <setline port=\"...\"> at the right port.");
    return 1;
  }
  final switch (syncRoutes(port, hostname, renderRouteMap(routes))) {
  case RouteSync.synced:
    if (!quiet)
      writeln(format!"%s routes synced to http://%s (host=%s)"(
          routes.length, adminAddress(port), hostname));
    return 0;
  case RouteSync.rejected:
    stderr.writeln("Port " ~ adminAddress(port)
        ~ " answers HTTP but rejected the route update; it is probably not the setline we expect.");
    return 1;
  case RouteSync.unreachable:
    stderr.writeln("Cannot reach setline at " ~ adminAddress(port) ~ ".");
    return 1;
  }
}

/**
 * 把整组路由推给 setline 的一个命名空间：`PUT /_setline/routes/all?host=<hostname>`——幂等，
 * 只替换这个 host 分组，别的分组不受影响（setline 侧是 `replaceRoutes`）。写接口只在管理口上、
 * 且只认本机（回环对端 + 回环 Host），所以能写进去就说明入口上坐的确实是我们能驱动的 setline。
 */
RouteSync syncRoutes(ushort port, string hostname, string routeMapJson) {
  auto body = "{\"routes\":" ~ routeMapJson ~ "}";
  auto res = execute(["curl", "--silent", "--show-error", "--max-time", "5",
      "-o", nullSink, "-w", "%{http_code}",
      "-X", "PUT", "-H", "Content-Type: application/json", "--data-binary", body,
      jsonUrl(port, "/_setline/routes/all?host=" ~ hostname)], null, Config.none);
  if (res.status != 0)
    return RouteSync.unreachable;
  return strip(res.output) == "200" ? RouteSync.synced : RouteSync.rejected;
}

/** 读 setline 路由表的结果。 */
enum RouteRead {
  /** 读到了（下面的 `json` 是 `host -> [route]` 的对象）。 */
  ok,
  /** 403（旧版本是 401）：来源不在 setline 的读名单里——读接口只放行本机与 `peerReaders`。 */
  denied,
  /** 有 HTTP 应答但不是我们认识的 setline（非 200/403）。 */
  unexpected,
  /** 连不上：没人听、超时或 curl 起不来。 */
  unreachable
}

/**
 * `GET /_setline/routes`：读回整张路由表（只读，无副作用）。
 *
 * 写路径要求回环对端加回环 Host，读路径只看**来源地址**：本机一律放行，其它机器要写在 setline 的
 * `peerReaders` 里，否则回 403。basctl 不存任何凭据（写路由走本机门，不需要），所以拿到 403 时
 * 返回 {@link RouteRead.denied}，让人知道"不是没对上账，是这台机器没被列为读方"。`status` 用它
 * 报 route 列。
 */
RouteRead fetchRouteTable(ushort port, out string json) {
  auto res = execute(["curl", "--silent", "--show-error", "--max-time", "5",
      "-w", "\n" ~ httpCodeMarker ~ "%{http_code}",
      jsonUrl(port, "/_setline/routes")], null, Config.none);
  if (res.status != 0)
    return RouteRead.unreachable;
  auto marker = res.output.lastIndexOf(httpCodeMarker);
  if (marker < 0)
    return RouteRead.unreachable;
  json = res.output[0 .. marker];
  auto code = strip(res.output[marker + httpCodeMarker.length .. $]);
  if (code == "200")
    return RouteRead.ok;
  if (code == "403" || code == "401")
    return RouteRead.denied;
  return RouteRead.unexpected;
}

/** `curl -w` 的输出标记：HTTP body 与状态码的分界（body 里不会出现它）。 */
private enum httpCodeMarker = "__basctl_http_code__";

/** Windows 上没有 `/dev/null`。 */
version (Windows) private enum nullSink = "NUL";
else private enum nullSink = "/dev/null";

/** 管理接口 URL。 */
private string jsonUrl(ushort port, string path) {
  return "http://" ~ adminAddress(port) ~ path;
}
