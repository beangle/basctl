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

/** Unit tests for bas.render. */
module test.render_test;

import bas.config;
import bas.render;

import std.algorithm : canFind;

@("render server.xml keeps fail-fast listener and connectors") unittest {
  auto xml = `<Sas version="9"><Engines><Engine name="tomcat" type="tomcat" version="11.0.5"/></Engines>
    <Farms><Farm name="f" engine="tomcat"><Server name="s" http="8080"/></Farm></Farms>
    <Webapps><Webapp uri="gav://g:a:1" runAt="f" path="/x"/></Webapps></Sas>`;
  auto cfg = parseServerXml(xml);
  auto ctx = new Context;
  auto loader = new Loader("org.beangle.sas.engine.tomcat.ExtendableWebappLoader");
  loader.properties["loaderClass"] = "org.beangle.sas.engine.tomcat.DependencyClassLoader";
  ctx.loader = loader;
  cfg.engines[0].context = ctx;
  auto text = renderServerXml(cfg, cfg.farms[0], cfg.farms[0].servers[0]);
  assert(text.canFind("WebappFailFastListener"));
  assert(text.canFind(`port="8080"`));
  assert(text.canFind("useVirtualThreads=\"true\""));
  assert(text.canFind(`<Context path="/x"`));
  assert(text.canFind(`<Loader className="org.beangle.sas.engine.tomcat.ExtendableWebappLoader"`));
}

@("render setenv.sh uses server options") unittest {
  auto xml = `<Sas version="9"><Engines><Engine name="t" type="tomcat" version="9"/></Engines>
    <Farms><Farm name="f" engine="t"><ServerOptions>-Dx=1</ServerOptions>
    <Server name="s" http="80"/></Farm></Farms></Sas>`;
  auto cfg = parseServerXml(xml);
  auto text = renderSetenvSh(cfg.farms[0], cfg.farms[0].servers[0]);
  assert(text.canFind("-Xmx300M"));
  assert(text.canFind("-Dx=1"));
}

@("render web.xml switches namespace by version") unittest {
  Engine e11 = new Engine("t", "tomcat", "11.0.5");
  auto xml11 = renderWebXml(e11);
  assert(xml11.canFind("web-app_6_1.xsd"));
  assert(!xml11.canFind("jsp/jspx"));

  Engine e9 = new Engine("t", "tomcat", "9.0.1");
  e9.jspSupport = true;
  auto xml9 = renderWebXml(e9);
  assert(xml9.canFind("web-app_4_0.xsd"));
  assert(xml9.canFind("JspServlet"));
}

@("render firewall xml lists ports") unittest {
  assert(renderFirewallConf([8080, 8081]).canFind(`<port protocol="tcp" port="8081"/>`));
}
