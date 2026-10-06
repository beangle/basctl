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
 * 每个 webapp 的 context path 与它部署到的 server 的 http 端口聚成 routes：同一路径落在多个
 * server 上时合并成端口列表，由 setline 在健康实例间选择（自带 TCP 健康检查）。
 *
 * 本模块只做纯计算与拼文本，不做 IO，也不启动 setline。后端固定为回环地址（setline 的约定），
 * 所以生成的路由只对跑在本机的 server 有意义。
 */
module bas.setline;

import bas.config;

import std.algorithm : canFind, sort;
import std.array : appender, join;
import std.conv : to;

/** setline 的缺省入口地址，与 setline 自身缺省一致：本地回环，不占特权端口。 */
enum defaultSetlineListen = "127.0.0.1:8080";

/** 路由缺省归属的 Host；`*` 是 setline 的兜底命名空间，等价于按路径匹配任意 Host。 */
enum defaultSetlineHost = "*";

/** 一条路由：context path 前缀 + 后端 http 端口（升序、去重）。 */
struct SetlineRoute {
  string path;
  int[] ports;
}

/**
 * 从拓扑算路由：遍历每个 webapp 的 run-at 目标，取其 server 的 http 端口。
 *
 * 没有 run-at、或 http 端口为 0（未分配）的 webapp 跳过；同一 path 落在多个 server 上时端口
 * 合并，交给 setline 轮询。结果按 path 排序，保证多次运行输出一致。
 */
SetlineRoute[] setlineRoutes(Container conf) {
  string[] paths;
  int[][string] portsByPath;
  foreach (app; conf.webapps) {
    auto path = app.contextPath.length ? app.contextPath : "/";
    foreach (server; app.runAt) {
      if (server.http <= 0)
        continue;
      if (!(path in portsByPath)) {
        portsByPath[path] = [];
        paths ~= path;
      }
      if (!portsByPath[path].canFind(server.http))
        portsByPath[path] ~= server.http;
    }
  }
  paths.sort();

  SetlineRoute[] routes;
  foreach (path; paths) {
    auto ports = portsByPath[path];
    ports.sort();
    routes ~= SetlineRoute(path, ports);
  }
  return routes;
}

/**
 * 渲染 setline 配置：`listen` 为入口地址，`host` 为路由归属的 Host。单个端口输出数字，多个
 * 端口输出数组（setline 两者都接受）。
 */
string renderSetlineConfig(const(SetlineRoute)[] routes, string listen, string host = defaultSetlineHost) {
  auto sb = appender!string;
  sb.put("{\n");
  sb.put("  \"listen\": \"" ~ jsonEscape(listen) ~ "\",\n");
  sb.put("  \"routes\": {\n");
  sb.put("    \"" ~ jsonEscape(host) ~ "\": {");
  if (routes.length) {
    sb.put("\n");
    foreach (i, route; routes) {
      sb.put("      \"" ~ jsonEscape(route.path) ~ "\": " ~ portsJson(route.ports));
      sb.put(i + 1 < routes.length ? ",\n" : "\n");
    }
    sb.put("    }\n");
  } else
    sb.put("}\n");
  sb.put("  }\n");
  sb.put("}\n");
  return sb.data;
}

/** 端口渲染：单端口是数字，多端口是数组。 */
private string portsJson(const(int)[] ports) {
  if (ports.length == 1)
    return ports[0].to!string;
  string[] items;
  foreach (port; ports)
    items ~= port.to!string;
  return "[" ~ items.join(", ") ~ "]";
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
