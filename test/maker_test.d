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

module test.maker_test;

import bas.config;
import bas.fsutil;
import bas.tomcatmaker;

import std.algorithm.searching : canFind;
import std.file;
import std.format : format;
import std.path : buildPath;
import std.string : representation;
import std.uuid : randomUUID;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

private void writeWar(string path) {
  auto zip = new ZipArchive();
  foreach (entry; [["WEB-INF/web.xml", "<web-app/>"], ["WEB-INF/lib/foo.jar", "jar"]]) {
    auto member = new ArchiveMember();
    member.name = entry[0];
    member.expandedData(cast(ubyte[]) entry[1].dup.representation);
    member.compressionMethod = CompressionMethod.deflate;
    zip.addMember(member);
  }
  write(path, zip.build());
}

@("doMakeBase builds server home with links and generated config") unittest {
  auto root = buildPath(tempDir, "basctl-make-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) removeTree(root);

  auto engineDir = buildPath(root, "engines", "tomcat-9.0.1");
  mkdirRecurse(buildPath(engineDir, "lib"));
  mkdirRecurse(buildPath(engineDir, "conf"));
  mkdirRecurse(buildPath(engineDir, "bin"));
  write(buildPath(engineDir, "conf", "catalina.properties"), "x=1\n");
  write(buildPath(engineDir, "bin", "bootstrap.jar"), "");

  auto war = buildPath(root, "app.war");
  writeWar(war);

  auto cfg = parseServerXml(format!`<Sas version="1">
      <Engines><Engine name="tomcat" type="tomcat" version="9.0.1"/></Engines>
      <Farms><Farm name="f" engine="tomcat"><Server name="s" http="8080"/></Farm></Farms>
      <Webapps><Webapp uri="%s" runAt="f" path="/"/></Webapps>
    </Sas>`(war));
  // Resolver 在 Maker 之前写入 docBase；这里直接模拟其结果。
  cfg.webapps[0].docBase = war;
  auto server = cfg.farms[0].servers[0];
  doMakeBase(root, cfg, server);

  auto base = buildPath(root, "servers", "f.s");
  assert(isLink(buildPath(base, "lib")));
  assert(isLink(buildPath(base, "logs")));
  assert(isLink(buildPath(base, "conf", "catalina.properties")));
  assert(exists(buildPath(base, "bin", "setenv.sh")));

  auto serverXml = readText(buildPath(base, "conf", "server.xml"));
  assert(serverXml.canFind(`<Context path=""`));
  assert(serverXml.canFind(`port="8080"`));
  assert(serverXml.canFind(buildPath(base, "webapps", "ROOT")), serverXml);

  auto setenv = readText(buildPath(base, "bin", "setenv.sh"));
  assert(setenv.canFind("-Xmx300M"));

  assert(exists(buildPath(base, "webapps", "ROOT", "WEB-INF", "web.xml")));
  assert(exists(buildPath(base, "webapps", "ROOT", "WEB-INF", "lib", "foo.jar")));
}

@("applyEngineDefault fills tomcat defaults once") unittest {
  auto cfg = parseServerXml(`<Sas version="0.13.9">
      <Engines><Engine name="tomcat" type="tomcat" version="11.0.5"/></Engines>
      <Farms><Farm name="f" engine="tomcat"><Server name="s" http="8080"/></Farm></Farms>
    </Sas>`);
  auto engine = cfg.engines[0];
  applyEngineDefault(cfg, engine);
  assert(engine.listeners.length == 2);
  assert(engine.context !is null);
  assert(engine.context.loader.className == "org.beangle.sas.engine.tomcat.ExtendableWebappLoader");
  assert(engine.context.jarScanner.properties["scanClassPath"] == "false");
  assert(engine.jars.length == 1);
  assert(engine.jars[0].uri == "gav://org.beangle.sas:beangle-sas-engine:0.13.9");
}
