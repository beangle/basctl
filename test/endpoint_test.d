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

/** Unit tests for bas.endpoint：端口解析、拨号地址，以及 `<setline port>` 是唯一来源这件事。 */
module test.endpoint_test;

import bas.endpoint;

import std.algorithm : canFind;
import std.exception : assertThrown;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketType;

@("adminAddress is the loopback dial address of the admin port") unittest {
  assert(adminAddress(10080) == "127.0.0.1:10080");
}

@("parseSetlinePort takes a bare port and rejects everything else") unittest {
  assert(parseSetlinePort("10080") == 10080);
  assert(parseSetlinePort(" 8080 ") == 8080);
  assert(parseSetlinePort("65535") == 65535);

  assertThrown(parseSetlinePort("0"));
  assertThrown(parseSetlinePort("65536"));
  assertThrown(parseSetlinePort("abc"));
  // 管理口只认回环来的写，所以 host:port / *:port 这类写法没有可配的余地
  assertThrown(parseSetlinePort("127.0.0.1:8080"));
  assertThrown(parseSetlinePort("*:8080"));
}

@("portFree reflects whether something is listening") unittest {
  // 用例与别的用例并行跑，端口是共享资源：刚释放的端口有可能被别的用例抢走，换一个再试。
  foreach (attempt; 0 .. 5) {
    auto sock = new Socket(AddressFamily.INET, SocketType.STREAM);
    scope (exit) sock.close();
    sock.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    sock.bind(new InternetAddress("127.0.0.1", 0));
    sock.listen(1);

    auto port = (cast(InternetAddress) sock.localAddress).port;
    assert(!portFree(port));

    sock.close();
    if (portFree(port))
      return;
  }
  assert(false, "a just-closed port stayed busy across 5 attempts");
}

@("resolveSetlinePort reads <setline port> only; no default to guess") unittest {
  // 配置是本 BAS_HOME 声明管理口的唯一地方，前后空白由解析吃掉
  assert(resolveSetlinePort(" 10080 ") == 10080);

  // 没写：报错，不替谁猜一个 10080
  assertThrown(resolveSetlinePort(""));
  assertThrown(resolveSetlinePort("  "));

  // 写法非法当场报错，而不是悄悄换个端口
  assertThrown(resolveSetlinePort("nope"));
  assertThrown(resolveSetlinePort("127.0.0.1:10080"));
}
