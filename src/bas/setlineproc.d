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
 * setline 的进程与运行期路由同步：探测入口、就地启动、推送路由、停止自己起的实例。
 *
 * 入口由 `server.xml` 的 `<setline listen>` 声明（出现即启用）。`start`/`stop` 不直接管 setline
 * 进程——外置的（systemd、手工、别的 BAS_HOME）自动复用；只有入口空闲时才由这里就地拉起，并把
 * pid 记进 `$BAS_HOME/run/setline.pid`。`--stop` 也只停这一种，不碰别人起的实例。
 *
 * 本模块只走 setline 的**写**接口：它只认本机、不需要 token（路由表将来会开放给同网段的服务
 * 进程读取，那条**读**路径才有 token，basctl 用不上）。探测也借用写接口——写进去成功，就说明
 * 入口上坐的确实是我们能驱动的 setline。
 */
module bas.setlineproc;

import bas.net : canBindPort;
import bas.serverinfo : liveInstances;
import bas.serverstatus : processRunning, signalProcess;
import bas.setline : SetlineRoute, renderRouteMap, renderSetlineConfig, runningPlan;
import bas.spec : shellQuote;

import core.thread : Thread;
import core.time : msecs;

import std.array : join;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, write;
import std.format : format;
import std.json : JSONType, parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, environment, execute;
import std.stdio : stderr, stdout, writeln;
import std.string : lastIndexOf, strip;
import std.typecons : Nullable, nullable;

/** 入口地址：`*` / 空 host 表示监听所有地址（探测时走回环）。 */
struct ListenEndpoint {
  string host;
  ushort port;

  /** 展示用写法：`*:8080` 或 `127.0.0.1:8080`。 */
  string toString() const {
    return (host.length ? host : "*") ~ ":" ~ port.to!string;
  }
}

/** 覆盖 setline 可执行文件位置的环境变量名（与 `beangle_jstart` 同约定）。 */
enum setlineEnvVar = "beangle_setline";

/** setline 可执行文件；缺省 `setline`，可用 {@link setlineEnvVar} 指定其它路径。 */
string setlineCommand() {
  auto cmd = environment.get(setlineEnvVar, "");
  return strip(cmd).length ? strip(cmd) : "setline";
}

/**
 * 解析 setline 的 listen 写法：`8080` / `*:8080` / `127.0.0.1:8080`。非法写法抛异常。
 *
 * 裸端口与 setline 同义，绑回环；`*` 落成空 host，表示监听所有地址。
 */
ListenEndpoint parseListenEndpoint(string value) {
  auto text = strip(value);
  auto colon = text.lastIndexOf(":");
  if (colon < 0) {
    return ListenEndpoint("127.0.0.1", parseListenPort(text));
  }
  auto host = text[0 .. colon];
  return ListenEndpoint(host == "*" ? "" : host, parseListenPort(text[colon + 1 .. $]));
}

/** 探测/连接用的实际地址：监听所有地址时只能用回环探自己。 */
string probeHost(ListenEndpoint endpoint) {
  auto host = strip(endpoint.host);
  if (host.length == 0 || host == "0.0.0.0" || host == "::")
    return "127.0.0.1";
  return host;
}

/**
 * 入口是否空闲：能独立 `bind` 一次就说明没有进程在监听（随即释放，不占端口）。
 *
 * `*` / 空 host 监听所有地址，绑定同一地址才探得准，语义见 {@link bas.net.canBindPort}。
 */
bool portFree(ListenEndpoint endpoint) @trusted {
  return canBindPort(endpoint.host, endpoint.port);
}

/** 路由推送结果：写成功 / 有应答被拒 / 连不上。 */
enum RouteSync {
  synced,
  rejected,
  unreachable
}

/**
 * 确保入口可用并把整组路由推过去：空闲就地启动，已在跑则复用（systemd、手工或别的 BAS_HOME
 * 起的），被别的进程占用则报错退出。返回 0 表示路由已经推到位。
 */
int syncSetline(string basHome, ListenEndpoint endpoint, string routeMapJson, bool quiet = false) {
  if (!portFree(endpoint)) {
    // 有人在监听：写接口只认本机、不要 token，能写进去就说明是我的 setline
    auto result = syncRoutes(endpoint, routeMapJson);
    if (result == RouteSync.synced) {
      if (!quiet)
        writeln("setline already listening on " ~ endpoint.toString() ~ ", reusing it.");
      return 0;
    }
    stderr.writeln(result == RouteSync.unreachable
        ? "Port " ~ endpoint.toString() ~ " is used by another process; "
          ~ "change <setline listen> or stop it first."
        : "Port " ~ endpoint.toString() ~ " answers HTTP but rejected the route update; "
          ~ "it is probably not the setline we expect. Change <setline listen> or stop it first.");
    return 1;
  }

  if (launchSetline(basHome, endpoint) != 0)
    return 1;
  if (syncRoutes(endpoint, routeMapJson) != RouteSync.synced) {
    stderr.writeln("setline did not accept the routes; see " ~ buildPath(basHome, "logs", "setline.out"));
    return 1;
  }
  return 0;
}

