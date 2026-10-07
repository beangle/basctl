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

/** Unit tests for bas.setlineproc. */
module test.setlineproc_test;

import bas.setlineproc;

import std.exception : assertThrown;
import std.path : buildPath;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketType;
import std.string : endsWith;

@("parseListenEndpoint follows setline's listen forms") unittest {
  auto bare = parseListenEndpoint("8080");
  assert(bare.host == "127.0.0.1");
  assert(bare.port == 8080);
  assert(bare.toString() == "127.0.0.1:8080");
  assert(probeHost(bare) == "127.0.0.1");

  auto wildcard = parseListenEndpoint("*:8080");
  assert(wildcard.host == "");
  assert(wildcard.port == 8080);
  assert(wildcard.toString() == "*:8080");
  assert(probeHost(wildcard) == "127.0.0.1");

  assert(parseListenEndpoint("127.0.0.1:9000").host == "127.0.0.1");
  assert(probeHost(parseListenEndpoint("0.0.0.0:9000")) == "127.0.0.1");
  assert(probeHost(parseListenEndpoint("10.0.0.1:9000")) == "10.0.0.1");
}

@("parseListenEndpoint rejects invalid ports") unittest {
  assertThrown(parseListenEndpoint("0"));
  assertThrown(parseListenEndpoint("65536"));
  assertThrown(parseListenEndpoint("abc"));
  assertThrown(parseListenEndpoint("*:"));
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
    assert(!portFree(ListenEndpoint("127.0.0.1", port)));

    sock.close();
    if (portFree(ListenEndpoint("127.0.0.1", port)))
      return;
  }
  assert(false, "a just-closed port stayed busy across 5 attempts");
}

@("pidFile lives under run/") unittest {
  assert(pidFile("/opt/bas").endsWith("setline.pid"));
  assert(pidFile("/opt/bas") == buildPath("/opt/bas", "run", "setline.pid"));
}

@("parseWatchInterval accepts positive seconds and rejects the rest") unittest {
  assert(parseWatchInterval("5") == 5);
  assert(parseWatchInterval(" 30 ") == 30);
  assertThrown(parseWatchInterval("0"));
  assertThrown(parseWatchInterval("-1"));
  assertThrown(parseWatchInterval("abc"));
  assert(defaultWatchIntervalSec > 0);
}
