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
 * `basctl setline`：把 `server.xml` 的服务拓扑渲染成 setline 的 JSON 配置。
 *
 * setline 在本地监听一个入口地址，按 Host + 路径前缀把请求转发到 `127.0.0.1:<port>`。这里把
 * 每个 webapp 的对外 URL 前缀（`<url path>`，未声明时退回 context path）与它部署到的 server
 * 的 http 端口聚成 routes：同一路径落在多个 server 上时合并成端口列表，由 setline 在健康实例间
 * 选择（自带 TCP 健康检查）。
 *
 * 同一路径被端口集合不同的多个 webapp 声明时无法判定归属，记成冲突（`SetlineConflict`）交给
 * 调用方报错；端口集合相同时合并无害（同一 webapp 的多实例部署），不算冲突。
 *
 * 反向的一步（`GET /__setline/routes` 的响应 → 可比较的路由表，`status` 的 route 列用它报"对没
 * 对上账"）也在本模块：{@link parseRouteTable}、{@link routeDriftLines}。
 *
 * 本模块只做纯计算与拼文本，不做 IO，也不启动 setline。后端固定为回环地址（setline 的约定），
 * 所以生成的路由只对跑在本机的 server 有意义。路由写进哪个命名空间由 `server.xml` 的
 * `<setline hostname>` 给出（见 {@link renderSetlineConfig}）——一台机器上共享一个 setline 的
 * 多份 `BAS_HOME` 靠它各占一格，互不覆盖。
 *
 * 渲染进文件的 `listen` 是 setline 自己要绑的 socket，写法与缺省见 {@link bas.endpoint}；它和
 * `basctl` 往外拨的入口地址（`<setline endpoint>`）写法同构但不是同一个值——`listen` 可以是
 * `*:8080`，往外拨的只能是具体地址。
 */
module bas.setline;

import bas.config;
import bas.serverinfo : ServerInfo, WebappInfo;

import std.algorithm : canFind, sort;
import std.array : appender, join;
import std.conv : to;
import std.format : format;
import std.json : JSONType, parseJSON;
import std.string : strip;

/** 一条路由：context path 前缀 + 后端 http 端口（升序、去重）。 */
struct SetlineRoute {
  string path;
  int[] ports;
}

/** 同一 path 被端口集合不同的多个 webapp 声明，无法按路径判定归属。 */
struct SetlineConflict {
  string path;
  string[] webapps;
}

/** 路由计算结果：可渲染的路由与必须报错的冲突。 */
struct SetlinePlan {
  SetlineRoute[] routes;
  SetlineConflict[] conflicts;
}

/** 一条路径的认领记录：声明者与其端口集合。 */
private struct PathClaim {
  string owner;
  int[] ports;
}

/** 冲突的展示行（打印与测试共用；调用方决定是报错还是只警告）。 */
string[] conflictLines(const(SetlineConflict)[] conflicts) {
  string[] lines;
  foreach (c; conflicts)
    lines ~= "Route conflict on " ~ c.path ~ ": declared by " ~ c.webapps.join(", ");
  return lines;
}

/**
 * 从拓扑算路由：遍历每个 webapp 的 run-at 目标，取其 server 的 http 端口。
 *
 * 没有 run-at、或 http 端口为 0（未分配）的 webapp 跳过；同一 path 落在多个 server 上时端口
 * 合并，交给 setline 轮询。结果按 path 排序，保证多次运行输出一致。
 */
SetlinePlan setlinePlan(Container conf) {
  string[] paths;
  PathClaim[][string] claimsByPath;
  foreach (app; conf.webapps) {
    int[] ports;
    foreach (server; app.runAt) {
      if (server.http <= 0)
        continue;
      if (!ports.canFind(server.http))
        ports ~= server.http;
    }
    if (!ports.length)
      continue;
    ports.sort();

    foreach (path; app.routePaths()) {
      if (!(path in claimsByPath)) {
        claimsByPath[path] = [];
        paths ~= path;
      }
      claimsByPath[path] ~= PathClaim(app.uri, ports);
    }
  }
  paths.sort();
  return mergeClaims(paths, claimsByPath);
}

/**
 * 从**实例运行信息**（`servers/<name>/server.info`）算路由，也就是「现状」：只有 pid 存活、端口
 * 已定的实例参与，每个 webapp 按它的 `url`（未声明回退 context）认领端口。
 *
 * 与 {@link setlinePlan} 共用同一套合并/冲突规则，区别只在数据来源——一个来自 `server.xml`
 * （意图），一个来自运行信息（现状）。对账用后者：配置改了但实例没重启时，路由不该跟着变。
 */
