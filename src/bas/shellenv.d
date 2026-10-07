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

/** 从工作目录读取 `conf/server.xml`。 */
module bas.shellenv;

import bas.config;

import std.file : exists, readText;
import std.path : buildPath;
import std.typecons : Nullable, nullable;

/** Reads `<workdir>/conf/server.xml`; returns null when the file is missing. */
Nullable!Container readContainer(string workdir) {
  auto target = buildPath(workdir, "conf", "server.xml");
  if (!exists(target))
    return Nullable!Container.init;
  return nullable(parseServerXml(readText(target)));
}
