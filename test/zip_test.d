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

/** Unit tests for bas.zip. */
module test.zip_test;

import bas.zip : unzipInto, warHasLibs;

import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.string : representation;
import std.uuid : randomUUID;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

/** Test helper: write a zip with the given `[name, content]` entries. */
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

@("unzip writes nested entries") unittest {
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
