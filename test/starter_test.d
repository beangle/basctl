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
  auto cfg = parseServerXml(`<bas version="1"><engines><engine name="tomcat" type="tomcat"
      version="11.0.18"/></engines><farms><farm name="f" engine="tomcat" max-heap-size="512M">
      <server-options>-Dems.profile=local
      --add-opens=java.base/java.lang=ALL-UNNAMED</server-options>
      <server name="s1" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  auto server = cfg.farms[0].servers[0];
  auto args = runtimeArgsFor(server);
  assert(args.canFind("-Xmx512M"));
  assert(args.canFind("-Dsas.server=f.s1"));
  assert(args.canFind("-Dems.profile=local"));
  assert(args.canFind("--add-opens=java.base/java.lang=ALL-UNNAMED"));
  assert(appArgsFor(server) == ["--port=8080"]);
}

@("repoArgs passes release and snapshot repositories through to jstart") unittest {
  auto cfg = parseServerXml(`<bas version="0.13.16">
      <repository local="/m2" remote="http://r1,http://r2"/>
      <snapshot-repo remote="http://snap"/>
      <engines><engine name="tomcat" type="tomcat" version="11.0.18"/></engines>
      <hosts><host name="local" ip="127.0.0.1"/></hosts>
      <farms><farm name="f" engine="tomcat"><server name="s" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  assert(repoArgs(cfg) == ["--local=/m2", "--remote=http://r1,http://r2",
      "--snapshot-remote=http://snap"]);
}

@("repoArgs falls back to the snapshot local and omits empty repositories") unittest {
  auto cfg = parseServerXml(`<bas version="0.13.16">
      <snapshot-repo local="/m2snap"/>
      <engines><engine name="tomcat" type="tomcat" version="11.0.18"/></engines>
      <hosts><host name="local" ip="127.0.0.1"/></hosts>
      <farms><farm name="f" engine="tomcat"><server name="s" http="8080"/></farm></farms>
      <webapps><webapp uri="gav://g:a:1" run-at="f" path="/"/></webapps></bas>`);
  assert(repoArgs(cfg) == ["--local=/m2snap"]);
}
