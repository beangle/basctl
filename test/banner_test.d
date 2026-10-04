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

@("logo renders bas and version") unittest {
  assert(logo("1.2.3").length > 1);
  assert(logo("1.2.3").canFind("(  _ \\"));
  assert(logo("1.2.3").canFind("version 1.2.3"));
}
