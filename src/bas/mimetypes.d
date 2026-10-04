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

/**
 * `mime.types` 解析。
 *
 * 每行形如 `type=<mime> ... exts=<逗号分隔的扩展名>`；注释行以 `#` 开头。
 * 结果同时包含扩展名和完整 mime 名两类键。
 */
module bas.mimetypes;

import std.string : indexOf, split, startsWith, strip;

/** 一个 mime 映射键值对（键可能是扩展名，也可能是完整 mime 名）。 */
struct MimeEntry {
  string key;
  string mimeType;
}

/** Parses mime.types text into entries in file order. */
MimeEntry[] parseMimeTypes(string text) {
  MimeEntry[] entries;
  foreach (raw; text.split("\n")) {
    auto line = strip(raw);
    if (line.length == 0 || line.startsWith("#"))
      continue;

    auto typeStart = line.indexOf("type=");
    auto extsStart = line.indexOf("exts=");
    if (typeStart < 0 || extsStart < 0)
      continue;

    auto mimeType = strip(line[typeStart + 5 .. extsStart]);
    if (!mimeType.length)
      continue;
    entries ~= MimeEntry(mimeType, mimeType);

    foreach (ext; line[extsStart + 5 .. $].split(",")) {
      auto extension = strip(ext);
      if (extension.length)
        entries ~= MimeEntry(extension, mimeType);
    }
  }
  return entries;
}
