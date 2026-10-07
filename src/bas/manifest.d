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
 * `basctl manifest`：把 `server.xml` 的**声明态拓扑**导出成一份机器可读的 manifest（JSON）。
 *
 * 与 `basctl setline` 的分工：setline 的配置面向"本机回环后端 + 单一入口"，只讲 `path -> port`；
 * manifest 面向 setline-roadmap 的 R6（生产侧产出拓扑 → registry → 边缘机 agent 拉取渲染
 * haproxy / nginx），除了路由还带上"让边缘机不必再看 `server.xml` 就能渲染"的信息：
 *
 *  - `setline`：这份 `BAS_HOME` 占哪个命名空间（`hostname`）、往里拨哪扇门（`endpoint`，未声明
 *    就没有）、以及 basctl 是否维护它的路由（`enabled`，即配置里有没有 `<setline>`）；
 *  - `servers[]`：每个实例的限定名、引擎（`type` + 版本）、`http` 端口、连接超时、
 *    `websocket` / `jsp` 开关，以及它部署了哪些 webapp；
 *  - `webapps[]`：每个 webapp 的 `contextPath`、**声明的**对外路径 `urls`、**生效的**路径
 *    `paths`（声明优先、否则退回 contextPath，即 `Webapp.routePaths`）与 `uri`。两者都给出来，
 *    消费方就不必再实现一遍回退规则；
 *  - `routes`：与 setline 配置同形状的 `hostname -> path -> port|[ports]`（{@link renderRouteMap}），
 *    边缘机想直接把这份拓扑喂给 setline 时取这一段即可。
 *
 * 它是**声明态**：端口取 `server.xml` 里写的值，`http="0"`（动态端口）原样输出 0——动态端口只有
 * 运行中的实例（`server.info`）才知道。"现状"那一面由 R0-R3 的运行期路由承担，不走这里。
 *
 * 后端地址仍假设在回环（与 setline 一致）：manifest 描述的是"这些 server 跑在本机"，跨机部署由
 * 边缘机渲染时替换后端地址——这正是它与 bashub 的 haproxy / nginx 模板对齐的位置。
 *
 * 本模块只做纯计算与拼文本：IO 在 {@link cmdManifest}，冲突判定沿用 {@link setlinePlan}。
 */
module bas.manifest;

import bas.config : Container, Server, Webapp, defaultSetlineHostname, parseServerXmlFile;
import bas.setline : SetlineConflict, conflictLines, jsonEscape, renderRouteMap, setlinePlan;
import bas.shellenv : resolveBasHome;

import std.algorithm : startsWith;
import std.array : Appender, appender;
import std.conv : to;
import std.file : exists, mkdirRecurse, write;
import std.path : absolutePath, buildPath, dirName;
import std.stdio : stderr, stdout, writeln;
import std.string : strip;

/** manifest 的 schema 版本；字段增删（不兼容）时 +1，消费方据此判断能不能读。 */
enum manifestVersion = 1;

/**
 * 渲染整份 manifest。
 *
 * `source` 是 `server.xml` 的来源（写进产物便于回溯是拿哪份配置生成的），`basctlVersion`
 * 只用于 `generator` 字段。冲突（同一路径被端口集合不同的多个 webapp 声明）不在这里报，
 * 由调用方先看 {@link setlinePlan} 的 `conflicts`——manifest 与 setline 配置必须对同一份拓扑
 * 得出同一个结论。
 */
