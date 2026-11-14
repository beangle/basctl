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

/** Unit tests for bas.remote URL construction and bas.pull's command behavior. */
module test.pull_test;

import bas.pull : runPull;
import bas.remote : RemoteConfig, serverConfigUrl;
import std.process : environment;

import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

@("server config URL follows bashub's config capability route") unittest {
  assert(serverConfigUrl(RemoteConfig("https://control.example", "openurp.prod", "k"))
      == "https://control.example/api/bashub/config/openurp.prod/server");
  assert(serverConfigUrl(RemoteConfig("https://control.example/", "openurp.prod", "k"))
      == "https://control.example/api/bashub/config/openurp.prod/server");
}

@("server config URL keeps a reverse-proxy prefix") unittest {
  assert(serverConfigUrl(RemoteConfig("https://control.example/bashub/", "openurp.prod", "k"))
      == "https://control.example/bashub/api/bashub/config/openurp.prod/server");
}
