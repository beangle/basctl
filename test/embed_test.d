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
import std.process : environment;

@("parseRunArgs splits the entry, app args, jvm args and options") unittest {
  auto opts = parseRunArgs(["-Xmx512M", "/tmp/app.war", "--port=8080", "--path=/app",
      "extra", "-Dfoo=bar", "--engine=undertow", "--base=/srv", "--instance=portal.1",
      "--workdir=/srv/sas", "--local=/m2", "--remote=http://r1,http://r2", "--offline",
      "--print", "--spec=/tmp/x.jstart"]);
  assert(opts.error.length == 0);
  assert(opts.entry == "/tmp/app.war");
  assert(opts.engine == "undertow");
  assert(opts.base == "/srv");
  assert(opts.instance == "portal.1");
  assert(opts.workdir == "/srv/sas");
  assert(opts.local == "/m2");
  assert(opts.remote == "http://r1,http://r2");
  assert(opts.spec == "/tmp/x.jstart");
  assert(opts.offline);
  assert(opts.printOnly);
  assert(opts.runtimeArgs == ["-Xmx512M", "-Dfoo=bar"]);
  assert(opts.appArgs == ["--port=8080", "--path=/app", "extra"]);
}

@("parseRunArgs defaults to tomcat at /tmp/sas") unittest {
  auto opts = parseRunArgs(["app.war"]);
  assert(opts.error.length == 0);
  assert(opts.engine == "tomcat");
  assert(opts.base == "/tmp");
  assert(opts.instance == "sas");
  assert(opts.entry == "app.war");
}

@("parseRunArgs reports invalid engine and instance names") unittest {
  assert(parseRunArgs(["--engine=jetty", "app.war"]).error.canFind("Unknown engine"));
  assert(parseRunArgs(["--instance=../etc", "app.war"]).error.canFind("Invalid --instance"));
  assert(parseRunArgs(["--instance=.", "app.war"]).error.canFind("Invalid --instance"));
  assert(parseRunArgs(["--base=", "app.war"]).error.canFind("--base"));
  assert(!isSafeInstance("a/b"));
  assert(isSafeInstance("portal-1.2_x"));
}

@("warTarget rewrites a 3-part gav to war packaging only") unittest {
  assert(warTarget("org.beangle:app:1.0") == "org.beangle:app:war:1.0");
  assert(warTarget("org.beangle:app:war:1.0") == "org.beangle:app:war:1.0");
  assert(warTarget("http://host:8080/app.war") == "http://host:8080/app.war");
  assert(warTarget("/tmp/app.war") == "/tmp/app.war");
  assert(warTarget("gav://org.beangle:app:1.0") == "gav://org.beangle:app:1.0");
}

@("embedEngineDeps lists the engine plus the selected container") unittest {
  EmbedVersions v;
  auto tomcat = embedEngineDeps("tomcat", v);
  assert(tomcat.canFind("org.beangle.sas:beangle-sas-engine:" ~ v.engine));
  assert(tomcat.canFind("org.scala-lang:scala3-library_3:" ~ v.scala));
  assert(tomcat.canFind("org.apache.tomcat.embed:tomcat-embed-core:" ~ v.tomcat));
  assert(!tomcat.canFind("io.undertow:undertow-core:"));

  auto undertow = embedEngineDeps("undertow", v);
  assert(undertow.canFind("io.undertow:undertow-core:" ~ v.undertow));
  assert(undertow.canFind("io.undertow.ee:undertow-servlet:" ~ v.undertowEe));
  assert(!undertow.canFind("org.apache.tomcat.embed:tomcat-embed-core:"));
}

@("embedVersions can be overridden per artifact") unittest {
  auto previous = environment.get("bas_engine_version", "");
  environment["bas_engine_version"] = "9.9.9";
  scope (exit) {
    if (previous.length)
      environment["bas_engine_version"] = previous;
    else
      environment.remove("bas_engine_version");
  }
  assert(embedVersions().engine == "9.9.9");
}