SetlinePlan runningPlan(const(ServerInfo)[] infos) {
  string[] paths;
  PathClaim[][string] claimsByPath;
  foreach (info; infos) {
    if (info.httpPort <= 0)
      continue;
    foreach (app; info.webapps) {
      foreach (path; webappRoutes(app)) {
        if (!(path in claimsByPath)) {
          claimsByPath[path] = [];
          paths ~= path;
        }
        claimsByPath[path] ~= PathClaim(app.uri, [cast(int) info.httpPort]);
      }
    }
  }
  paths.sort();
  return mergeClaims(paths, claimsByPath);
}

/** 运行信息里一个 webapp 的对外路径：`url` 优先，未声明回退 context（ROOT 记作 `/`）。 */
private string[] webappRoutes(const WebappInfo app) {
  if (app.urls.length)
    return app.urls.dup;
  return [app.context.length ? app.context : "/"];
}

/**
 * 合并同一路径的多条认领：同一个 webapp（`uri` 相同）的多实例端口取并集，不同 webapp 之间
 * 端口集合不一致即冲突（无法按路径判定归属）；端口集合相同则合并无害。
 *
 * 按 `owner` 先合并是必须的：多实例部署时每个实例只报自己的端口，直接比 `ports` 会把
 * 「同一个 webapp 跑在两台机器/两个端口」误判成冲突。
 */
private SetlinePlan mergeClaims(string[] paths, PathClaim[][string] claimsByPath) {
  SetlinePlan plan;
  foreach (path; paths) {
    string[] owners;
    int[][] ownerPorts;
    foreach (claim; claimsByPath[path]) {
      auto index = ownerIndex(owners, claim.owner);
      if (index < 0) {
        owners ~= claim.owner;
        ownerPorts ~= claim.ports.dup;
        ownerPorts[$ - 1].sort();
        continue;
      }
      foreach (port; claim.ports) {
        if (!ownerPorts[index].canFind(port)) {
          ownerPorts[index] ~= port;
          ownerPorts[index].sort();
        }
      }
    }

    int[] ports;
    foreach (candidate; ownerPorts)
      foreach (port; candidate)
        if (!ports.canFind(port))
          ports ~= port;
    ports.sort();

    bool conflicted;
    foreach (candidate; ownerPorts[1 .. $])
      if (candidate != ownerPorts[0])
        conflicted = true;

    plan.routes ~= SetlineRoute(path, ports);
    if (conflicted)
      plan.conflicts ~= SetlineConflict(path, owners);
  }
  return plan;
}

/** `owners` 里 `owner` 的下标，找不到返回 -1。 */
private ptrdiff_t ownerIndex(const(string)[] owners, string owner) {
  foreach (i, candidate; owners)
    if (candidate == owner)
      return cast(ptrdiff_t) i;
  return -1;
}

/** 只要路由，忽略冲突（保留给只关心渲染的调用方与测试）。 */
SetlineRoute[] setlineRoutes(Container conf) {
  return setlinePlan(conf).routes;
}

/**
 * 渲染 setline 配置：`endpoint` 落进 setline 自己的 `listen` 字段（回环上两者是同一个值；容器里
 * 绑 `*:8080` 而拨 `127.0.0.1:8080`，渲染方按绑的那一面给），路由放在 `hostname` 命名空间下
 * （`server.xml` 的 `<setline hostname>`，缺省 `localhost`，`*` 表示匹配任意 Host）。单个端口
 * 输出数字，多个端口输出数组（setline 两者都接受）。
 */
string renderSetlineConfig(const(SetlineRoute)[] routes, string endpoint, string hostname) {
  auto sb = appender!string;
  sb.put("{\n");
  sb.put("  \"listen\": \"" ~ jsonEscape(endpoint) ~ "\",\n");
  sb.put("  \"routes\": {\n");
  sb.put("    \"" ~ jsonEscape(hostname) ~ "\": " ~ renderRouteMap(routes, "    ") ~ "\n");
  sb.put("  }\n");
  sb.put("}\n");
  return sb.data;
}

/**
 * 渲染 `path -> port|[ports]` 的映射对象，即 setline 路由表里一个 host 分组的内容。
 *
 * 运行期同步（`PUT /__setline/routes/all`）要的正是这段；`indent` 只影响换行后的缩进，
 * 便于嵌进完整配置文件。
 */
string renderRouteMap(const(SetlineRoute)[] routes, string indent = "") {
  auto sb = appender!string;
  sb.put("{");
  if (routes.length) {
    sb.put("\n");
    foreach (i, route; routes) {
      sb.put(indent ~ "  \"" ~ jsonEscape(route.path) ~ "\": " ~ portsJson(route.ports));
      sb.put(i + 1 < routes.length ? ",\n" : "\n");
    }
    sb.put(indent);
  }
  sb.put("}");
  return sb.data;
}

