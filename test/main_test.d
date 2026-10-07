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

/** Unit tests for bas.main status rendering (setline config helpers live in setlineproc_test). */
module test.main_test;

import bas.config : Container, parseServerXml;
import bas.main : setlineStatusLines, staleStatusLine, statusLines;
import bas.serverinfo : ServerInfo, WebappInfo;

import core.thread : Thread;

import std.algorithm : canFind;
import std.conv : to;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel,
  SocketType;
import std.typecons : nullable;

@("statusLines shows identity plus one line per webapp") unittest {
  ServerInfo info;
  info.id = "platform.server1";
  info.engine = "tomcat-server-11.0.26";
  info.httpPort = 20001;
  info.started = "2026-10-07T10:12:33+08:00";
  info.pid = 23145;
  info.webapps ~= WebappInfo("portal", "gav://org.beangle.ems:beangle-ems-portal:4.20.13",
      "/portal", []);
  info.webapps ~= WebappInfo("ROOT", "gav://org.beangle.otk:beangle-otk-ws:war:0.0.30", "/",
      ["/context1", "/context2"]);

  auto lines = statusLines(info);
  assert(lines.length == 3);
  assert(lines[0] == "platform.server1(pid=23145 port=20001 engine=tomcat-server-11.0.26"
      ~ " started=2026-10-07T10:12:33+08:00)");
  // 未声明 <url> 的 webapp 不写 urls（对外走 context），声明了的列出来
  assert(lines[1] == "  /portal  gav://org.beangle.ems:beangle-ems-portal:4.20.13");
  assert(lines[2] == "  /        gav://org.beangle.otk:beangle-otk-ws:war:0.0.30"
      ~ "  urls=/context1,/context2");
}

@("staleStatusLine marks run info left behind by a dead process") unittest {
  ServerInfo info;
  info.id = "platform.server2";
  info.httpPort = 20002;
  info.pid = 999;
  assert(staleStatusLine(info, "platform.server2") == "platform.server2(stale pid=999 port=20002)");

  info.id = "";
  info.pid = 0;
  assert(staleStatusLine(info, "platform.server2") == "platform.server2(stale port=20002)");
}

@("setlineStatusLines reports the namespace, the endpoint and whether it answers") unittest {
  // 用例与别的用例并行跑，端口是共享资源：刚释放的端口可能被别的用例抢走，所以换一个端口重试。
  string endpoint;
  bool down;
  foreach (attempt; 0 .. 5) {
    auto probe = new Socket(AddressFamily.INET, SocketType.STREAM);
    probe.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    probe.bind(new InternetAddress("127.0.0.1", 0));
    endpoint = "127.0.0.1:" ~ (cast(InternetAddress) probe.localAddress).port.to!string;
    probe.close();
    if (setlineStatusLines(setlineContainer("alice.localhost", endpoint), [])
        == ["host=alice.localhost endpoint=" ~ endpoint ~ " (down)"]) {
      down = true;
      break;
    }
  }
  assert(down, "no probed port stayed free long enough to observe 'down'");

  // 入口有人监听：报 up，route 列如实说"读不动"。不判断坐的是不是我们的 setline——status 只读，
  // 不做带副作用的写探测。这里接一下就连关，让 curl 立刻失败，不必等它的 --max-time。
  auto listener = new Socket(AddressFamily.INET, SocketType.STREAM);
  scope (exit) listener.close();
  listener.bind(new InternetAddress("127.0.0.1", 0));
  listener.listen(1);
  auto upEndpoint = "127.0.0.1:" ~ (cast(InternetAddress) listener.localAddress).port.to!string;
  auto acceptor = new Thread({
    listener.accept().close();
  });
  acceptor.start();
  auto upLines = setlineStatusLines(setlineContainer("alice.localhost", upEndpoint), []);
  acceptor.join();
  assert(upLines.length == 2, upLines.to!string);
  assert(upLines[0] == "host=alice.localhost endpoint=" ~ upEndpoint ~ " (up)", upLines[0]);
  assert(upLines[1].canFind("routes:") && upLines[1].canFind("cannot reach setline"), upLines[1]);

  // 401（setline 的非本机读要 token）：如实报凭据墙，不当成 down、也不当成"没对上账"
  auto authListener = new Socket(AddressFamily.INET, SocketType.STREAM);
  scope (exit) authListener.close();
  authListener.bind(new InternetAddress("127.0.0.1", 0));
  authListener.listen(1);
  auto authEndpoint = "127.0.0.1:" ~ (cast(InternetAddress) authListener.localAddress).port.to!string;
  auto denier = new Thread({
    auto conn = authListener.accept();
    conn.send("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
    conn.close();
  });
  denier.start();
  auto denied = setlineStatusLines(setlineContainer("alice.localhost", authEndpoint), []);
  denier.join();
  assert(denied.length == 2, denied.to!string);
  assert(denied[1].canFind("wants adminToken for non-local reads"), denied[1]);

  // 没配 <setline> 时整节省略（不启用就没有地址，也不报错）
  assert(setlineStatusLines(parseServerXml(`<bas version="1"><engines/></bas>`), []).length == 0);
  // hostname 缺省 localhost；入口没人听时状态行照样只有一行，不拨号
  assert(setlineStatusLines(
      parseServerXml(`<bas version="1"><setline endpoint="` ~ endpoint ~ `"/><engines/></bas>`), [])
      == ["host=localhost endpoint=" ~ endpoint ~ " (down)"]);
}

@("setlineStatusLines reports a missing address instead of throwing") unittest {
  // 配置校验已经保证"有 <setline> 就有 endpoint"；这条守的是手工构造的容器（公开 API），
  // 缺地址时也要有个说得清的结果，而不是抛异常。
  auto container = new Container();
  container.setlineHostname = nullable("localhost");
  auto lines = setlineStatusLines(container, []);
  assert(lines.length == 1 && lines[0].canFind("host=localhost")
      && lines[0].canFind("No setline entry address"), lines.to!string);
}

/** 一份带 `<setline>`（有 `<setline>` 就得有 `endpoint`）的最小可解析配置。 */
private auto setlineContainer(string hostname, string endpoint) {
  return parseServerXml(`<bas version="1">
    <setline hostname="` ~ hostname ~ `" endpoint="` ~ endpoint ~ `"/>
    <engines><engine name="t" type="tomcat" version="11"/></engines>
    <farms><farm name="f" engine="t"><server name="s1" http="0"/></farm></farms>
  </bas>`);
}
