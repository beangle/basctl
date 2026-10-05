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
  auto a = parseArtifact("org.beangle.bas:demo:1.0.4");
  assert(a.groupId == "org.beangle.bas");
  assert(a.artifactId == "demo");
  assert(a.version_ == "1.0.4");
  assert(a.classifier == "");
  assert(a.packaging == "jar");
  assert(a.asGav() == "org.beangle.bas:demo:1.0.4");
}

@("parse 4 part gav with packaging") unittest {
  auto a = parseArtifact("org.beangle.bas:demo:war:1.0.4");
  assert(a.packaging == "war" && a.classifier == "");
  assert(a.asGav() == "org.beangle.bas:demo:war:1.0.4");
  assert(a.fileName() == "demo-1.0.4.war");
  assert(a.dirPath() == "/org/beangle/bas/demo/1.0.4");
  assert(a.layoutPath() == "/org/beangle/bas/demo/1.0.4/demo-1.0.4.war");
}

@("parse 4 part gav with classifier") unittest {
  auto a = parseArtifact("org.beangle.bas:demo:sources:1.0.4");
  assert(a.packaging == "jar" && a.classifier == "sources");
  assert(a.fileName() == "demo-1.0.4-sources.jar");
  assert(a.asGav() == "org.beangle.bas:demo:jar:sources:1.0.4");
}

@("parse 5 part gav") unittest {
  auto a = parseArtifact("org.beangle.bas:demo:war:sources:1.0.4");
  assert(a.packaging == "war" && a.classifier == "sources");
  assert(a.asGav() == "org.beangle.bas:demo:war:sources:1.0.4");
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

@("isMavenCoord accepts coordinates and rejects urls or paths") unittest {
  // 3 段及以上视为坐标；gav:// 前缀不影响
  assert(isMavenCoord("g:a:1"));
  assert(isMavenCoord("org.apache.tomcat:tomcat:zip:11.0.26"));
  assert(isMavenCoord("gav://org.beangle.bas:beangle-bas-engine:0.14.0"));
  // 少于 3 段不是坐标
  assert(!isMavenCoord("g:a"));
  // url 与本地路径不是坐标
  assert(!isMavenCoord("https://host/a.jar"));
  assert(!isMavenCoord("http://host/a.jar"));
  assert(!isMavenCoord("/opt/libs/extra.jar"));
  assert(!isMavenCoord("~/libs/extra.jar"));
  assert(!isMavenCoord("./extra.jar"));
}

@("gaOf extracts groupId:artifactId from coordinates only") unittest {
  assert(gaOf("org.apache.tomcat:tomcat:zip:11.0.26") == "org.apache.tomcat:tomcat");
  assert(gaOf("gav://org.beangle.bas:beangle-bas-engine:0.14.0")
      == "org.beangle.bas:beangle-bas-engine");
  assert(gaOf("https://host/a.jar") == "");
  assert(gaOf("/opt/libs/extra.jar") == "");
}
