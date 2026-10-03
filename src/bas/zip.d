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

/** zip / war 解包（替代 Scala 的 `org.beangle.commons.file.zip.Zipper`）。 */
module bas.zip;

import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath, dirName;
import std.string : endsWith, startsWith;
import std.zip : ZipArchive;

/**
 * Extracts every entry of `zipPath` under `destDir`, creating parent directories.
 *
 * 目录条目（以 `/` 结尾）会被跳过；条目名按 zip 内的相对路径拼接。
 */
void unzipInto(string zipPath, string destDir) {
  auto zip = new ZipArchive(cast(ubyte[]) read(zipPath));
  foreach (name, member; zip.directory) {
    if (name.endsWith("/"))
      continue;
    auto target = buildPath(destDir, name);
    mkdirRecurse(dirName(target));
    write(target, zip.expand(member));
  }
}

/** Whether the war contains any `WEB-INF/lib/*.jar`（Scala `isLibEmpty` 的反义）。 */
bool warHasLibs(string warPath) {
  auto zip = new ZipArchive(cast(ubyte[]) read(warPath));
  foreach (name, member; zip.directory) {
    if (name.startsWith("WEB-INF/lib/") && name.endsWith(".jar"))
      return true;
  }
  return false;
}

version (unittest) {
  import std.string : representation;
  import std.zip : ArchiveMember, CompressionMethod;

  private void writeZip(string path, string[][] entries) {
    auto zip = new ZipArchive();
    foreach (e; entries) {
      auto m = new ArchiveMember();
      m.name = e[0];
      m.expandedData(cast(ubyte[]) e[1].dup.representation);
      m.compressionMethod = CompressionMethod.deflate;
      zip.addMember(m);
    }
    write(path, zip.build());
  }
}

@("unzip writes nested entries") unittest {
  import std.file : readText, rmdirRecurse, tempDir;
  import std.path : buildPath;
  import std.uuid : randomUUID;

  auto root = buildPath(tempDir, "basctl-zip-" ~ randomUUID().toString());
  scope (exit) {
    if (exists(root))
      rmdirRecurse(root);
  }
  mkdirRecurse(root);
  auto archive = buildPath(root, "t.zip");
  writeZip(archive, [["a.txt", "hello"], ["sub/b.txt", "world"]]);

  auto outDir = buildPath(root, "out");
  unzipInto(archive, outDir);
  assert(readText(buildPath(outDir, "a.txt")) == "hello");
  assert(readText(buildPath(outDir, "sub/b.txt")) == "world");
}

@("warHasLibs detects WEB-INF/lib jars") unittest {
  import std.file : rmdirRecurse, tempDir;
  import std.path : buildPath;
  import std.uuid : randomUUID;

  auto root = buildPath(tempDir, "basctl-war-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) {
    if (exists(root))
      rmdirRecurse(root);
  }
  auto withLib = buildPath(root, "with.war");
  writeZip(withLib, [["WEB-INF/web.xml", "<x/>"], ["WEB-INF/lib/a.jar", "j"]]);
  auto withoutLib = buildPath(root, "without.war");
  writeZip(withoutLib, [["WEB-INF/web.xml", "<x/>"]]);
  assert(warHasLibs(withLib));
  assert(!warHasLibs(withoutLib));
}
