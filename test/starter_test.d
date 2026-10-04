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

@("runtimeArgsFor adds sas defaults and farm options") unittest {
  auto cfg = parseServerXml(`<Sas version="1"><Engines><Engine name="tomcat" type="tomcat"
      version="11.0.18"/></Engines><Farms><Farm name="f" engine="tomcat" maxHeapSize="512M">
      <ServerOptions>-Dems.profile=local
      --add-opens=java.base/java.lang=ALL-UNNAMED</ServerOptions>
      <Server name="s1" http="8080"/></Farm></Farms>
      <Webapps><Webapp uri="gav://g:a:1" runAt="f" path="/"/></Webapps></Sas>`);
  auto server = cfg.farms[0].servers[0];
  auto args = runtimeArgsFor(server);
  assert(args.canFind("-Xmx512M"));
  assert(args.canFind("-Dsas.server=f.s1"));
  assert(args.canFind("-Dems.profile=local"));
  assert(args.canFind("--add-opens=java.base/java.lang=ALL-UNNAMED"));
  assert(appArgsFor(server) == ["--port=8080"]);
}

@("repoArgs passes release and snapshot repositories through to jstart") unittest {
  auto cfg = parseServerXml(`<Sas version="0.13.16">
      <Repository local="/m2" remote="http://r1,http://r2"/>
      <SnapshotRepo remote="http://snap"/>
      <Engines><Engine name="tomcat" type="tomcat" version="11.0.18"/></Engines>
      <Hosts><Host name="local" ip="127.0.0.1"/></Hosts>
      <Farms><Farm name="f" engine="tomcat"><Server name="s" http="8080"/></Farm></Farms>
      <Webapps><Webapp uri="gav://g:a:1" runAt="f" path="/"/></Webapps></Sas>`);
  assert(repoArgs(cfg) == ["--local=/m2", "--remote=http://r1,http://r2",
      "--snapshot-remote=http://snap"]);
}

@("repoArgs falls back to the snapshot local and omits empty repositories") unittest {
  auto cfg = parseServerXml(`<Sas version="0.13.16">
      <SnapshotRepo local="/m2snap"/>
      <Engines><Engine name="tomcat" type="tomcat" version="11.0.18"/></Engines>
      <Hosts><Host name="local" ip="127.0.0.1"/></Hosts>
      <Farms><Farm name="f" engine="tomcat"><Server name="s" http="8080"/></Farm></Farms>
      <Webapps><Webapp uri="gav://g:a:1" runAt="f" path="/"/></Webapps></Sas>`);
  assert(repoArgs(cfg) == ["--local=/m2snap"]);
}
