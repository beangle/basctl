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

/** Unit tests for bas.setline. */
module test.setline_test;

import bas.config;
import bas.serverinfo : ServerInfo, WebappInfo;
import bas.setline;

import std.algorithm : canFind;
import std.file : readText;

@("setlineRoutes maps every webapp to its server's http port") unittest {
  auto routes = setlineRoutes(parseServerXml(readText("server.xml")));
  assert(routes.length == 4);
  assert(routes[0].path == "/api/platform" && routes[0].ports == [8081]);
  assert(routes[1].path == "/api/tools" && routes[1].ports == [8088]);
  assert(routes[2].path == "/cas" && routes[2].ports == [8081]);
  assert(routes[3].path == "/portal" && routes[3].ports == [8081]);
}

@("setlineRoutes merges one path across servers and skips undeployed webapps") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="app" engine="tomcat">
      <server name="s2" http="9002"/>
      <server name="s1" http="9001"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:b:1" run-at="app" path="/api"/>
    <webapp uri="gav://a:c:1" run-at="app" path="/api/"/>
    <webapp uri="gav://a:d:1" run-at="app" path="/"/>
    <webapp uri="gav://a:e:1" run-at="app"/>
    <webapp uri="gav://a:f:1" path="/nowhere"/>
  </webapps>
</bas>`);
  auto routes = setlineRoutes(conf);
  // "/api" 与 "/api/" 归一到同一路径；"/" 兼收显式 path="/" 与省略 path 的两个 webapp；
  // 未声明 run-at 的 webapp 不产生路由。端口升序去重。
  assert(routes.length == 2);
  assert(routes[0].path == "/" && routes[0].ports == [9001, 9002]);
  assert(routes[1].path == "/api" && routes[1].ports == [9001, 9002]);
}

@("setlinePlan routes a root webapp by its declared <url path> list") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="a" engine="tomcat">
      <server name="s1" http="9001"/>
    </farm>
    <farm name="b" engine="tomcat">
      <server name="s1" http="9002"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:one:1" run-at="a" path="/">
      <url path="/context1"/>
      <url path="/context2/"/>
    </webapp>
    <webapp uri="gav://a:two:1" run-at="b" path="/">
      <url path="/context3"/>
      <url path="/context4"/>
    </webapp>
  </webapps>
</bas>`);
  auto plan = setlinePlan(conf);
  // 两个 webapp 的上下文都是 /，靠各自声明的 URL 前缀区分；声明了 <url> 就不再认领 context path。
  assert(plan.conflicts.length == 0);
  assert(plan.routes.length == 4);
  assert(plan.routes[0].path == "/context1" && plan.routes[0].ports == [9001]);
  assert(plan.routes[1].path == "/context2" && plan.routes[1].ports == [9001]);
  assert(plan.routes[2].path == "/context3" && plan.routes[2].ports == [9002]);
  assert(plan.routes[3].path == "/context4" && plan.routes[3].ports == [9002]);
}

@("setlinePlan reports a conflict when one path lands on different servers") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="a" engine="tomcat">
      <server name="s1" http="9001"/>
    </farm>
    <farm name="b" engine="tomcat">
      <server name="s1" http="9002"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:one:1" run-at="a" path="/"/>
    <webapp uri="gav://a:two:1" run-at="b" path="/"/>
  </webapps>
</bas>`);
  auto plan = setlinePlan(conf);
  assert(plan.conflicts.length == 1);
  assert(plan.conflicts[0].path == "/");
  assert(plan.conflicts[0].webapps == ["gav://a:one:1", "gav://a:two:1"]);
  // 冲突仍然给出合并后的路由，便于调用方提示后仍能写出可用的配置
  assert(plan.routes.length == 1 && plan.routes[0].ports == [9001, 9002]);
}

@("setlinePlan keeps two webapps on one path when they share every server") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="a" engine="tomcat">
      <server name="s1" http="9001"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:one:1" run-at="a" path="/">
      <url path="/context1"/>
    </webapp>
    <webapp uri="gav://a:two:1" run-at="a" path="/">
      <url path="/context1"/>
    </webapp>
  </webapps>
</bas>`);
  auto plan = setlinePlan(conf);
  // 端口集合一致时无法区分也无区别，合并即可，不报冲突
  assert(plan.conflicts.length == 0);
  assert(plan.routes.length == 1 && plan.routes[0].ports == [9001]);
}

