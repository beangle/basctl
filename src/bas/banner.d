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

/** 版本横幅与主机地址。 */
module bas.banner;

import bas.net;

import std.algorithm : sort;
import std.array : join;
import std.conv : text;

/** basctl 的 logo。 */
string logo(string version_) {
  return text(
i` ____    __    ___
(  _ \  /__\  / __)
 ) _ < /(__)\ \__ \
(____/(__)(__)(___/
version $(version_)`);
}

/** 所有本机地址，排序后以逗号连接。 */
string hostsLine() {
  auto addresses = localAddresses();
  addresses.sort();
  return "hosts:" ~ addresses.join(",");
}
