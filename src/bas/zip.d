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

/** zip / war 解包。 */
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

/** 判断 war 是否包含 `WEB-INF/lib/*.jar`。 */
bool warHasLibs(string warPath) {
  auto zip = new ZipArchive(cast(ubyte[]) read(warPath));
  foreach (name, member; zip.directory) {
    if (name.startsWith("WEB-INF/lib/") && name.endsWith(".jar"))
      return true;
  }
  return false;
}
