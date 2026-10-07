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

/** 本机地址枚举与端口探测。 */
module bas.net;

import std.algorithm : canFind;
import std.format : format;
import std.socket : Socket, SocketOption, SocketOptionLevel, SocketType, parseAddress;

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

/**
 * 能否独占绑定 `host:port` 一次（随即释放）：能就说明没有进程在监听。
 *
 * 用绑定探测而不是「连一下试试」：连接成功只能说明有东西在，连接失败却可能是超时、防火墙或对端
 * 拒绝；而 `bind` 失败（EADDRINUSE）是「有人听着」的确定性答案。SO_REUSEADDR 让上次的
 * TIME_WAIT 残留不妨碍判断——那种情况下确实可以重新监听。
 *
 * `host` 为空表示所有地址（`0.0.0.0`）；系统调用失败一律当作「不可用」（保守）。
 */
bool canBindPort(string host, ushort port) @trusted {
  Socket sock;
  try {
    auto addr = parseAddress(host.length ? host : "0.0.0.0", port);
    sock = new Socket(addr.addressFamily, SocketType.STREAM);
    sock.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    sock.bind(addr);
    return true;
  }
  catch (Exception) {
    return false;
  }
  finally {
    if (sock !is null)
      sock.close();
  }
}
