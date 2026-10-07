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

/** Unit tests for bas.endpoint：写法解析、探测，以及 `--endpoint` / `<setline endpoint>` 的取用顺序。 */
module test.endpoint_test;

import bas.endpoint;

import std.algorithm : canFind;
import std.exception : assertThrown;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketType;

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

@("resolveSetlineEndpoint takes --endpoint, then the config; no default to guess") unittest {
  // 配置：本 BAS_HOME 长期声明的那扇门，出处报 server.xml
  auto fromConfig = resolveSetlineEndpoint("", " 127.0.0.1:9100 ");
  assert(fromConfig.endpoint.toString() == "127.0.0.1:9100");
  assert(fromConfig.source == SetlineEndpointSource.serverXml);
  assert(sourceName(fromConfig.source) == "server.xml");

  // 命令行覆盖单次调用，比配置还优先
  auto fromFlag = resolveSetlineEndpoint(" 9200 ", "127.0.0.1:9100");
  assert(fromFlag.endpoint.port == 9200);
  assert(fromFlag.source == SetlineEndpointSource.endpointFlag);
  assert(sourceName(fromFlag.source) == "--endpoint");

  // 写法与 setline 的 listen 同构：裸端口落回环，* 只表示绑所有地址（拨的时候走回环）
  assert(resolveSetlineEndpoint("9000", "").endpoint.toString() == "127.0.0.1:9000");
  assert(resolveSetlineEndpoint("*:9000", "").endpoint.toString() == "*:9000");
  assert(probeHost(resolveSetlineEndpoint("*:9000", "").endpoint) == "127.0.0.1");

  // 两处都没写：报错，不替谁猜一个 8080
  assertThrown(resolveSetlineEndpoint("", ""));
  assertThrown(resolveSetlineEndpoint("  ", "  "));

  // 写法非法当场报错，而不是悄悄换个地址
  assertThrown(resolveSetlineEndpoint("nope", ""));
  assertThrown(resolveSetlineEndpoint("", "nope"));
}