/**
 * 入口空闲时就地启动 setline（`nohup setline -f conf/setline.json`），pid 记进 pid 文件。
 *
 * `nohup ... & echo $!` 拿到的是 setline 自己的 pid（nohup 直接 exec，不套一层 shell），因此
 * `--stop` 与存活判断用的是同一个 pid。启动后等一小会儿再确认存活：配置写坏、端口抢不到这类
 * 失败会立刻退出，此时不写 pid 文件，避免留下指向死进程的记录。
 */
int launchSetline(string basHome, ListenEndpoint endpoint) {
  auto confFile = buildPath(basHome, "conf", "setline.json");
  if (!exists(confFile)) {
    stderr.writeln("Missing " ~ confFile ~ "; run `basctl setline` to render it first.");
    return 1;
  }

  auto log = buildPath(basHome, "logs", "setline.out");
  mkdirRecurse(dirName(log));
  auto cmd = "nohup " ~ shellQuote(setlineCommand()) ~ " -f " ~ shellQuote(confFile)
    ~ " >> " ~ shellQuote(log) ~ " 2>&1 < /dev/null & echo $!";
  auto res = execute(["/bin/sh", "-c", cmd]);
  if (res.status != 0) {
    stderr.writeln("Cannot launch " ~ setlineCommand() ~ ", install setline or set "
        ~ setlineEnvVar ~ " to its path.");
    return 1;
  }

  auto pid = parsePid(strip(res.output));
  if (pid <= 0) {
    stderr.writeln("Cannot determine the setline pid; see " ~ log);
    return 1;
  }
  Thread.sleep(msecs(probeDelayMs));
  if (!processRunning(pid)) {
    stderr.writeln("setline exited during startup, see " ~ log);
    return 1;
  }
  auto pidPath = pidFile(basHome);
  mkdirRecurse(dirName(pidPath));
  write(pidPath, pid.to!string ~ "\n");
  writeln(format!"setline started (pid=%s, listen=%s, log=%s)"(pid, endpoint.toString(), log));
  return 0;
}

/**
 * 把整组路由推给 setline：`PUT /__setline/routes/all?host=*`——幂等，只替换兜底命名空间，
 * 别的 host 分组不受影响。
 */
RouteSync syncRoutes(ListenEndpoint endpoint, string routeMapJson) {
  auto body = "{\"routes\":" ~ routeMapJson ~ "}";
  auto res = execute(["curl", "--silent", "--show-error", "--max-time", "5",
      "-o", nullSink, "-w", "%{http_code}",
      "-X", "PUT", "-H", "Content-Type: application/json", "--data-binary", body,
      jsonUrl(endpoint, "/__setline/routes/all?host=*")], null, Config.none);
  if (res.status != 0)
    return RouteSync.unreachable;
  return strip(res.output) == "200" ? RouteSync.synced : RouteSync.rejected;
}

/**
 * 停止 basctl 就地启动的 setline（`$BAS_HOME/run/setline.pid`）。
 *
 * setline 收到 SIGTERM 会自己收尾（停止监听、写完配置），所以默认只发 SIGTERM 并轮询等待；超过
 * `waitMillis` 仍不退时，只有 `force` 才发 SIGKILL——没有 `--force` 就报错退出，把「要不要强杀」
 * 留给使用者。pid 文件不存在说明不是我们起的（systemd、别的 BAS_HOME），一律不动；pid 已死则
 * 直接清掉陈旧文件，重复 `--stop` 不会越做越乱。
 */
int stopSetline(string basHome, bool force, int waitMillis = 10_000) {
  auto path = pidFile(basHome);
  if (!exists(path)) {
    stderr.writeln("setline is not running: no " ~ path ~ " (only instances started by basctl are stopped).");
    return 1;
  }

  auto pid = parsePid(readText(path));
  if (pid <= 0 || !processRunning(pid)) {
    remove(path);
    writeln("setline is not running; removed stale " ~ path);
    return 0;
  }

  if (!signalProcess(pid, false)) {
    stderr.writeln("Cannot signal setline (pid=" ~ pid.to!string ~ ").");
    return 1;
  }
  auto waited = 0;
  while (processRunning(pid) && waited < waitMillis) {
    Thread.sleep(msecs(100));
    waited += 100;
  }
  if (processRunning(pid)) {
    if (!force) {
      stderr.writeln("setline (pid=" ~ pid.to!string ~ ") did not exit in "
          ~ (waitMillis / 1000).to!string ~ "s; rerun with --force to SIGKILL it.");
      return 1;
    }
    signalProcess(pid, true);
    Thread.sleep(msecs(500));
    if (processRunning(pid)) {
      stderr.writeln("setline (pid=" ~ pid.to!string ~ ") is still alive after SIGKILL.");
      return 1;
    }
  }

  remove(path);
  writeln("setline stopped (pid=" ~ pid.to!string ~ ").");
  return 0;
}

