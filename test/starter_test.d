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

@("renderLaunchSpec writes engine, runtime, args and one section per subapp") unittest {
  auto text = renderLaunchSpec("/srv/sas/servers", "platform.server1", "/srv/sas",
      "/srv/sas/bin/basctl-tomcat-dist-init.sh",
      ["org.apache.tomcat:tomcat:zip:11.0.18", "org.beangle.sas:beangle-sas-engine:0.13.16"],
      ["-Xmx300M", "-Dems.profile=local"], ["--port=8081"],
      [SubappSpec("cas", "/r/cas.war", "/cas", "org.postgresql:postgresql:42.7.9"),
       SubappSpec("portal", "/r/portal.war", "/portal", "")]);
  assert(text.canFind("[app]\nbase = /srv/sas/servers\ninstance = platform.server1\n"));
  assert(text.canFind("working_dir = /srv/sas\n"));
  assert(text.canFind("init = /srv/sas/bin/basctl-tomcat-dist-init.sh\n"));
  assert(text.canFind("\n[runtime]\n-Xmx300M\n-Dems.profile=local\n"));
  assert(text.canFind("\n[args]\n--port=8081\n"));
  assert(text.canFind("\n[subapp cas]\nentry = /r/cas.war\npath = /cas\nlibs = org.postgresql:postgresql:42.7.9\n"));
  assert(text.canFind("\n[subapp portal]\nentry = /r/portal.war\npath = /portal\n"));
  assert(!text.canFind("libs = \n"));
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

@("shellQuote escapes single quotes") unittest {
  assert(shellQuote("/a/b") == "'/a/b'");
  assert(shellQuote("a'b") == `'a'\''b'`);
}
