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
  assert(cfg.version_ == "0.14.0");
  assert(cfg.repository !is null);
  assert(cfg.snapshotRepo !is null);

  assert(cfg.engines.length == 1);
  assert(cfg.engines[0].name == "tomcat");
  assert(cfg.engines[0].typ == "tomcat-server");
  assert(cfg.engines[0].version_ == "11.0.26");
  assert(cfg.engines[0].jars.length == 1);
  assert(cfg.engines[0].jars[0].uri == "gav://org.postgresql:postgresql:42.7.9");
  assert(cfg.engines[0].jars[0].name() == "postgresql-42.7.9.jar");

  assert(cfg.hosts.length == 1);
  assert(cfg.hosts[0].name == "localhost" && cfg.hosts[0].ip == "127.0.0.1");

  assert(!cfg.setlineHostname.isNull);
  assert(cfg.setlineHostname.get == "localhost");

  assert(cfg.farms.length == 2);
  assert(cfg.farms[0].name == "tools");
  assert(cfg.farms[0].maxHeapSize == "300M");
  assert(cfg.farms[0].servers.length == 1);
  assert(cfg.farms[0].servers[0].http == 8088);
  assert(cfg.farms[0].servers[0].host.ip == "127.0.0.1");
  assert(cfg.farms[0].servers[0].maxHeapSize == "300M");
  // <http> 未声明时的缺省：connection-timeout 60s，accept-count/max-connections 不下发
  assert(cfg.farms[0].http.connectionTimeout == 60000);
  assert(cfg.farms[0].http.acceptCount.isNull);
  assert(cfg.farms[0].http.maxConnections.isNull);

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
      <engines><engine name="t" type="tomcat-server" version="9"/></engines>
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
        <engine name="t" type="tomcat-server" version="11" jsp-support="true">
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
        <webapp uri="gav://a:b:1" run-at="f" path="/" doc-base="/tmp/a.war" resolve-support="false"/>
      </webapps>
    </bas>`;
  auto cfg = parseServerXml(xml);
  assert(cfg.engines[0].jspSupport);
  // 未写 websocket-support 时缺省 true，保留 engines.ini 的完整默认集
  assert(cfg.engines[0].websocketSupport);
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
  assert(!app.resolveSupport);
  assert(app.docBase.length == 0);
  assert(app.libs.isNull);
  assert(app.properties.length == 0);
  assert(!app.getContainerSciFilter(cfg.engines[0]).isNull);
  assert(cfg.resourceNames() == ["ds1"]);
}

@("missing farm engine is rejected") unittest {
  import std.exception : assertThrown;

  auto xml = `<bas version="1"><engines/><farms><farm name="f" engine="nope"/></farms></bas>`;
  assertThrown!ServerXmlException(parseServerXml(xml));
}

@("parse the optional setline entry: hostname defaults to localhost, \"*\" is allowed") unittest {
  auto cfg = parseServerXml(`<bas version="1">
    <setline hostname="Alice.LOCALHOST" endpoint="127.0.0.1:8080"/>
    <engines><engine name="t" type="tomcat" version="11"/></engines>
    <farms><farm name="f" engine="t"><server name="s1" http="8080"/></farm></farms>
  </bas>`);
  assert(!cfg.setlineHostname.isNull);
  assert(cfg.setlineHostname.get == "alice.localhost", cfg.setlineHostname.get);

  // 不写 hostname：启用，命名空间缺省 localhost（只用 Host: localhost 访问得到）
  auto bare = parseServerXml(
      `<bas version="1"><setline endpoint="127.0.0.1:8080"/><engines/></bas>`);
  assert(bare.setlineHostname.get == "localhost");

  // 显式 * ：匹配任意 Host（用 IP / 任意域名访问也走同一组路由）
  auto any = parseServerXml(
      `<bas version="1"><setline hostname="*" endpoint="127.0.0.1:8080"/><engines/></bas>`);
  assert(any.setlineHostname.get == "*");

  auto off = parseServerXml(`<bas version="1"><engines/></bas>`);
  assert(off.setlineHostname.isNull);

  // endpoint：本 BAS_HOME 往外拨的入口地址，写法与 setline 的 listen 同构；
  // 没有 <setline> 时是空串（不启用就没有地址）
  assert(off.setlineEndpointText() == "");
  assert(bare.setlineEndpointText() == "127.0.0.1:8080");
  auto pointed = parseServerXml(
      `<bas version="1"><setline hostname="localhost" endpoint="*:9100"/><engines/></bas>`);
  assert(pointed.setlineEndpointText() == "*:9100");
  assert(parseServerXml(`<bas version="1"><setline endpoint="9100"/><engines/></bas>`)
      .setlineEndpointText() == "9100");
}

@("setline endpoint is required by the element and rejects anything that is not an address") unittest {
  import std.exception : assertThrown;

  // 有 <setline> 就必须给地址（hostname 可以省）
  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline hostname="localhost"/><engines/></bas>`));
  assertThrown!ServerXmlException(parseServerXml(`<bas version="1"><setline/><engines/></bas>`));
  // 没有 <setline> 就什么都不要求
  assert(parseServerXml(`<bas version="1"><engines/></bas>`).setlineEndpointText() == "");

  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline endpoint="nope"/><engines/></bas>`));
  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline endpoint="127.0.0.1:0"/><engines/></bas>`));
  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline endpoint="127.0.0.1:70000"/><engines/></bas>`));
}

@("setline hostname rejects anything that is not a hostname") unittest {
  import std.exception : assertThrown;

  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline hostname="a b"/><engines/></bas>`));
  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline hostname="a/b"/><engines/></bas>`));
  assertThrown!ServerXmlException(parseServerXml(
      `<bas version="1"><setline hostname="a*"/><engines/></bas>`));
}

@("parse webapp <url> children as the exposed url prefixes") unittest {
  auto xml = `<bas version="1">
  <engines><engine name="t" type="tomcat-server" version="9"/></engines>
  <farms><farm name="f" engine="t"><server name="s1" http="8080"/></farm></farms>
  <webapps>
    <webapp uri="gav://a:one:1" run-at="f" path="/">
      <url path="/context1"/>
      <url path="/context2/"/>
      <url path="/context1"/>
    </webapp>
    <webapp uri="gav://a:two:1" run-at="f" path="/api"/>
  </webapps>
