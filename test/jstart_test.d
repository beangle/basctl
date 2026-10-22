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

/** Unit tests for bas.jstart. */
module test.jstart_test;

import bas.jstart;

import std.typecons : Nullable, nullable;

@("build args keeps official and snapshot remotes separate") unittest {
  auto args = buildArgs("jstart", "resolve", "g:a:1", nullable("/repo"),
      ["release-key-a@https://a", "https://b"], false, []);
  assert(args == ["jstart", "resolve", "g:a:1", "--local=/repo",
      "--remote=release-key-a@https://a,https://b"]);

  auto snap = buildArgs("jstart", "fetch", "g:a:1-SNAPSHOT", Nullable!string.init, [],
      true, ["snapshot-key@https://snap"]);
  assert(snap == ["jstart", "fetch", "g:a:1-SNAPSHOT",
      "--snapshot-remote=snapshot-key@https://snap", "--offline"]);
}

@("quiet snapshot fetch suppresses jstart diagnostics") unittest {
  auto args = buildArgs("jstart", "fetch", "g:a:1-SNAPSHOT", Nullable!string.init, [],
      false, ["snapshot-key@https://snap"], true);
  assert(args == ["jstart", "fetch", "g:a:1-SNAPSHOT",
      "--snapshot-remote=snapshot-key@https://snap", "--quiet"]);
}

@("last line skips trailing blanks") unittest {
  assert(lastLine("/repo/g/a/1/a-1.jar\n\n").get == "/repo/g/a/1/a-1.jar");
  assert(lastLine("").isNull);
}
