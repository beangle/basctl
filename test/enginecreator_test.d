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

/** Unit tests for bas.enginecreator. */
module test.enginecreator_test;

import bas.enginecreator;

import std.algorithm : canFind;
import std.array : replicate, split;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : absolutePath, buildPath;
import std.string : representation;
import std.uuid : randomUUID;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

@("normalizePath folds slashes and trims edges") unittest {
  assert(normalizePath(null) == "");
  assert(normalizePath("") == "");
  assert(normalizePath("/") == "");
  assert(normalizePath("a") == "/a");
  assert(normalizePath("/a/") == "/a");
  assert(normalizePath("/a//b/") == "/a/b");
}

@("docBaseName follows the webapps layout") unittest {
  assert(docBaseName("/") == "ROOT");
  assert(docBaseName("") == "ROOT");
  assert(docBaseName("/portal") == "portal");
  assert(docBaseName("/a/b") == "a#b");
}

@("parseEngineArgs reads the jstart protocol") unittest {
  auto o = parseEngineArgs(["--base=/b", "--entry=/w/app.war", "--entry-out=/b/e.argv",
      "--engine-classpath-file=/b/engine.cp", "--app-classpath-file=/b/app.cp",
      "--local-repo=/repo", "--app-jvm-arg=-Xmx1g", "--port=8080", "--path=/a/b",
      "--jsp=true", "--listener=com.x.L:k=v", "--Dfoo=bar", "--Dbaz", "extra"]);
  assert(o.base == "/b");
  assert(o.entry == "/w/app.war");
  assert(o.entryOut == "/b/e.argv");
  assert(o.engineClasspathFile == "/b/engine.cp");
  assert(o.appClasspathFile == "/b/app.cp");
  assert(o.localRepo == "/repo");
  assert(o.appJvmArgs == ["-Xmx1g"]);
  assert(o.port == "8080");
  assert(o.path == "/a/b");
  assert(o.jspSupport);
  assert(o.listeners == ["com.x.L:k=v"]);
  assert(o.properties.length == 2);
  assert(o.properties[0].key == "foo" && o.properties[0].value == "bar");
  assert(o.properties[1].key == "baz" && o.properties[1].value == "true");
  assert(o.others == ["extra"]);
}

@("propertyArgs restores --D flags") unittest {
  auto args = propertyArgs([EngineProperty("a", "1"), EngineProperty("b", "2")]);
  assert(args == ["--Da=1", "--Db=2"]);
}

@("quoteArg quotes only when needed") unittest {
  assert(quoteArg("-Xmx1g") == "-Xmx1g");
  assert(quoteArg("/a b") == "\"/a b\"");
  assert(quoteArg("") == "\"\"");
  assert(quoteArg("#x") == "\"#x\"");
  assert(quoteArg("a\\b") == "\"a\\\\b\"");
}

@("explodeZip skips zip-slip entries") unittest {
  auto root = buildPath(tempDir, "basctl-ec-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) {
    if (exists(root))
      rmdirRecurse(root);
  }
  auto archive = buildPath(root, "t.zip");
  auto zip = new ZipArchive();
  foreach (e; [["ok.txt", "ok"], ["../evil.txt", "evil"], ["sub/b.txt", "b"]]) {
    auto m = new ArchiveMember();
    m.name = e[0];
    m.expandedData(cast(ubyte[]) e[1].dup.representation);
    m.compressionMethod = CompressionMethod.deflate;
    zip.addMember(m);
  }
  write(archive, zip.build());

  auto outDir = buildPath(root, "out");
  explodeZip(archive, outDir);
  assert(readText(buildPath(outDir, "ok.txt")) == "ok");
  assert(readText(buildPath(outDir, "sub", "b.txt")) == "b");
  assert(!exists(buildPath(root, "evil.txt")));
}