@("setlineRoutes drops webapps whose server has no http port") unittest {
  auto conf = parseServerXml(`
<bas version="0.14.0">
  <engines>
    <engine name="tomcat" type="tomcat" version="11.0.26"/>
  </engines>
  <farms>
    <farm name="app" engine="tomcat">
      <server name="s1"/>
    </farm>
  </farms>
  <webapps>
    <webapp uri="gav://a:b:1" run-at="app" path="/api"/>
  </webapps>
</bas>`);
  assert(setlineRoutes(conf).length == 0);
}

@("renderSetlineConfig writes listen, the hostname namespace and single/multiple ports") unittest {
  auto text = renderSetlineConfig([SetlineRoute("/api", [9001]), SetlineRoute("/m", [9001, 9002])],
      "127.0.0.1:8080", "alice.localhost");
  assert(text == "{\n  \"listen\": \"127.0.0.1:8080\",\n  \"routes\": {\n"
      ~ "    \"alice.localhost\": {\n      \"/api\": 9001,\n      \"/m\": [9001, 9002]\n    }\n"
      ~ "  }\n}\n");
}

@("renderSetlineConfig writes an empty route table") unittest {
  auto text = renderSetlineConfig([], "127.0.0.1:8080", "*");
  assert(text.canFind(`"*": {}`));
  assert(text.canFind(`"listen": "127.0.0.1:8080"`));
}

@("runningPlan merges the ports of one webapp across instances") unittest {
  auto infos = [
    runningInfo("platform.server1", 9001,
        [WebappInfo("ROOT", "gav://a:b:1", "/", ["/context1", "/context2"])]),
    runningInfo("platform.server2", 9002,
        [WebappInfo("ROOT", "gav://a:b:1", "/", ["/context1", "/context2"])]),
  ];
  auto plan = runningPlan(infos);
  // 同一个 webapp（uri 相同）的两个实例：端口并集，不是冲突
  assert(plan.conflicts.length == 0);
  assert(plan.routes.length == 2);
  assert(plan.routes[0].path == "/context1" && plan.routes[0].ports == [9001, 9002]);
  assert(plan.routes[1].path == "/context2" && plan.routes[1].ports == [9001, 9002]);
}

@("runningPlan falls back to the context path and skips portless or webappless instances") unittest {
  auto infos = [
    runningInfo("a.s1", 9001, [WebappInfo("portal", "gav://a:p:1", "/portal", [])]),
    runningInfo("a.s2", 0, [WebappInfo("portal", "gav://a:p:1", "/portal", [])]),
    runningInfo("a.s3", 9003, []),
  ];
  auto plan = runningPlan(infos);
  assert(plan.routes.length == 1);
  assert(plan.routes[0].path == "/portal" && plan.routes[0].ports == [9001]);
}

@("runningPlan reports two different webapps claiming one path on different ports") unittest {
  auto infos = [
    runningInfo("a.s1", 9001, [WebappInfo("x", "gav://a:x:1", "/", ["/api"])]),
    runningInfo("a.s2", 9002, [WebappInfo("y", "gav://a:y:1", "/", ["/api"])]),
  ];
  auto plan = runningPlan(infos);
  assert(plan.routes.length == 1);
  assert(plan.routes[0].ports == [9001, 9002]);
  assert(plan.conflicts.length == 1 && plan.conflicts[0].path == "/api");
  assert(conflictLines(plan.conflicts)[0].canFind("gav://a:x:1, gav://a:y:1"));
}

/** 一份实例运行信息，只填对账关心的字段。 */
private ServerInfo runningInfo(string id, int port, WebappInfo[] webapps) {
  ServerInfo info;
  info.id = id;
  info.httpPort = cast(ushort) port;
  info.pid = 1;
  info.webapps = webapps;
  return info;
}
