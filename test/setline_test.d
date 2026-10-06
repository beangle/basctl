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

@("renderSetlineConfig writes listen, host and single/multiple ports") unittest {
  auto text = renderSetlineConfig([SetlineRoute("/api", [9001]), SetlineRoute("/m", [9001, 9002])],
      "127.0.0.1:8080", "demo.example.com");
  assert(text == "{\n  \"listen\": \"127.0.0.1:8080\",\n  \"routes\": {\n"
      ~ "    \"demo.example.com\": {\n      \"/api\": 9001,\n      \"/m\": [9001, 9002]\n    }\n  }\n}\n");
}

@("renderSetlineConfig escapes the host and writes an empty route table") unittest {
  auto text = renderSetlineConfig([], "127.0.0.1:8080", "a\"b");
  assert(text.canFind(`"a\"b": {}`));
  assert(text.canFind(`"listen": "127.0.0.1:8080"`));
}
