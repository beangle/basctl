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

module test.config_test;

import bas.config;

import std.algorithm.searching : canFind;
import std.file : readText;
import std.format : format;

@("parse repo server.xml sample") unittest {
  auto cfg = parseServerXml(readText("server.xml"));
  assert(cfg.version_ == "0.13.9");
  assert(cfg.repository !is null);
  assert(cfg.snapshotRepo !is null);

  assert(cfg.engines.length == 1);
  assert(cfg.engines[0].name == "tomcat");
  assert(cfg.engines[0].typ == "tomcat");
  assert(cfg.engines[0].version_ == "11.0.18");
  assert(cfg.engines[0].jars.length == 1);
  assert(cfg.engines[0].jars[0].uri == "gav://org.postgresql:postgresql:42.7.9");
  assert(cfg.engines[0].jars[0].name() == "postgresql-42.7.9.jar");

  assert(cfg.hosts.length == 1);
  assert(cfg.hosts[0].name == "localhost" && cfg.hosts[0].ip == "127.0.0.1");

  assert(cfg.farms.length == 2);
  assert(cfg.farms[0].name == "tools");
  assert(cfg.farms[0].maxHeapSize == "300M");
  assert(cfg.farms[0].servers.length == 1);
  assert(cfg.farms[0].servers[0].http == 8088);
  assert(cfg.farms[0].servers[0].host.ip == "127.0.0.1");
  assert(cfg.farms[0].servers[0].maxHeapSize == "300M");

  assert(cfg.farms[1].name == "platform");
  assert(!cfg.farms[1].serverOptions.isNull);
  assert(cfg.farms[1].serverOptions.get.canFind("-Dems.profile=local"));
  assert(cfg.farms[1].servers[0].http == 8081);

  assert(cfg.webapps.length == 4);
  assert(cfg.webapps[0].contextPath == "/api/tools");
  assert(cfg.webapps[0].runAt.length == 1);
  assert(cfg.webapps[0].runAt[0].qualifiedName == "tools.server1");
  assert(cfg.webapps[1].contextPath == "/cas");
  assert(cfg.webapps[1].runAt[0].qualifiedName == "platform.server1");

  auto tools = cfg.farms[0].servers[0];
  assert(cfg.getWebapps(tools).length == 1);
  assert(cfg.getServer("platform.server1") is cfg.farms[1].servers[0]);
  assert(cfg.getMatchedServers("tools").length == 1);
  assert(cfg.ports() == [8081, 8088]);
  assert(!cfg.hasExternHost());
}

@("runAt resolves qualified server name") unittest {
  auto xml = format!(`
    <bas version="1">
      <engines><engine name="t" type="tomcat" version="9"/></engines>
      <farms>
        <farm name="a" engine="t"><server name="s1" http="8080"/></farm>
      </farms>
      <webapps>
        <webapp uri="gav://x:y:1" run-at="a.s1" path="/x"/>
      </webapps>
    </bas>`);
  auto cfg = parseServerXml(xml);
  assert(cfg.webapps[0].runAt.length == 1);
  assert(cfg.webapps[0].runAt[0].qualifiedName == "a.s1");
}

@("listener, context and resource refs") unittest {
  auto xml = `
    <bas version="9">
      <engines>
        <engine name="t" type="tomcat" version="11" jsp-support="true">
          <listener class-name="L1" foo="bar"/>
          <context>
            <loader class-name="MyLoader" loaderClass="MyClassLoader"/>
            <jar-scanner scanAllFiles="false"/>
          </context>
        </engine>
      </engines>
      <hosts><host name="h1" ip="10.0.0.1"/></hosts>
      <resources><resource name="ds1" url="jdbc:x" type="javax.sql.DataSource"/></resources>
      <farms><farm name="f" engine="t" max-heap-size="1G"><server name="s" http="80" host="h1"/></farm></farms>
      <webapps>
        <webapp uri="gav://a:b:1" run-at="f" path="/" doc-base="/tmp/a.war" resolve-support="false">
          <resource-ref ref="ds1"/>
        </webapp>
      </webapps>
    </bas>`;
  auto cfg = parseServerXml(xml);
  assert(cfg.engines[0].jspSupport);
  assert(cfg.engines[0].listeners.length == 1);
  assert(cfg.engines[0].listeners[0].properties["foo"] == "bar");
  assert(cfg.engines[0].context.loader.className == "MyLoader");
  assert(cfg.engines[0].context.jarScanner.properties["scanAllFiles"] == "false");
  assert(cfg.hasExternHost());
  assert(cfg.farms[0].servers[0].maxHeapSize == "1G");
  assert(cfg.farms[0].servers[0].host.ip == "10.0.0.1");

  auto app = cfg.webapps[0];
  assert(app.contextPath == "");
  assert(app.uri == cfg.webapps[0].uri);
  assert(app.resources.length == 1);
  assert(app.resources[0].name == "ds1");
  assert(app.resources[0].type() == "javax.sql.DataSource");
  assert(!app.resolveSupport);
  assert(app.docBase.length == 0);
  assert(app.libs.isNull);
  assert(app.properties.length == 0);
  assert(!app.getContainerSciFilter(cfg.engines[0]).isNull);
  assert(cfg.farmResourceNames(cfg.farms[0]) == ["ds1"]);
  assert(cfg.resourceNames() == ["ds1"]);
}

@("missing farm engine is rejected") unittest {
  import std.exception : assertThrown;

  auto xml = `<bas version="1"><engines/><farms><farm name="f" engine="nope"/></farms></bas>`;
  assertThrown!ServerXmlException(parseServerXml(xml));
}

@("applyEngineDefault fills tomcat defaults once") unittest {
  auto cfg = parseServerXml(`<bas version="0.13.9">
      <engines><engine name="tomcat" type="tomcat" version="11.0.5"/></engines>
      <farms><farm name="f" engine="tomcat"><server name="s" http="8080"/></farm></farms>
    </bas>`);
  auto engine = cfg.engines[0];
  applyEngineDefault(cfg, engine);
  assert(engine.listeners.length == 2);
  assert(engine.context !is null);
  assert(engine.context.loader.className == "org.beangle.sas.engine.tomcat.ExtendableWebappLoader");
  assert(engine.context.jarScanner.properties["scanClassPath"] == "false");
  // 引擎 jar + 容器日志桥接 juli
  assert(engine.jars.length == 2);
  assert(engine.jars[0].uri == "gav://org.beangle.sas:beangle-sas-engine:0.13.9");
  assert(engine.jars[1].uri == "gav://org.beangle.sas:beangle-sas-juli:0.13.9");
}
