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

/** Unit tests for bas.resolver. */
module test.resolver_test;

import bas.resolver;

@("parse gav lists") unittest {
  auto a = parseGavs("g1:a1:1; g2:a2:2,\n g3:a3:war:3");
  assert(a.length == 3);
  assert(a[0].asGav() == "g1:a1:1");
  assert(a[2].packaging == "war");
  assert(parseGavs("  ").length == 0);
}

@("resolvable recognizes archives and dirs") unittest {
  assert(resolvable("/tmp/a.jar"));
  assert(resolvable("/tmp/a.war"));
  assert(!resolvable("/tmp/a.txt"));
}
