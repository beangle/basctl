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

/** Unit tests for bas.embed. */
module test.embed_test;

import bas.embed;

import std.algorithm : canFind;

@("EngineRef parses type-version pairs") unittest {
  auto tomcat = EngineRef.parse("tomcat-11.0.25");
  assert(tomcat.typ == "tomcat");
  assert(tomcat.version_ == "11.0.25");

  auto undertow = EngineRef.parse("undertow-2.0.3.Final");
  assert(undertow.typ == "undertow");
  assert(undertow.version_ == "2.0.3.Final");

  // 版本里可以带 `-`
  assert(EngineRef.parse("tomcat-11.0.0-M1").version_ == "11.0.0-M1");
  // 缺版本 / 未知类型 / 缺分隔符都算非法
  assert(EngineRef.parse("tomcat").typ.length == 0);
  assert(EngineRef.parse("tomcat-").typ.length == 0);
  assert(EngineRef.parse("-11.0.25").typ.length == 0);
  assert(EngineRef.parse("jetty-11").typ.length == 0);
}

@("parseRunArgs splits the entry, app args, jvm args and options") unittest {
  auto opts = parseRunArgs(["-Xmx512M", "/tmp/app.war", "--port=8080", "--path=/app",
      "extra", "-Dfoo=bar", "--engine=tomcat-11.0.25", "--bas=9.9.9",
      "--base=/srv", "--instance=portal.1", "--workdir=/srv/bas", "--local=/m2",
      "--remote=http://r1,http://r2", "--offline", "--print", "--spec=/tmp/x.jstart"]);
  assert(opts.error.length == 0);
  assert(opts.entry == "/tmp/app.war");
  assert(opts.engine.typ == "tomcat" && opts.engine.version_ == "11.0.25");
  assert(opts.bas == "9.9.9");
  assert(opts.base == "/srv");
  assert(opts.instance == "portal.1");
  assert(opts.workdir == "/srv/bas");
  assert(opts.local == "/m2");
  assert(opts.remote == "http://r1,http://r2");
  assert(opts.spec == "/tmp/x.jstart");
  assert(opts.offline);
  assert(opts.printOnly);
  assert(opts.runtimeArgs == ["-Xmx512M", "-Dfoo=bar"]);
  assert(opts.appArgs == ["--port=8080", "--path=/app", "extra"]);
}

@("parseRunArgs defaults bas to the built-in value") unittest {
  auto opts = parseRunArgs(["--engine=tomcat-11.0.25", "app.war"]);
  assert(opts.error.length == 0);
  assert(opts.bas == defaultBasVersion);
  assert(opts.base == "/tmp");
  assert(opts.instance == "bas");
}

@("parseRunArgs requires a well-formed --engine") unittest {
  assert(parseRunArgs(["app.war"]).error.canFind("Missing --engine"));
  assert(parseRunArgs(["--engine=jetty-11", "app.war"]).error.canFind("Invalid --engine"));
  assert(parseRunArgs(["--engine=tomcat-11.0.25", "--instance=../etc", "app.war"])
      .error.canFind("Invalid --instance"));
  assert(parseRunArgs(["--engine=tomcat-11.0.25", "--instance=.", "app.war"])
      .error.canFind("Invalid --instance"));
  assert(parseRunArgs(["--engine=tomcat-11.0.25", "--base=", "app.war"]).error.canFind("--base"));
  assert(parseRunArgs(["--engine=tomcat-11.0.25", "--help", "app.war"]).help);
  assert(!isSafeInstance("a/b"));
  assert(isSafeInstance("portal-1.2_x"));
}

@("planRun picks the embed container and engines.ini deps") unittest {
  auto opts = parseRunArgs(["--engine=tomcat-11.0.25", "app.war"]);
  auto tomcat = planRun(opts);
  assert(tomcat.containerType == "tomcat-embed");
  assert(tomcat.deps.canFind("org.apache.tomcat.embed:tomcat-embed-core:11.0.25"));
  assert(tomcat.deps.canFind("org.beangle.bas:beangle-bas-engine:" ~ defaultBasVersion));
  assert(!tomcat.deps.canFind("org.apache.tomcat:tomcat:zip:"));

  opts = parseRunArgs(["--engine=undertow-2.0.3.Final", "--bas=1.2.3", "app.war"]);
  auto undertow = planRun(opts);
  assert(undertow.containerType == "undertow-embed");
  assert(undertow.deps.canFind("io.undertow.ee:undertow-servlet:2.0.3.Final"));
  assert(undertow.deps.canFind("org.beangle.bas:beangle-bas-engine:1.2.3"));
  assert(!undertow.deps.canFind("beangle-bas-juli"));
}

@("warTarget rewrites a 3-part gav to war packaging only") unittest {
  assert(warTarget("org.beangle:app:1.0") == "org.beangle:app:war:1.0");
  assert(warTarget("org.beangle:app:war:1.0") == "org.beangle:app:war:1.0");
  assert(warTarget("http://host:8080/app.war") == "http://host:8080/app.war");
  assert(warTarget("/tmp/app.war") == "/tmp/app.war");
  assert(warTarget("gav://org.beangle:app:1.0") == "gav://org.beangle:app:1.0");
}