string renderManifest(Container conf, string source, string basctlVersion) {
  auto plan = setlinePlan(conf);
  auto hostname = conf.setlineHostname.isNull ? defaultSetlineHostname
    : strip(conf.setlineHostname.get);

  auto sb = appender!string;
  sb.put("{\n");
  sb.put("  \"version\": " ~ manifestVersion.to!string ~ ",\n");
  sb.put("  \"generator\": \"" ~ jsonEscape("basctl " ~ basctlVersion) ~ "\",\n");
  sb.put("  \"source\": \"" ~ jsonEscape(source) ~ "\",\n");
  sb.put("  \"bas\": \"" ~ jsonEscape(conf.version_) ~ "\",\n");
  putSetline(sb, conf, hostname);
  putServers(sb, conf);
  sb.put("  \"routes\": {\n");
  sb.put("    \"" ~ jsonEscape(hostname) ~ "\": " ~ renderRouteMap(plan.routes, "    ") ~ "\n");
  sb.put("  }\n");
  sb.put("}\n");
  return sb.data;
}

/** `setline` 段：命名空间、入口（声明了才有）与是否启用。 */
private void putSetline(ref Appender!string sb, Container conf, string hostname) {
  sb.put("  \"setline\": {\n");
  sb.put("    \"enabled\": " ~ (conf.setlineHostname.isNull ? "false" : "true") ~ ",\n");
  auto endpoint = conf.setlineEndpointText();
  sb.put("    \"hostname\": \"" ~ jsonEscape(hostname) ~ "\""
      ~ (endpoint.length ? ",\n" : "\n"));
  if (endpoint.length)
    sb.put("    \"endpoint\": \"" ~ jsonEscape(endpoint) ~ "\"\n");
  sb.put("  },\n");
}

/** `servers` 段：每个实例的引擎、端口与部署的 webapp。 */
private void putServers(ref Appender!string sb, Container conf) {
  auto servers = allServers(conf);
  sb.put("  \"servers\": [");
  if (!servers.length) {
    sb.put("],\n");
    return;
  }
  sb.put("\n");
  foreach (i, server; servers) {
    putServer(sb, conf, server);
    sb.put(i + 1 < servers.length ? ",\n" : "\n");
  }
  sb.put("  ],\n");
}

/** 一个实例：限定名、farm、引擎（type + 版本）、端口与开关，以及它部署的 webapp。 */
private void putServer(ref Appender!string sb, Container conf, Server server) {
  auto engine = server.farm.engine;
  sb.put("    {\n");
  sb.put("      \"name\": \"" ~ jsonEscape(server.qualifiedName) ~ "\",\n");
  sb.put("      \"farm\": \"" ~ jsonEscape(server.farm.name) ~ "\",\n");
  sb.put("      \"engine\": \"" ~ jsonEscape(engine.typ ~ "-" ~ engine.version_) ~ "\",\n");
  sb.put("      \"type\": \"" ~ jsonEscape(engine.typ) ~ "\",\n");
  sb.put("      \"engineVersion\": \"" ~ jsonEscape(engine.version_) ~ "\",\n");
  sb.put("      \"http\": " ~ server.http.to!string ~ ",\n");
  sb.put("      \"connectionTimeout\": " ~ server.farm.http.connectionTimeout.to!string ~ ",\n");
  sb.put("      \"websocket\": " ~ (engine.websocketSupport ? "true" : "false") ~ ",\n");
  sb.put("      \"jsp\": " ~ (engine.jspSupport ? "true" : "false") ~ ",\n");
  sb.put("      \"webapps\": [");
  auto deployed = deployedWebapps(conf, server);
  if (deployed.length)
    sb.put("\n");
  foreach (i, app; deployed) {
    putWebapp(sb, app);
    sb.put(i + 1 < deployed.length ? ",\n" : "\n");
  }
  sb.put(deployed.length ? "      ]\n" : "]\n");
  sb.put("    }");
}

/** 一个 webapp：部署上下文、声明的对外路径、生效的对外路径与构件坐标。 */
private void putWebapp(ref Appender!string sb, Webapp app) {
  sb.put("        {\n");
  sb.put("          \"contextPath\": \"" ~ jsonEscape(app.contextPath.length ? app.contextPath : "/") ~ "\",\n");
  sb.put("          \"urls\": " ~ jsonArray(app.urls) ~ ",\n");
  sb.put("          \"paths\": " ~ jsonArray(app.routePaths) ~ ",\n");
  sb.put("          \"uri\": \"" ~ jsonEscape(app.uri) ~ "\"\n");
  sb.put("        }");
}

