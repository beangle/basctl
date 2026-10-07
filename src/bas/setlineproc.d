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
 * 入口地址由 {@link bas.endpoint.resolveSetlineEndpoint} 统一解析（`--endpoint` > `server.xml` 的
 * `<setline endpoint>`，没有缺省）；命名空间来自
 * `server.xml` 的 `<setline hostname>`（缺省 `localhost`）。一台机器上共享同一个 setline 的多份
 * `BAS_HOME` 靠命名空间各占一格——`PUT /__setline/routes/all?host=<ns>` 只替换自己那一格。
 *
 * 本模块只走 setline 的**写**接口：它只认本机、不需要 token（路由表将来会开放给同网段的服务
 * 进程读取，那条**读**路径才有 token，basctl 用不上）。
 */
module bas.setlineproc;

import bas.endpoint : ListenEndpoint, probeHost, portFree;
import bas.serverinfo : liveInstances;
import bas.setline : SetlineRoute, renderRouteMap, runningPlan;

import core.thread : Thread;
import core.time : msecs;

import std.array : join;
import std.conv : to;
import std.format : format;
import std.path : buildPath;
import std.process : Config, execute;
import std.stdio : stderr, stdout, writeln;
import std.string : strip;

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
int syncRoutesToSetline(const(SetlineRoute)[] routes, ListenEndpoint endpoint, string hostname,
    bool quiet = false) {
  if (portFree(endpoint)) {
    stderr.writeln("No setline listening on " ~ endpoint.toString()
        ~ "; start the setline service (basctl does not launch it), or point"
        ~ " <setline endpoint=\"...\"> at the right address.");
    return 1;
  }
  final switch (syncRoutes(endpoint, hostname, renderRouteMap(routes))) {
  case RouteSync.synced:
    if (!quiet)
      writeln(format!"%s routes synced to http://%s (host=%s)"(
          routes.length, endpoint.toString(), hostname));
    return 0;
  case RouteSync.rejected:
    stderr.writeln("Port " ~ endpoint.toString()
        ~ " answers HTTP but rejected the route update; it is probably not the setline we expect.");
    return 1;
  case RouteSync.unreachable:
    stderr.writeln("Cannot reach setline at " ~ endpoint.toString() ~ ".");
    return 1;
  }
}

/**
 * 把整组路由推给 setline 的一个命名空间：`PUT /__setline/routes/all?host=<hostname>`——幂等，
 * 只替换这个 host 分组，别的分组不受影响（setline 侧是 `replaceRoutes`）。写接口只认本机来源，
 * 所以能写进去就说明入口上坐的确实是我们能驱动的 setline。
 */
RouteSync syncRoutes(ListenEndpoint endpoint, string hostname, string routeMapJson) {
  auto body = "{\"routes\":" ~ routeMapJson ~ "}";
  auto res = execute(["curl", "--silent", "--show-error", "--max-time", "5",
      "-o", nullSink, "-w", "%{http_code}",
      "-X", "PUT", "-H", "Content-Type: application/json", "--data-binary", body,
      jsonUrl(endpoint, "/__setline/routes/all?host=" ~ hostname)], null, Config.none);
  if (res.status != 0)
    return RouteSync.unreachable;
  return strip(res.output) == "200" ? RouteSync.synced : RouteSync.rejected;
}

/**
 * `basctl setline --watch`：轮询 `servers/<name>/server.info`，把「现状」路由整组推给 setline。
 *
 * 输入只有运行信息：pid 不存活即视为不存在，因此 `kill -9`、手工起停、端口漂移都会在下一个周期
 * 被纠正；只改 `server.xml` 而实例没重启时路由不变（跟随实例，而不是跟随当前配置）。路由只在
 * 算出的结果与上次推过的不一样时才推，连续对账不产生多余请求。
 *
 * 不退出（交给 systemd / 终端），停掉它不影响 setline 已有的路由。push 失败只警告：setline 挂了
 * 不该让对账进程死掉，下一个周期会重试。
 */
int watchRoutes(string basHome, ListenEndpoint endpoint, string hostname, int intervalSec) {
  writeln(format!"watching %s for route changes (interval=%ss, endpoint=%s, host=%s; ctrl-c to stop)"(
      buildPath(basHome, "servers"), intervalSec, endpoint.toString(), hostname));

  string pushed;
  string reportedConflict;
  for (;;) {
    auto plan = runningPlan(liveInstances(basHome));
    if (plan.conflicts.length) {
      // 冲突时不动路由：现有路由继续服务，修好冲突（改 <url path>）后下一周期自然会推
      string[] lines;
      foreach (conflict; plan.conflicts)
        lines ~= "route conflict on " ~ conflict.path ~ ": declared by " ~ conflict.webapps.join(", ");
      auto text = lines.join("\n");
      if (text != reportedConflict) {
        stderr.writeln(text);
        reportedConflict = text;
      }
    } else {
      reportedConflict = "";
      auto routeMap = renderRouteMap(plan.routes);
      if (routeMap != pushed) {
        if (syncRoutesToSetline(plan.routes, endpoint, hostname, true) == 0)
          pushed = routeMap;
      }
    }
    // 守护进程的 stdout 常常重定向到文件（systemd / nohup），默认全缓冲会把日志攥在手里，
    // 每轮显式刷一次，日志才跟得上。
    stdout.flush();
    Thread.sleep(msecs(intervalSec * 1000));
  }
}

/** 解析 `--interval=<sec>`：正整数秒，非法即抛异常（带上 `--interval=` 的写法）。 */
int parseWatchInterval(string text) {
  int seconds;
  try
    seconds = strip(text).to!int;
  catch (Exception)
    throw new Exception("Invalid --interval value: " ~ text);
  if (seconds <= 0)
    throw new Exception("Invalid --interval value: " ~ text);
  return seconds;
}

/** `--watch` 的缺省轮询周期（秒）：够短以覆盖 `kill -9`，又不至于让日志刷屏。 */
enum defaultWatchIntervalSec = 5;

/** Windows 上没有 `/dev/null`。 */
version (Windows) private enum nullSink = "NUL";
else private enum nullSink = "/dev/null";

/** 管理接口 URL。 */
private string jsonUrl(ListenEndpoint endpoint, string path) {
  return "http://" ~ probeHost(endpoint) ~ ":" ~ endpoint.port.to!string ~ path;
}

