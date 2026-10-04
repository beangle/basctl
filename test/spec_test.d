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

/** Unit tests for bas.spec. */
module test.spec_test;

import bas.spec;

import std.algorithm : canFind;
import std.string : startsWith;

@("renderLaunchSpec writes engine, runtime, args and one section per subapp") unittest {
  auto text = renderLaunchSpec("/srv/sas/servers", "platform.server1", "/srv/sas",
      "/srv/sas/bin/basctl make tomcat-dist",
      ["org.apache.tomcat:tomcat:zip:11.0.18", "org.beangle.sas:beangle-sas-engine:0.13.16"],
      ["-Xmx300M", "-Dems.profile=local"], ["--port=8081"],
      [SubappSpec("cas", "/r/cas.war", "/cas", "org.postgresql:postgresql:42.7.9"),
       SubappSpec("portal", "/r/portal.war", "/portal", "")]);
  assert(text.canFind("[app]\nbase = /srv/sas/servers\ninstance = platform.server1\n"));
  assert(text.canFind("working_dir = /srv/sas\n"));
  assert(text.canFind("init = /srv/sas/bin/basctl make tomcat-dist\n"));
  assert(text.canFind("\n[runtime]\n-Xmx300M\n-Dems.profile=local\n"));
  assert(text.canFind("\n[args]\n--port=8081\n"));
  assert(text.canFind("\n[subapp cas]\nentry = /r/cas.war\npath = /cas\nlibs = org.postgresql:postgresql:42.7.9\n"));
  assert(text.canFind("\n[subapp portal]\nentry = /r/portal.war\npath = /portal\n"));
  assert(!text.canFind("libs = \n"));
  assert(!text.canFind("entry = /r/portal.war\n\n[engine]"));
}

@("renderLaunchSpec writes a single [app] entry for embedded runs") unittest {
  auto text = renderLaunchSpec("/tmp", "sas", "/srv/sas",
      "/opt/basctl make tomcat-embed", ["org.beangle.sas:beangle-sas-engine:0.13.16"],
      ["-Xmx512M"], ["--port=8080", "--path=/app"], [], "/tmp/app.war");
  assert(text.canFind("[app]\nentry = /tmp/app.war\nbase = /tmp\ninstance = sas\n"));
  assert(text.canFind("\n[engine]\ninit = /opt/basctl make tomcat-embed\n"
      ~ "org.beangle.sas:beangle-sas-engine:0.13.16\n"));
  assert(text.canFind("\n[runtime]\n-Xmx512M\n"));
  assert(text.canFind("\n[args]\n--port=8080\n--path=/app\n"));
  assert(!text.canFind("[subapp"));
}

@("shellQuote escapes single quotes") unittest {
  assert(shellQuote("/a/b") == "'/a/b'");
  assert(shellQuote("a'b") == `'a'\''b'`);
}

@("engineInitCommand quotes the basctl path and names the make subcommand") unittest {
  auto cmd = engineInitCommand();
  assert(cmd.canFind(" make tomcat-dist"));
  assert(cmd.startsWith("'") || cmd.canFind("'"));
}

@("engineInitCommand accepts the embedded container types") unittest {
  assert(engineInitCommand("tomcat-embed").canFind(" make tomcat-embed"));
  assert(engineInitCommand("undertow-embed").canFind(" make undertow-embed"));
}