/** 渲染 `["a", "b"]`；空数组输出 `[]`。 */
private string jsonArray(const(string)[] items) {
  auto sb = appender!string;
  sb.put("[");
  foreach (i, item; items) {
    sb.put("\"" ~ jsonEscape(item) ~ "\"");
    if (i + 1 < items.length)
      sb.put(", ");
  }
  sb.put("]");
  return sb.data;
}

/** 配置里全部实例，按 farm、server 的声明顺序（farm 无 server 时不产生条目）。 */
private Server[] allServers(Container conf) {
  Server[] result;
  foreach (farm; conf.farms)
    result ~= farm.servers;
  return result;
}

/** 部署到该实例的 webapp，按 `webapps` 的声明顺序。 */
private Webapp[] deployedWebapps(Container conf, Server server) {
  Webapp[] result;
  foreach (app; conf.webapps)
    foreach (target; app.runAt)
      if (target is server) {
        result ~= app;
        break;
      }
  return result;
}

/**
 * `basctl manifest [server.xml] [--output=<file>]`
 *
 * 输出路径缺省是 `$BAS_HOME/conf/manifest.json`，`--output=-` 写到 stdout。与 `setline` 一样，
 * 生成前先做冲突预检：同一路径落在端口集合不同的多个 webapp 上时无从判定归属，报错而不是导出
 * 一份消费方没法用的拓扑。
 */
int cmdManifest(string[] args, string basctlVersion) {
  string confFile;
  string outFile;
  foreach (arg; args) {
    if (arg.startsWith("--output="))
      outFile = arg["--output=".length .. $];
    else if (!confFile.length)
      confFile = arg;
    else {
      manifestUsage();
      return 1;
    }
  }

  auto basHome = resolveBasHome();
  if (!confFile.length)
    confFile = buildPath(basHome, "conf", "server.xml");
  if (!exists(confFile)) {
    stderr.writeln("Cannot find config file " ~ confFile);
    return 1;
  }

  Container container;
  try
    container = parseServerXmlFile(confFile);
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  SetlineConflict[] conflicts;
  try
    conflicts = setlinePlan(container).conflicts;
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }
  if (conflicts.length) {
    foreach (line; conflictLines(conflicts))
      stderr.writeln(line);
    stderr.writeln("Give each webapp its own <url path=\"...\"/> so no two share a path.");
    return 1;
  }

  auto text = renderManifest(container, absolutePath(confFile), basctlVersion);
  if (outFile == "-") {
    stdout.write(text);
    stdout.flush();
    return 0;
  }

  if (!outFile.length)
    outFile = buildPath(basHome, "conf", "manifest.json");
  auto target = absolutePath(outFile);
  mkdirRecurse(dirName(target));
  try
    write(target, text);
  catch (Exception e) {
    auto reason = e.msg;
    if (reason.startsWith(target ~ ": "))
      reason = reason[target.length + 2 .. $];
    stderr.writeln("Cannot write " ~ target ~ ": " ~ reason);
    return 1;
  }
  writeln("write ", target);
  return 0;
}

/** `manifest` 的用法。 */
void manifestUsage() {
  stderr.writeln("Usage: basctl manifest [server.xml] [--output=<file>]");
  stderr.writeln("  Exports the declared topology as JSON for an edge agent to render");
  stderr.writeln("  haproxy / nginx from: setline namespace and entry, every server's engine");
  stderr.writeln("  and http port, each webapp's context path and external paths, plus the");
  stderr.writeln("  same path -> port routes as the setline config. Output defaults to");
  stderr.writeln("  conf/manifest.json (--output=- writes it to stdout).");
  stderr.writeln("  Ports are the declared ones (http=\"0\" stays 0: dynamic ports live in");
  stderr.writeln("  server.info, not here).");
}
