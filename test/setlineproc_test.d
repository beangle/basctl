/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/** Unit tests for bas.setlineproc（入口地址的解析与探测在 endpoint_test.d）。 */
module test.setlineproc_test;

import bas.setline : SetlineRoute;
import bas.setlineproc;

import core.stdc.errno : EINTR;
import core.thread : Thread;

import std.algorithm : canFind, splitter, startsWith;
import std.array : appender;
import std.conv : to;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel,
  SocketOSException, SocketType;
import std.string : indexOf, strip;

@("syncRoutesToSetline PUTs the whole route map to the admin port of the hostname") unittest {
  auto listener = new Socket(AddressFamily.INET, SocketType.STREAM);
  scope (exit) listener.close();
  listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
  listener.bind(new InternetAddress("127.0.0.1", 0));
  listener.listen(1);
  auto port = (cast(InternetAddress) listener.localAddress).port;

  string request;
  auto stub = new Thread({
    auto conn = acceptOne(listener);
    scope (exit) conn.close();
    request = readRequest(conn);
    conn.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
  });
  stub.start();
  auto code = syncRoutesToSetline([SetlineRoute("/tools", [19001])], port, "alice.localhost");
  stub.join();

  assert(code == 0, "push should report success on a 200");
  // 写接口只在管理口上、且只认本机：URL 里有命名空间，方法必须是 PUT（不是 POST）
  assert(request.startsWith("PUT /_setline/routes/all?host=alice.localhost HTTP/1.1\r\n"), request);
  assert(request.canFind("Content-Type: application/json"), request);
  // 整组路由一次推完，路径 -> 端口；单端口不包成数组
  assert(request.canFind(`{"routes":{`), request);
  assert(request.canFind(`"/tools": 19001`), request);
}

@("syncRoutesToSetline reports a missing setline instead of pretending it synced") unittest {
  // 挑一个刚空出来的端口：没人听的时候不拨号，也就没有第二次探测
  ushort freePort;
  foreach (attempt; 0 .. 5) {
    auto probe = new Socket(AddressFamily.INET, SocketType.STREAM);
    probe.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    probe.bind(new InternetAddress("127.0.0.1", 0));
    freePort = (cast(InternetAddress) probe.localAddress).port;
    probe.close();
    if (syncRoutesToSetline([], freePort, "localhost") != 0)
      return;
  }
  assert(false, "a just-closed port stayed busy across 5 attempts");
}

/**
 * 读到一个完整的 HTTP 请求（头 + `Content-Length` 说的那么多 body）。
 *
 * 请求可能分几段到达，所以按 body 长度判断读完了没有，不假设一次 `receive` 拿到全部。
 */
private string readRequest(Socket conn) {
  auto received = appender!string;
  auto buf = new ubyte[8192];
  while (true) {
    ptrdiff_t count;
    try {
      count = conn.receive(buf);
    } catch (SocketOSException e) {
      if (e.errorCode == EINTR)
        continue;
      throw e;
    }
    if (count == Socket.ERROR || count == 0)
      break;
    received.put(cast(string) buf[0 .. count]);
    auto text = received.data;
    auto headEnd = text.indexOf("\r\n\r\n");
    if (headEnd < 0)
      continue;
    if (text.length >= headEnd + 4 + contentLength(text[0 .. headEnd]))
      break;
  }
  return received.data;
}

/** `accept` 会被其它测试子进程的 SIGCHLD 打断；EINTR 只重试，不当作服务结束。 */
private Socket acceptOne(Socket listener) {
  while (true) {
    try {
      return listener.accept();
    } catch (SocketOSException e) {
      if (e.errorCode != EINTR)
        throw e;
    }
  }
}

/** 请求头里的 `Content-Length`（没写按 0）。 */
private int contentLength(string head) {
  foreach (line; head.splitter("\r\n")) {
    if (line.startsWith("Content-Length:"))
      return line["Content-Length:".length .. $].strip.to!int;
  }
  return 0;
}
