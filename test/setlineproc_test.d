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

/** Unit tests for bas.setlineproc（入口地址的解析与探测在 endpoint_test.d）。 */
module test.setlineproc_test;

import bas.setlineproc;

import std.exception : assertThrown;

@("parseWatchInterval accepts positive seconds and rejects the rest") unittest {
  assert(parseWatchInterval("5") == 5);
  assert(parseWatchInterval(" 30 ") == 30);
  assertThrown(parseWatchInterval("0"));
  assertThrown(parseWatchInterval("-1"));
  assertThrown(parseWatchInterval("abc"));
  assert(defaultWatchIntervalSec > 0);
}
