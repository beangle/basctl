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

/** Unit tests for bas.manifest. */
module test.manifest_test;

import bas.config;
import bas.manifest;
import bas.setline : setlinePlan;

import std.algorithm : map;
import std.array : array;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.uuid : randomUUID;

@("renderManifest exports setline namespace, servers and routes from server.xml") unittest {
  auto conf = parseServerXml(readText("server.xml"));
  auto root = parseJSON(renderManifest(conf, "conf/server.xml", "9.9.9"));

  assert(root["version"].integer == manifestVersion);
  assert(root["generator"].str == "basctl 9.9.9");
  assert(root["bas"].str == "0.14.0");
  assert(root["setline"]["enabled"].type == JSONType.true_);
  assert(root["setline"]["hostname"].str == "localhost");
  assert(root["setline"]["endpoint"].str == "127.0.0.1:8080");

  // 声明顺序：tools.server1、platform.server1
  auto servers = root["servers"].array;
  assert(servers.length == 2);
  assert(servers[0]["name"].str == "tools.server1");
  assert(servers[0]["engine"].str == "tomcat-server-11.0.26");
  assert(servers[0]["type"].str == "tomcat-server");
  assert(servers[0]["engineVersion"].str == "11.0.26");
  assert(servers[0]["http"].integer == 8088);
  assert(servers[0]["connectionTimeout"].integer == 60000);
  assert(servers[1]["http"].integer == 8081);
  assert(servers[1]["webapps"].array.length == 3);

  // routes 与 setline 配置同形状，可直接取来当 setline 的 routes
  auto routes = root["routes"]["localhost"];
  assert(routes["/api/tools"].integer == 8088);
  assert(routes["/cas"].integer == 8081);
}

@("renderManifest keeps declared urls apart from the effective paths") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26" websocket-support="false"/>
  </engines>
  <farms>
    <farm name="app" engine="tomcat">
      <server name="s1" http="9001"/>
      <server name="s2" http="0"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:b:1" run-at="app" path="/">
      <url path="/context1"/>
      <url path="/context2"/>
    </webapp>
    <webapp uri="gav://a:c:1" run-at="app"/>
  </webapps>
</bas>`);
  auto root = parseJSON(renderManifest(conf, "server.xml", "0.0.1"));

  auto servers = root["servers"].array;
  // http="0" 是动态端口：声明态原样输出 0，实际端口在 server.info 里
  assert(servers[1]["http"].integer == 0);
  assert(servers[0]["websocket"].type == JSONType.false_);
  // 同一次声明的 webapp 出现在每个目标 server 下
  assert(servers[0]["webapps"].array.length == 2);

  auto declared = servers[0]["webapps"].array[0];
  assert(declared["contextPath"].str == "/");
  assert(declared["urls"].array.map!(x => x.str).array == ["/context1", "/context2"]);
  assert(declared["paths"].array.map!(x => x.str).array == ["/context1", "/context2"]);

  // 未声明 <url> 时 urls 为空、paths 退回 context path
  auto fallback = servers[0]["webapps"].array[1];
  assert(fallback["urls"].array.length == 0);
  assert(fallback["paths"].array.map!(x => x.str).array == ["/"]);

  assert(root["setline"]["enabled"].type == JSONType.false_);
  assert(root["setline"]["hostname"].str == "localhost");
  assert(("endpoint" in root["setline"].object) is null);
}

@("renderManifest escapes the source path and reports the engine type without a version") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="jetty" type="jetty" version="12.0.30"/>
  </engines>
  <farms>
    <farm name="app" engine="jetty">
      <server name="s1" http="9001"/>
    </farm>
  </farms>
</bas>`);
  auto root = parseJSON(renderManifest(conf, "/opt/bas/\"odd\"/server.xml", "0.0.1"));
  assert(root["source"].str == "/opt/bas/\"odd\"/server.xml");
  assert(root["servers"].array[0]["engine"].str == "jetty-12.0.30");
  // 没有 webapp 时 routes 是空对象而不是缺字段
  assert(root["routes"]["localhost"].object.length == 0);
}

@("one path claimed by different port sets is a conflict, not a manifest") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="app" engine="tomcat">
      <server name="s1" http="9001"/>
      <server name="s2" http="9002"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:b:1" run-at="app.s1" path="/api"/>
    <webapp uri="gav://a:c:1" run-at="app.s2" path="/api"/>
  </webapps>
</bas>`);
  auto plan = setlinePlan(conf);
  assert(plan.conflicts.length == 1);
  assert(plan.conflicts[0].path == "/api");
}

@("cmdManifest writes conf/manifest.json under BAS_HOME") unittest {
  auto root = buildPath(tempDir, "basctl-manifest-" ~ randomUUID().toString());
  scope (exit) {
    environment.remove("BAS_HOME");
    if (exists(root))
      rmdirRecurse(root);
  }
  mkdirRecurse(buildPath(root, "conf"));
  write(buildPath(root, "conf", "server.xml"), readText("server.xml"));
  environment["BAS_HOME"] = root;

  assert(cmdManifest([], "test") == 0);
  auto target = buildPath(root, "conf", "manifest.json");
  assert(exists(target));
  auto written = parseJSON(readText(target));
  assert(written["generator"].str == "basctl test");
  assert(written["routes"]["localhost"]["/cas"].integer == 8081);
}