/**
 * 解析 setline `GET /__setline/routes` 的响应：`{"<host>": [{"prefix": "/x", "port": 8080}, ...]}`。
 *
 * 返回 `host -> (path -> 端口集合)`（端口升序去重）。形状不对就抛异常——意思是"读回来的东西
 * 不是路由表"，由调用方决定怎么报（`status` 只打一行，不因此让命令失败）。
 */
int[][string][string] parseRouteTable(string json) {
  auto root = parseJSON(json);
  if (root.type != JSONType.object)
    throw new Exception("setline routes: expected a JSON object");

  int[][string][string] table;
  foreach (host, groups; root.object) {
    if (groups.type != JSONType.array)
      throw new Exception("setline routes: \"" ~ host ~ "\" is not an array");
    int[][string] paths;
    foreach (entry; groups.array) {
      if (entry.type != JSONType.object || !("prefix" in entry.object))
        throw new Exception("setline routes: entry without prefix");
      auto path = entry.object["prefix"].str;
      int[] ports;
      if ("port" in entry.object)
        ports ~= cast(int) entry.object["port"].integer;
      if ("ports" in entry.object) {
        foreach (port; entry.object["ports"].array)
          ports ~= cast(int) port.integer;
      }
      ports.sort();
      // setline 的 host / prefix 都过了规范化（去重、去尾斜杠），这里仍按同一规则收一遍，
      // 免得比较时"/api"与"/api/"被当成两条。
      paths[normalizeRoutePath(path)] = dedupe(ports);
    }
    table[host] = paths;
  }
  return table;
}

/**
 * 把「本机该有的路由」（`runningPlan` 的现状）与「setline 上有的路由」对照成展示行——`status`
 * 的 route 列，也是"对没对上账"的答案，不必再手工 `curl` 一遍。
 *
 * 该有的路由来自运行中的实例：**缺**说明 `start` 之后没推上去（setline 刚起或推送只警告过），
 * **对不上**说明端口漂移后没对账，**多**说明实例已停但路由还留着（`--watch` 没跑或没走到
 * `stop`）。全对得上就是一行 `routes in sync (N)`。
 */
string[] routeDriftLines(const(SetlineRoute)[] want, int[][string] have) {
  string[] lines;
  foreach (route; want) {
    if (!(route.path in have))
      lines ~= format!"  %s  missing on setline (want %s)"(route.path, portsText(route.ports));
    else if (have[route.path] != route.ports)
      lines ~= format!"  %s  setline has %s, want %s"(
          route.path, portsText(have[route.path]), portsText(route.ports));
  }

  // 关联数组遍历顺序不定：多出来的路由排序后再输出，多次运行结果一致
  string[] stale;
  foreach (path, ports; have) {
    bool wanted;
    foreach (route; want)
      if (route.path == path)
        wanted = true;
    if (!wanted)
      stale ~= format!"  %s  not in this BAS_HOME (setline has %s); a `setline --sync` removes it"(
          path, portsText(ports));
  }
  stale.sort();
  lines ~= stale;

  if (!lines.length)
    lines ~= format!"  routes in sync (%s)"(want.length);
  return lines;
}

/** 路由路径的规范化：去尾斜杠（根路径保留 `/`），与 setline 的 `normalizeRoutePrefix` 同义。 */
private string normalizeRoutePath(string path) {
  auto text = strip(path);
  while (text.length > 1 && text[$ - 1] == '/')
    text = text[0 .. $ - 1];
  return text.length ? text : "/";
}

/** 端口升序去重（解析 setline 返回的 `port` / `ports` 时用）。 */
private int[] dedupe(int[] ports) {
  int[] result;
  foreach (port; ports)
    if (!result.canFind(port))
      result ~= port;
  result.sort();
  return result;
}

/** 端口集合的展示写法：`8081` / `[8081, 8088]` / `none`。 */
private string portsText(const(int)[] ports) {
  if (!ports.length)
    return "none";
  if (ports.length == 1)
    return ports[0].to!string;
  string[] items;
  foreach (port; ports)
    items ~= port.to!string;
  return "[" ~ items.join(", ") ~ "]";
}

/** 端口渲染：单端口是数字，多端口是数组。 */
private string portsJson(const(int)[] ports) {
  return ports.length == 1 ? ports[0].to!string : portsText(ports);
}

/** 最小 JSON 字符串转义（本命令只处理地址、Host 与 URL 路径）。 */
private string jsonEscape(string text) {
  auto sb = appender!string;
  foreach (ch; text) {
    switch (ch) {
    case '"': sb.put(`\"`); break;
    case '\\': sb.put(`\\`); break;
    case '\n': sb.put(`\n`); break;
    case '\r': sb.put(`\r`); break;
    case '\t': sb.put(`\t`); break;
    default: sb.put(ch); break;
    }
  }
  return sb.data;
}
