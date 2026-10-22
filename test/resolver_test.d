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

/** Unit tests for bas.resolver. */
module test.resolver_test;

import bas.artifact : parseArtifact;
import bas.resolver;

import core.time : minutes;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, rmdirRecurse, setTimes, tempDir, write;
import std.path : buildPath, dirName;
import std.typecons : Nullable, nullable;
import std.uuid : randomUUID;

@("parse gav lists") unittest {
  auto a = parseGavs("g1:a1:1; g2:a2:2,\n g3:a3:war:3");
  assert(a.length == 3);
  assert(a[0].asGav() == "g1:a1:1");
  assert(a[2].packaging == "war");
  assert(parseGavs("  ").length == 0);
}

@("resolvable recognizes archives and dirs") unittest {
  assert(resolvable("/tmp/a.jar"));
  assert(resolvable("/tmp/a.war"));
  assert(!resolvable("/tmp/a.txt"));
}

@("SNAPSHOT falls back to BAS_HOME/webapps when repository fetch fails") unittest {
  auto root = buildPath(tempDir, "basctl-resolver-" ~ randomUUID().toString());
  auto gav = parseArtifact("org.xurp.prac:xurp-prac-labour:war:0.0.3-SNAPSHOT");
  auto localWar = buildPath(root, "webapps", gav.fileName());
  mkdirRecurse(dirName(localWar));
  write(localWar, "local");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto chosen = chooseSnapshotEntry(root, gav, Nullable!string.init);
  assert(!chosen.isNull);
  assert(chosen.get == localWar);
}

@("SNAPSHOT prefers the newer of repository and BAS_HOME/webapps") unittest {
  auto root = buildPath(tempDir, "basctl-resolver-" ~ randomUUID().toString());
  auto gav = parseArtifact("org.xurp.prac:xurp-prac-labour:war:0.0.3-SNAPSHOT");
  auto localWar = buildPath(root, "webapps", gav.fileName());
  auto repoWar = buildPath(root, "repository", gav.fileName());
  mkdirRecurse(dirName(localWar));
  mkdirRecurse(dirName(repoWar));
  write(localWar, "local");
  write(repoWar, "repository");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto now = Clock.currTime;
  setTimes(repoWar, now, now - 2.minutes);
  setTimes(localWar, now, now - 1.minutes);
  assert(chooseSnapshotEntry(root, gav, nullable(repoWar)).get == localWar);

  setTimes(localWar, now, now - 3.minutes);
  assert(chooseSnapshotEntry(root, gav, nullable(repoWar)).get == repoWar);
}
