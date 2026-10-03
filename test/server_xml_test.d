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

module test.server_xml_test;

import beangle.sas.config;

import std.algorithm.searching : canFind;
import std.file : readText;
import std.format : format;

@("parse repo server.xml sample") unittest {
  immutable xml = readText("server.xml");
  SasConfig cfg = parseServerXml(xml);
  assert(cfg.version_ == "0.13.9");
  assert(!cfg.sasPort.isNull && cfg.sasPort.get == 8080);
  assert(cfg.engines.length == 1);
  assert(cfg.engines[0].name == "tomcat");
  assert(cfg.engines[0].jars.length == 1);
  assert(cfg.engines[0].jars[0].uri == "gav://org.postgresql:postgresql:42.7.9");
  assert(cfg.farms.length == 2);
  assert(cfg.farms[0].name == "tools");
  assert(cfg.farms[0].servers.length == 1);
  assert(cfg.farms[0].servers[0].http == 8088);
  assert(cfg.farms[1].name == "platform");
  assert(!cfg.farms[1].serverOptions.isNull);
  assert(cfg.farms[1].serverOptions.get.canFind("-Dems.profile=local"));
  assert(cfg.farms[1].servers[0].http == 8081);
  assert(cfg.webapps.length == 4);
  assert(cfg.webapps[0].contextPath == "/api/tools");
  assert(cfg.webapps[0].runAtQualifiedServers == ["tools.server1"]);
  auto cas = cfg.webapps[1];
  assert(cas.contextPath == "/cas");
  assert(cas.runAtQualifiedServers == ["platform.server1"]);
}

@("runAt resolves qualified server name") unittest {
  immutable xml = format!(`
    <Sas version="1" port="80">
      <Engines><Engine name="t" type="tomcat" version="9"/></Engines>
      <Farms>
        <Farm name="a" engine="t"><Server name="s1" http="8080"/></Farm>
      </Farms>
      <Webapps>
        <Webapp uri="gav://x:y:1" runAt="a.s1" path="/x"/>
      </Webapps>
    </Sas>`);
  SasConfig cfg = parseServerXml(xml);
  assert(cfg.webapps[0].runAtQualifiedServers == ["a.s1"]);
}
