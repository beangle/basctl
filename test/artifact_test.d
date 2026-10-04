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

/** Unit tests for bas.artifact. */
module test.artifact_test;

import bas.artifact;

@("parse 3 part gav") unittest {
  auto a = parseArtifact("org.beangle.sas:demo:1.0.4");
  assert(a.groupId == "org.beangle.sas");
  assert(a.artifactId == "demo");
  assert(a.version_ == "1.0.4");
  assert(a.classifier == "");
  assert(a.packaging == "jar");
  assert(a.asGav() == "org.beangle.sas:demo:1.0.4");
}

@("parse 4 part gav with packaging") unittest {
  auto a = parseArtifact("org.beangle.sas:demo:war:1.0.4");
  assert(a.packaging == "war" && a.classifier == "");
  assert(a.asGav() == "org.beangle.sas:demo:war:1.0.4");
  assert(a.fileName() == "demo-1.0.4.war");
  assert(a.dirPath() == "/org/beangle/sas/demo/1.0.4");
  assert(a.layoutPath() == "/org/beangle/sas/demo/1.0.4/demo-1.0.4.war");
}

@("parse 4 part gav with classifier") unittest {
  auto a = parseArtifact("org.beangle.sas:demo:sources:1.0.4");
  assert(a.packaging == "jar" && a.classifier == "sources");
  assert(a.fileName() == "demo-1.0.4-sources.jar");
  assert(a.asGav() == "org.beangle.sas:demo:jar:sources:1.0.4");
}

@("parse 5 part gav") unittest {
  auto a = parseArtifact("org.beangle.sas:demo:war:sources:1.0.4");
  assert(a.packaging == "war" && a.classifier == "sources");
  assert(a.asGav() == "org.beangle.sas:demo:war:sources:1.0.4");
}

@("snapshot and packaging helpers") unittest {
  auto a = parseArtifact("g:a:1.0-SNAPSHOT");
  assert(a.isSnapshot());
  assert(a.withPackaging("war").packaging == "war");
}

@("gav uri helpers") unittest {
  assert(isGav("gav://g:a:1"));
  assert(isRemote("https://host/a.jar"));
  assert(!isGav("https://host/a.jar"));
  assert(toArtifact("gav://g:a:1").artifactId == "a");
}
