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

/** 本机地址枚举。 */
module bas.net;

import std.algorithm : canFind;
import std.format : format;

/**
 * 返回 `127.0.0.1` 与本机所有非回环 IPv4 地址。
 *
 * Maker 用它判断某个 `<server>` 是否部署在本机。非 Linux 平台退化为只返回回环地址。
 */
string[] localAddresses() {
  string[] result = ["127.0.0.1"];
  version (linux) {
    import core.sys.linux.ifaddrs : freeifaddrs, getifaddrs, ifaddrs;
    import core.sys.posix.netinet.in_ : AF_INET, sockaddr_in;
    import core.sys.posix.sys.socket : sockaddr;

    enum IFF_UP = 0x1;
    enum IFF_LOOPBACK = 0x8;

    ifaddrs* head;
    if (getifaddrs(&head) != 0)
      return result;
    scope (exit) freeifaddrs(head);

    for (auto cur = head; cur !is null; cur = cur.ifa_next) {
      if (cur.ifa_addr is null)
        continue;
      if ((cur.ifa_flags & IFF_UP) == 0 || (cur.ifa_flags & IFF_LOOPBACK) != 0)
        continue;
      if (cur.ifa_addr.sa_family != AF_INET)
        continue;
      auto sa = cast(sockaddr_in*) cur.ifa_addr;
      auto raw = sa.sin_addr.s_addr;
      auto dotted = format!"%d.%d.%d.%d"(raw & 0xff, (raw >> 8) & 0xff, (raw >> 16) & 0xff, (raw >> 24) & 0xff);
      if (!result.canFind(dotted))
        result ~= dotted;
    }
  }
  return result;
}