</bas>`;
  auto cfg = parseServerXml(xml);

  // 逐条保留声明顺序，规范化尾部 /，重复的忽略
  assert(cfg.webapps[0].urls == ["/context1", "/context2"]);
  // 声明了 <url> 就不再认领 context path
  assert(cfg.webapps[0].routePaths() == ["/context1", "/context2"]);
  // 未声明的退回 context path（/ 或空视为 ROOT）
  assert(cfg.webapps[1].urls.length == 0);
  assert(cfg.webapps[1].routePaths() == ["/api"]);

  auto root = parseServerXml(`<bas version="1">
  <engines><engine name="t" type="tomcat-server" version="9"/></engines>
  <farms><farm name="f" engine="t"><server name="s1" http="8080"/></farm></farms>
  <webapps><webapp uri="gav://a:one:1" run-at="f" path="/"/></webapps>
</bas>`);
  assert(root.webapps[0].routePaths() == ["/"]);
}

@("reject a webapp <url> that is not an absolute path") unittest {
  import std.exception : assertThrown;

  static string withUrl(string url) {
    return `<bas version="1">
  <engines><engine name="t" type="tomcat-server" version="9"/></engines>
  <farms><farm name="f" engine="t"><server name="s1" http="8080"/></farm></farms>
  <webapps><webapp uri="gav://a:one:1" run-at="f" path="/">` ~ url ~ `</webapp></webapps>
