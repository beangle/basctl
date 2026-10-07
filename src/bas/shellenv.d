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
 * 工具环境：`BAS_HOME` 与从工作目录读 `conf/server.xml`。
 *
 * `BAS_HOME` 是所有 basctl 命令的共同输入（找 `conf/server.xml`、找 `servers/<name>/server.info`、
 * 决定 `conf/*.json` 写哪儿），所以解析它的入口放在这里，而不是散在各命令里。
 */
module bas.shellenv;

import bas.config;

import std.file : exists, getcwd, readText;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.string : strip;
import std.typecons : Nullable, nullable;

/** `BAS_HOME` 有值时取其指向目录，否则取当前工作目录。 */
string resolveBasHome() @trusted {
  auto fromEnv = strip(environment.get("BAS_HOME", ""));
  if (fromEnv.length)
    return absolutePath(fromEnv);
  return absolutePath(getcwd());
}

/** Reads `<workdir>/conf/server.xml`; returns null when the file is missing. */
Nullable!Container readContainer(string workdir) {
  auto target = buildPath(workdir, "conf", "server.xml");
  if (!exists(target))
    return Nullable!Container.init;
  return nullable(parseServerXml(readText(target)));
}
