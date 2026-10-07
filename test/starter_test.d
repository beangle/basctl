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

/** Unit tests for bas.starter. */
module test.starter_test;

import bas.config;
import bas.starter;

import std.algorithm : canFind;

@("subappId derives ids from context paths") unittest {
  assert(subappId("", []) == "ROOT");
  assert(subappId("/", []) == "ROOT");
  assert(subappId("/portal", []) == "portal");
  assert(subappId("/api/tools", []) == "api-tools");
  assert(subappId("/a b", []) == "a-b");
  assert(subappId("/portal", ["portal"]) == "portal-2");
  assert(subappId("/portal", ["portal", "portal-2"]) == "portal-3");
}

@("standaloneWebappError restricts embed engines to one webapp") unittest {
  assert(standaloneWebappError("tomcat", "tomcat", 1) == "");
  assert(standaloneWebappError("undertow", "undertow", 1) == "");
  assert(standaloneWebappError("jetty", "jetty", 1) == "");

  auto err = standaloneWebappError("tomcat", "tomcat", 3);
  assert(err.canFind("single webapp"));
  assert(err.canFind("use type=\"tomcat-server\""));

  // 发行包多应用不受限制
  assert(standaloneWebappError("tomcat-server", "tomcat", 3) == "");
}

@("runtimeArgsFor adds bas defaults and farm options") unittest {
  auto cfg = parseServerXml(`<bas version="1"><engines><engine name="tomcat" type="tomcat-server"
      version="11.0.18"/></engines><farms><farm name="f" engine="tomcat" max-heap-size="512M">
      <server-options>-Dems.profile=local
      --add-opens=java.base/java.lang=ALL-UNNAMED</server-options>
      <server name="s1" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  auto server = cfg.farms[0].servers[0];
  auto args = runtimeArgsFor(server);
  assert(args.canFind("-Xmx512M"));
  assert(args.canFind("-Dbas.server=f.s1"));
  assert(args.canFind("-Dems.profile=local"));
  assert(args.canFind("--add-opens=java.base/java.lang=ALL-UNNAMED"));
  auto appArgs = appArgsFor(server);
  assert(appArgs.canFind("--port=8080"));
  assert(appArgs.canFind("--Dconnector.connectionTimeout=60000"));
  assert(appArgs.canFind("--Dconnector.enableLookups=false"));
  assert(appArgs.canFind("--Dconnector.disableUploadTimeout=true"));
  // 未显式给出的项不下发，交给容器默认
  assert(!appArgs.canFind("--Dconnector.acceptCount="));
  assert(!appArgs.canFind("--Dconnector.maxConnections="));
}

@("appArgsFor maps <http> to connector engine properties") unittest {
  auto cfg = parseServerXml(`<bas version="1"><engines><engine name="tomcat" type="tomcat"
      version="11.0.18"/></engines><farms><farm name="f" engine="tomcat">
      <http accept-count="200" max-connections="5000" connection-timeout="30000"
        enable-lookups="true" disable-upload-timeout="false"/>
      <server name="s1" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  auto args = appArgsFor(cfg.farms[0].servers[0]);
  assert(args.canFind("--Dconnector.acceptCount=200"));
  assert(args.canFind("--Dconnector.maxConnections=5000"));
  assert(args.canFind("--Dconnector.connectionTimeout=30000"));
  assert(args.canFind("--Dconnector.enableLookups=true"));
  assert(args.canFind("--Dconnector.disableUploadTimeout=false"));
}

@("appArgsFor passes --jsp only for tomcat-server") unittest {
  auto dist = parseServerXml(`<bas version="1"><engines><engine name="ts" type="tomcat-server"
      version="11.0.18" jsp-support="true"/></engines>
      <farms><farm name="f" engine="ts"><server name="s1" http="8080"/></farm></farms></bas>`);
  assert(appArgsFor(dist.farms[0].servers[0]).canFind("--jsp=true"));

  // 嵌入式引擎不支持 JSP：即使 server.xml 写了 jsp-support 也不下发 --jsp
  auto embed = parseServerXml(`<bas version="1"><engines><engine name="te" type="tomcat"
      version="11.0.18" jsp-support="true"/></engines>
      <farms><farm name="f" engine="te"><server name="s1" http="8080"/></farm></farms></bas>`);
  assert(!appArgsFor(embed.farms[0].servers[0]).canFind("--jsp"));
}

@("repoArgs passes release and snapshot repositories through to jstart") unittest {
  auto cfg = parseServerXml(`<bas version="0.13.16">
      <repository local="/m2" remote="http://r1,http://r2"/>
      <snapshot-repo remote="http://snap"/>
      <engines><engine name="tomcat" type="tomcat-server" version="11.0.18"/></engines>
      <hosts><host name="local" ip="127.0.0.1"/></hosts>
      <farms><farm name="f" engine="tomcat"><server name="s" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  assert(repoArgs(cfg) == ["--local=/m2", "--remote=http://r1,http://r2",
      "--snapshot-remote=http://snap"]);
}

@("repoArgs falls back to the snapshot local and omits empty repositories") unittest {
  auto cfg = parseServerXml(`<bas version="0.13.16">
      <snapshot-repo local="/m2snap"/>
      <engines><engine name="tomcat" type="tomcat-server" version="11.0.18"/></engines>
      <hosts><host name="local" ip="127.0.0.1"/></hosts>
      <farms><farm name="f" engine="tomcat"><server name="s" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  assert(repoArgs(cfg) == ["--local=/m2snap"]);
}

@("describeInstance collects engine, port and webapps with their urls") unittest {
  auto cfg = parseServerXml(`<bas version="1">
      <engines><engine name="ts" type="tomcat-server" version="11.0.26"/></engines>
      <hosts><host name="local" ip="127.0.0.1"/></hosts>
      <farms><farm name="platform" engine="ts">
        <server name="server1" http="8081"/></farm></farms>
      <webapps>
        <webapp uri="gav://org.beangle.ems:beangle-ems-portal:4.20.13" run-at="platform" path="/portal"/>
        <webapp uri="gav://org.beangle.otk:beangle-otk-ws:war:0.0.30" run-at="platform" path="/">
          <url path="/context1"/><url path="/context2"/>
        </webapp>
      </webapps></bas>`);

  auto info = describeInstance(cfg, cfg.farms[0].servers[0], "2026-10-07T10:12:33+08:00");
  assert(info.id == "platform.server1");
  assert(info.engine == "tomcat-server-11.0.26");
  assert(info.httpPort == 8081);
  assert(info.started == "2026-10-07T10:12:33+08:00");
  assert(info.pid == 0);
  assert(info.webapps.length == 2);
  // 段 id 与 spec 的 [subapp <id>] 同源：由 context path 推导
  assert(info.webapps[0].id == "portal");
  assert(info.webapps[0].context == "/portal");
  assert(info.webapps[0].urls.length == 0);
  assert(info.webapps[1].id == "ROOT");
  assert(info.webapps[1].context == "/");
  assert(info.webapps[1].urls == ["/context1", "/context2"]);
  // 与 spec 的 [subapp <id>] 对上号
  auto specs = subappSpecs(cfg.getWebapps(cfg.farms[0].servers[0]));
  assert(specs.length == 2);
  assert(specs[0].id == info.webapps[0].id);
  assert(specs[1].id == info.webapps[1].id);
}

@("describeInstance leaves the port open for <server http=0>") unittest {
  auto cfg = parseServerXml(`<bas version="1">
      <engines><engine name="ts" type="tomcat-server" version="11.0.26"/></engines>
      <hosts><host name="local" ip="127.0.0.1"/></hosts>
      <farms><farm name="f" engine="ts"><server name="s1" http="0"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  assert(describeInstance(cfg, cfg.farms[0].servers[0], "").httpPort == 0);
}

@("appArgsFor passes the instance port to the engine") unittest {
  auto cfg = parseServerXml(`<bas version="1">
      <engines><engine name="tc" type="tomcat" version="11.0.21"/></engines>
      <farms><farm name="f" engine="tc"><server name="s1" http="20000"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  // 动态端口在 reserveInstance 里回填 server.http 后走的就是这条路（见 starter.d 的注释）
  assert(appArgsFor(cfg.farms[0].servers[0]).canFind("--port=20000"));
  assert(parseServerXml(`<bas version="1">
      <engines><engine name="tc" type="tomcat" version="11.0.21"/></engines>
      <farms><farm name="f" engine="tc"><server name="s1" http="0"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`)
      .farms[0].servers[0].http == 0);
}