</bas>`;
  }

  // 缺少 path 属性，或不是以 / 开头
  assertThrown!ServerXmlException(parseServerXml(withUrl(`<url/>`)));
  assertThrown!ServerXmlException(parseServerXml(withUrl(`<url path="context1"/>`)));
  assertThrown!ServerXmlException(parseServerXml(withUrl(`<url path=""/>`)));
}

@("applyEngineDefault fills tomcat defaults once") unittest {
  auto cfg = parseServerXml(`<bas version="0.13.9">
      <engines><engine name="tomcat" type="tomcat-server" version="11.0.5"/></engines>
      <farms><farm name="f" engine="tomcat"><server name="s" http="8080"/></farm></farms>
    </bas>`);
  auto engine = cfg.engines[0];
  applyEngineDefault(cfg, engine);
  assert(engine.listeners.length == 2);
  assert(engine.context !is null);
  assert(engine.context.loader.className == "org.beangle.bas.engine.tomcat.ExtendableWebappLoader");
  assert(engine.context.jarScanner.properties["scanClassPath"] == "false");
  // 引擎依赖不再由默认值累加，而是由 resolveEngineDeps 从 engines.ini + <jar> 计算
  assert(engine.jars.length == 0);

  // 非 Tomcat 引擎不补 Tomcat 专有的 listener / Loader / JarScanner
  auto jetty = new Engine("j", containerTypeJetty, "12.0.30");
  applyEngineDefault(cfg, jetty);
  assert(jetty.listeners.length == 0);
  assert(jetty.context is null);
}

@("containerTypeOf accepts the four creator types and rejects the rest") unittest {
  import std.exception : assertThrown;

  auto cfg = parseServerXml(`<bas version="0.14.0">
      <engines>
        <engine name="ts" type="tomcat-server" version="11.0.26"/>
        <engine name="te" type="tomcat" version="11.0.26"/>
        <engine name="u" type="undertow" version="2.0.3.Final"/>
        <engine name="j" type="jetty" version="12.0.30"/>
      </engines>
    </bas>`);
  assert(containerTypeOf(cfg.engines[0]) == containerTypeTomcatServer);
  assert(containerTypeOf(cfg.engines[1]) == containerTypeTomcat);
  assert(containerTypeOf(cfg.engines[2]) == containerTypeUndertow);
  assert(containerTypeOf(cfg.engines[3]) == containerTypeJetty);
  assert(isTomcatType(cfg.engines[0].typ) && isTomcatType(cfg.engines[1].typ));
  assert(!isTomcatType(cfg.engines[2].typ) && !isTomcatType(cfg.engines[3].typ));

  // 其它类型都不再接受
  assertThrown!ServerXmlException(containerTypeOf(new Engine("r", "resin", "4.0.0")));
}

@("engineDefaultDeps reads the engines.ini section") unittest {
  auto dist = engineDefaultDeps(containerTypeTomcatServer);
  assert(dist.canFind("org.apache.tomcat:tomcat:zip:{version}"));
  assert(dist.canFind("org.beangle.bas:beangle-bas-engine:{bas}"));
  assert(dist.canFind("org.beangle.bas:beangle-bas-juli:{bas}"));

  auto embed = engineDefaultDeps(containerTypeTomcat);
  assert(embed.canFind("org.apache.tomcat.embed:tomcat-embed-core:{version}"));
  assert(embed.canFind("org.beangle.bas:beangle-bas-engine:{bas}"));
  // embed 不引入 juli，日志由应用自带
  assert(!embed.canFind("beangle-bas-juli"));

  auto undertow = engineDefaultDeps(containerTypeUndertow);
  assert(undertow.canFind("io.undertow.ee:undertow-servlet:{version}"));
  assert(undertow.canFind("io.undertow:undertow-core:2.4.4.Final"));
  assert(!undertow.canFind("beangle-bas-juli"));

  auto jetty = engineDefaultDeps(containerTypeJetty);
  assert(jetty.canFind("org.eclipse.jetty.ee10:jetty-ee10-webapp:{version}"));
  assert(jetty.canFind("org.eclipse.jetty.ee10:jetty-ee10-annotations:{version}"));
  // Jetty 的 AbstractLifeCycle 直接依赖 slf4j-api（无 JUL 回退）；只声明 API，provider 由应用自带
  assert(jetty.canFind("org.slf4j:slf4j-api:2.0.17"));
  assert(!jetty.canFind("logback"));
  assert(jetty.canFind("org.beangle.bas:beangle-bas-engine:{bas}"));
  assert(!jetty.canFind("beangle-bas-juli"));

  // 各类型的 websocket 补充集独立成 <type>.websocket 分节，基础分节不再包含它们
  assert(!embed.canFind("tomcat-embed-websocket"));
  assert(!undertow.canFind("undertow-websockets"));
  assert(engineDefaultDeps(containerTypeTomcat ~ ".websocket")
      .canFind("org.apache.tomcat.embed:tomcat-embed-websocket:{version}"));
  assert(engineDefaultDeps(containerTypeUndertow ~ ".websocket")
      .canFind("io.undertow.ee:undertow-websockets:{version}"));
  auto jettyWs = engineDefaultDeps(containerTypeJetty ~ ".websocket");
  assert(jettyWs.canFind("org.eclipse.jetty.ee10.websocket:jetty-ee10-websocket-jakarta-server:{version}"));
  assert(jettyWs.canFind("org.eclipse.jetty.websocket:jetty-websocket-core-server:{version}"));
  assert(jettyWs.canFind("org.eclipse.jetty:jetty-client:{version}"));
  assert(jettyWs.canFind("jakarta.websocket:jakarta.websocket-api:2.1.1"));
}

@("resolveEngineDeps adds websocket deps only when enabled") unittest {
  auto cfg = parseServerXml(`<bas version="0.14.0">
      <engines>
        <engine name="on" type="tomcat" version="11.0.26"/>
        <engine name="off" type="tomcat" version="11.0.26" websocket-support="false"/>
      </engines>
    </bas>`);
  assert(cfg.engines[0].websocketSupport);
  assert(!cfg.engines[1].websocketSupport);

  auto on = resolveEngineDeps(cfg, cfg.engines[0], containerTypeTomcat);
  assert(on.canFind("org.apache.tomcat.embed:tomcat-embed-websocket:11.0.26"));
  // 基础依赖仍在
  assert(on.canFind("org.apache.tomcat.embed:tomcat-embed-core:11.0.26"));

  auto off = resolveEngineDeps(cfg, cfg.engines[1], containerTypeTomcat);
  assert(!off.canFind("tomcat-embed-websocket"));
  assert(off.canFind("org.apache.tomcat.embed:tomcat-embed-core:11.0.26"));

  // jetty 的 websocket 补充集同样可关
  auto jettyCfg = parseServerXml(`<bas version="0.14.0">
      <engines>
        <engine name="j" type="jetty" version="12.0.30" websocket-support="false"/>
      </engines>
    </bas>`);
  auto jetty = resolveEngineDeps(jettyCfg, jettyCfg.engines[0], containerTypeJetty);
  assert(!jetty.canFind("jetty-ee10-websocket"));
  assert(jetty.canFind("org.eclipse.jetty.ee10:jetty-ee10-webapp:12.0.30"));
}

@("resolveEngineDeps expands placeholders and merges <jar> by GA") unittest {
  auto cfg = parseServerXml(`<bas version="0.14.0">
      <engines>
        <engine name="tomcat" type="tomcat-server" version="11.0.26">
          <jar uri="gav://org.apache.tomcat:tomcat:zip:11.0.24"/>
          <jar uri="gav://org.postgresql:postgresql:42.7.13"/>
          <jar uri="/opt/local/extra.jar"/>
        </engine>
      </engines>
    </bas>`);
  auto deps = resolveEngineDeps(cfg, cfg.engines[0], containerTypeTomcatServer);
  // 引擎与 juli 版本来自 <bas version>
  assert(deps.canFind("org.beangle.bas:beangle-bas-engine:0.14.0"));
  assert(deps.canFind("org.beangle.bas:beangle-bas-juli:0.14.0"));
  // GA 相同的默认项被 <jar> 覆盖（zip 仍在，版本换成 11.0.24）
  assert(deps.canFind("org.apache.tomcat:tomcat:zip:11.0.24"));
  assert(!deps.canFind("org.apache.tomcat:tomcat:zip:11.0.26"));
  // 自定义 GA 与本地路径追加
  assert(deps.canFind("org.postgresql:postgresql:42.7.13"));
  assert(deps.canFind("/opt/local/extra.jar"));
  // 覆盖发生在原位：tomcat zip 仍是第一行
  assert(deps[0] == "org.apache.tomcat:tomcat:zip:11.0.24");
}

@("resolveEngineDeps lets a <jar> override the bas engine version for embed") unittest {
  auto cfg = parseServerXml(`<bas version="0.14.0">
      <engines>
        <engine name="tomcat" type="tomcat" version="11.0.26">
          <jar uri="gav://org.beangle.bas:beangle-bas-engine:0.13.16"/>
          <jar uri="gav://ch.qos.logback:logback-core:1.6.3"/>
        </engine>
      </engines>
    </bas>`);
  auto deps = resolveEngineDeps(cfg, cfg.engines[0], containerTypeTomcat);
  // <jar> 覆盖默认的引擎版本，且不引入 juli
  assert(deps.canFind("org.beangle.bas:beangle-bas-engine:0.13.16"));
  assert(!deps.canFind("org.beangle.bas:beangle-bas-engine:0.14.0"));
  assert(!deps.canFind("beangle-bas-juli"));
  // 应用自带日志实现由 <jar> 追加
  assert(deps.canFind("ch.qos.logback:logback-core:1.6.3"));
}