/**
 * pid 文件位置：`$BAS_HOME/run/setline.pid`。
 *
 * 机器级守护进程（就地启动的 setline，将来的对账进程）的 pid 都放 `run/`，与按实例分目录的
 * `servers/<name>/` 分开：前者属于整个 BAS_HOME，后者属于某个 farm.server。
 */
string pidFile(string basHome) {
  return buildPath(basHome, "run", "setline.pid");
}

/**
 * 就地启动的 setline 的 pid（`$BAS_HOME/run/setline.pid`）；文件不存在、内容不可解析或进程已经
 * 不在时为空（陈旧文件不在这里清理，`--stop` 才负责）。
 */
Nullable!int runningSetlinePid(string basHome) {
  auto path = pidFile(basHome);
  if (!exists(path))
    return Nullable!int.init;
  int pid;
  try
    pid = parsePid(readText(path));
  catch (Exception)
    return Nullable!int.init;
  if (pid <= 0 || !processRunning(pid))
    return Nullable!int.init;
  return nullable(pid);
}

/**
 * 把整组路由推到 setline：`--sync` 与 `start` / `stop` / `--watch` 共用的一条路。
 *
 * 缺 `conf/setline.json` 时写一份骨架（`listen` + 空 `routes`）——就地启动要用它；已有的一律
 * 不改（那是 setline 进程的配置，里面有 `adminToken` 这类 basctl 不该碰的东西）。随后确保入口
 * 可用（在跑就复用，空闲就地启动）再推路由，路由由 setline 自己写回文件，重启不丢。
 */
int syncRoutesToSetline(string basHome, const(SetlineRoute)[] routes, string listen, bool quiet = false) {
  ListenEndpoint endpoint;
  try
    endpoint = parseListenEndpoint(listen);
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  auto confFile = buildPath(basHome, "conf", "setline.json");
  if (!exists(confFile)) {
    mkdirRecurse(dirName(confFile));
    try
      write(confFile, renderSetlineConfig(null, listen));
    catch (Exception e) {
      stderr.writeln("Cannot write " ~ confFile ~ ": " ~ e.msg);
      return 1;
    }
  } else {
    auto fileListen = setlineFileListen(confFile);
    bool differs;
    try
      differs = fileListen.length > 0 && parseListenEndpoint(fileListen) != endpoint;
    catch (Exception)
      differs = false;
    if (differs && !quiet)
      stderr.writeln("Note: " ~ confFile ~ " says listen=" ~ fileListen ~ " but this command uses "
          ~ listen ~ "; the running setline follows the file. The routes below go to " ~ listen ~ ".");
  }

  if (syncSetline(basHome, endpoint, renderRouteMap(routes), quiet) != 0)
    return 1;
  writeln(format!"%s routes synced to http://%s"(routes.length, endpoint.toString()));
  return 0;
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
int watchRoutes(string basHome, string listen, int intervalSec) {
  ListenEndpoint endpoint;
  try
    endpoint = parseListenEndpoint(listen);
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  writeln(format!"watching %s for route changes (interval=%ss, listen=%s; ctrl-c to stop)"(
      buildPath(basHome, "servers"), intervalSec, endpoint.toString()));

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
        if (syncRoutesToSetline(basHome, plan.routes, listen, true) == 0)
          pushed = routeMap;
      }
    }
    // 守护进程的 stdout 常常重定向到文件（systemd / nohup），默认全缓冲会把日志攥在手里，
    // 每轮显式刷一次，日志才跟得上。
    stdout.flush();
    Thread.sleep(msecs(intervalSec * 1000));
  }
}

/** 读 `conf/setline.json` 里 `listen` 的原始写法；文件或字段不可用时返回空串。 */
string setlineFileListen(string path) {
  try {
    auto root = parseJSON(readText(path));
    if (!("listen" in root.object))
      return "";
    auto listen = root["listen"];
    if (listen.type == JSONType.string)
      return strip(listen.str);
    if (listen.type == JSONType.integer)
      return listen.integer.to!string;
  }
  catch (Exception) {
  }
  return "";
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

/** 启动后等待进程稳定下来的时间。 */
private enum probeDelayMs = 1000;

/** `--watch` 的缺省轮询周期（秒）：够短以覆盖 `kill -9`，又不至于让日志刷屏。 */
enum defaultWatchIntervalSec = 5;

/** Windows 上没有 `/dev/null`。 */
version (Windows) private enum nullSink = "NUL";
else private enum nullSink = "/dev/null";

/** 管理接口 URL。 */
private string jsonUrl(ListenEndpoint endpoint, string path) {
  return "http://" ~ probeHost(endpoint) ~ ":" ~ endpoint.port.to!string ~ path;
}

/** 解析端口号，越界即抛异常。 */
private ushort parseListenPort(string text) {
  int port;
  try
    port = strip(text).to!int;
  catch (Exception)
    throw new Exception("Invalid listen port: " ~ text);
  if (port <= 0 || port > 65535)
    throw new Exception("Invalid listen port: " ~ text);
  return cast(ushort) port;
}

/** 从命令输出里取 pid，解析失败返回 0。 */
private int parsePid(string text) {
  try
    return strip(text).to!int;
  catch (Exception)
    return 0;
}
