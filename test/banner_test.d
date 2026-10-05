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

/** Unit tests for bas.banner. */
module test.banner_test;

import bas.banner;

import std.algorithm : canFind;
import std.array : split;
import std.string : endsWith, stripRight;

@("asciiLogo renders the bas figure in pure ASCII") unittest {
  auto art = asciiLogo();
  assert(art.canFind("(  _ \\"), "should read bas, not sas");
  assert(art.endsWith("(__)(__)(___/"));
  // 纯图形，尾部不带换行，版本行由 banner 拼接；每行不留行尾空白
  auto lines = art.split('\n');
  assert(lines.length == 4);
  foreach (line; lines) {
    assert(line == line.stripRight);
    foreach (ch; line)
      assert(ch < 128, "logo must stay in ASCII");
  }
}

@("banner shows both versions and hosts") unittest {
  auto text = banner("0.0.1", "0.14.0", false);
  assert(text.canFind("bas 0.14.0"));
  assert(text.canFind("basctl 0.0.1"));
  assert(text.canFind("hosts:"));
  // 重定向时第一行就是版本行，便于日志里 grep
  assert(text.split('\n')[0].canFind("bas 0.14.0"));
}

@("banner without server.xml only shows basctl") unittest {
  auto text = banner("0.0.1", "", false);
  assert(text.canFind("basctl 0.0.1"));
  assert(!text.canFind("bas 0.14.0"));
}

@("banner prints the logo on an interactive terminal") unittest {
  auto text = banner("0.0.1", "0.14.0", true);
  assert(text.canFind("(____/"));
  assert(text.canFind("basctl 0.0.1"));
}