@("writeLaunchArgv folds long commands into an argfile") unittest {
  auto root = buildPath(tempDir, "basctl-argv-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) {
    if (exists(root))
      rmdirRecurse(root);
  }
  auto shortOut = buildPath(root, "short.argv");
  writeLaunchArgv(shortOut, ["java", "-cp", "a.jar", "Main"]);
  assert(readText(shortOut) == "java\0-cp\0a.jar\0Main\0");

  auto longOut = buildPath(root, "long.argv");
  writeLaunchArgv(longOut, ["java", "-cp", replicate("x", 5000), "Main"]);
  assert(readText(longOut) == "java\0@" ~ absolutePath(longOut ~ ".args") ~ "\0");
  auto argFile = readText(longOut ~ ".args");
  auto lines = split(argFile, "\n");
  assert(lines[0] == "-cp");
  assert(lines[2] == "Main");
}

@("prepareWebapp explodes a war and keeps a directory") unittest {
  auto root = buildPath(tempDir, "basctl-prep-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) {
    if (exists(root))
      rmdirRecurse(root);
  }
  auto war = buildPath(root, "app.war");
  auto zip = new ZipArchive();
  auto m = new ArchiveMember();
  m.name = "index.html";
  m.expandedData(cast(ubyte[]) "hi".representation);
  m.compressionMethod = CompressionMethod.deflate;
  zip.addMember(m);
  write(war, zip.build());

  EngineOptions o;
  o.base = buildPath(root, "base");
  o.entry = war;
  o.path = "/a/b";
  auto docBase = prepareWebapp(o);
  assert(docBase == absolutePath(buildPath(o.base, "webapps", "a#b")));
  assert(readText(buildPath(docBase, "index.html")) == "hi");
  assert(dirHere(buildPath(docBase, "WEB-INF", "classes")));

  EngineOptions d;
  d.base = root;
  d.entry = root;
  assert(prepareWebapp(d) == absolutePath(root));
}

@("parseSubappsPlan reads jstart subapp sections") unittest {
  auto apps = parseSubappsPlan(
      "# Generated by jstart: resolved subapps for the dist engine. Do not edit.\n"
      ~ "\n[subapp portal]\nentry = /srv/portal.war\npath = /portal\nlibs = a:b:1,c:d:2\n"
      ~ "\n[subapp admin]\nentry = /srv/admin\npath = /admin\n");
  assert(apps.length == 2);
  assert(apps[0].id == "portal");
  assert(apps[0].entry == "/srv/portal.war");
  assert(apps[0].path == "/portal");
  assert(apps[0].libs == "a:b:1,c:d:2");
  assert(apps[1].id == "admin");
  assert(apps[1].entry == "/srv/admin");
  assert(apps[1].libs.length == 0);
}

@("parseSubappsPlan rejects an incomplete section") unittest {
  bool threw;
  try
    parseSubappsPlan("[subapp broken]\npath = /broken\n");
  catch (Exception)
    threw = true;
  assert(threw);
}

@("validateSubapps rejects duplicate id, context path and docBase") unittest {
  bool dupId;
  try
    validateSubapps([Subapp("a", "/x.war", "/x", ""), Subapp("a", "/y.war", "/y", "")]);
  catch (Exception)
    dupId = true;
  assert(dupId);

  bool dupCtx;
  try
    validateSubapps([Subapp("a", "/x.war", "/x", ""), Subapp("b", "/y.war", "x", "")]);
  catch (Exception)
    dupCtx = true;
  assert(dupCtx);

  // "/a/b" 与 "/a#b" 是不同的 context path，却共用 webapps/a#b 这一个 docBase
  bool dupDocBase;
  try
    validateSubapps([Subapp("a", "/x.war", "/a/b", ""), Subapp("b", "/y.war", "/a#b", "")]);
  catch (Exception)
    dupDocBase = true;
  assert(dupDocBase);

  assert(validateSubapps([Subapp("a", "/x.war", "a/b/", "")]) == ["/a/b"]);
}

@("serverXml renders one context per subapp with libs") unittest {
  auto xml = serverXml("8080",
      [ContextSpec("/portal", "/b/webapps/portal", "a:b:1"),
       ContextSpec("/admin", "/b/webapps/admin", "")],
      "11", []);
  assert(xml.split("<Context ").length == 3);
  assert(xml.canFind(`<Context path="/portal" docBase="/b/webapps/portal">`));
  assert(xml.canFind(`<Context path="/admin" docBase="/b/webapps/admin">`));
  assert(xml.canFind(`libs="a:b:1"`));
  assert(xml.canFind(`useVirtualThreads="true"`));
}
