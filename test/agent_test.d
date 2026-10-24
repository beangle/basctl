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

/**
 * `bas.agent` 的测试：协议的编解码在 channel_test.d，这里测「真的拨号」与「真的读日志」。
 *
 * `report` 那条路要一个真的 WebSocket 对端才测得出来——凭证在握手里、路径在 URL 里、报文在帧里，
 * mock 掉哪一段都测不到真问题。所以这里用 {@link FakeHub} 手搓一个最小服务端（握手 + 文本帧），
 * 跑真的 `runReport`。手搓而不用 vibe：假 hub 得跑在另一个线程上阻塞等着 agent 来连，而事件循环
 * 在主线程里——两边各用各的 socket，互不打扰。
 */
module test.agent_test;

import bas.agent : agentLogResult, channelEnabled, logReadResult, runAgent, runReport, serviceResult;
import bas.channel : Envelope, parseEnvelope;
import bas.remote : loadRemoteConf;

import core.thread : Thread;
import core.time : dur;

import std.algorithm : canFind, startsWith;
import std.array : appender, join;
import std.base64 : Base64;
import std.conv : to;
import std.digest.sha : sha1Of;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel,
  SocketType;
import std.string : indexOf, representation, strip;
import std.uuid : randomUUID;

@("report dials the hub with the profile key and sends hello plus both reports") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-e2e");
  mkdirRecurse(buildPath(home, "conf"));
  auto configFile = buildPath(home, "conf", "server.xml");

  auto hub = new FakeHub();
  write(configFile, "<bas version=\"0.14.0\"/>");
  write(buildPath(home, "conf", "basctl.conf"), "[remote]\nurl = http://127.0.0.1:"
      ~ hub.port.to!string ~ "\nproject = demo.prod\ntoken = k1\n");

  auto serving = new Thread({ hub.serve(); });
  serving.start();
  auto code = runReport(configFile, "0.0.0-test", []);
  serving.join();

  assert(code == 0, "one-shot report should exit cleanly");
  // 路径里的 profile 与凭证都在握手里：hub 靠这两样认「这是哪台机器」
  assert(hub.request.startsWith(
      "GET /api/bashub/monitor/agents/demo.prod/channel HTTP/1.1\r\n"), hub.request);
  assert(hub.request.canFind("Authorization: Bearer demo.prod:k1"), hub.request);
  assert(hub.request.canFind("Upgrade: websocket"), hub.request);

  // 三条：hello（身份与能力）+ 两份上报（整份替换语义）
  assert(hub.messages.length == 3, hub.messages.join("\n"));
  auto hello = parseEnvelope(hub.messages[0]);
  assert(hello.type == "hello", hub.messages[0]);
  assert(!hello.id.length, "hello 是通知，不带 id");
  assert(hello.body["supports"].array.canFind(JSONValue("report:os")), hub.messages[0]);
  assert(hello.body["supports"].array.canFind(JSONValue("log:read")), hub.messages[0]);
  assert(hello.body["supports"].array.canFind(JSONValue("service:restart")), hub.messages[0]);
  assert(hello.body["basctl"].str == "0.0.0-test", hub.messages[0]);
  assert(hello.body["bas"].str == "0.14.0", hub.messages[0]);

  auto os = parseEnvelope(hub.messages[1]);
  assert(os.type == "report:os", hub.messages[1]);
  assert(("cpu" in os.body.object) !is null, hub.messages[1]);

  auto bas = parseEnvelope(hub.messages[2]);
  assert(bas.type == "report:bas", hub.messages[2]);
  assert(("instances" in bas.body.object) !is null, hub.messages[2]);
  assert(("declared" in bas.body.object) !is null, hub.messages[2]);
}

@("channel is enabled only by a complete basctl.conf [remote] section") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-switch-" ~ randomUUID().toString);
  mkdirRecurse(buildPath(home, "conf"));
  auto configFile = buildPath(home, "conf", "server.xml");
  auto remoteFile = buildPath(home, "conf", "basctl.conf");
  write(configFile, "<bas version=\"0.14.0\"/>");
  assert(!channelEnabled(loadRemoteConf(remoteFile)), "没有 basctl.conf 就不该拨号");
  write(remoteFile, "[remote]\nurl = http://127.0.0.1:8080\nproject = demo\n");
  assert(!channelEnabled(loadRemoteConf(remoteFile)), "缺 token 不启用");

  write(remoteFile, "[remote]\nurl = http://127.0.0.1:8080\nproject = demo\ntoken = k1\n");
  assert(channelEnabled(loadRemoteConf(remoteFile)), "三项齐全就是启用");
}

@("agent warns and exits cleanly when remote is not configured") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-unconfigured-" ~ randomUUID().toString);
  mkdirRecurse(buildPath(home, "conf"));
  auto configFile = buildPath(home, "conf", "server.xml");
  write(configFile, "<bas version=\"0.14.0\"/>");

  assert(runAgent(configFile, "0.0.0-test", []) == 0);
}

@("logReadResult reads a window out of the instance console log") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-log");
  mkdirRecurse(buildPath(home, "logs", "tools.server1"));
  write(buildPath(home, "logs", "tools.server1", "console.out"),
      "one\ntwo\nthree\nfour\nfive\n".representation);

  auto request = parseJSON(`{"instance":"tools.server1","from":2,"to":4}`);
  auto reply = parseEnvelope(logReadResult(home, "r1", request));
  assert(reply.type == "result", reply.type);
  assert(reply.id == "r1", reply.id);
  assert(reply.body["ok"].type == JSONValue(true).type, "read should succeed");
  auto data = reply.body["data"];
  assert(data["total"].integer == 5, "total 是文件总行数，控制台据此翻页");
  assert(data["from"].integer == 2, data["from"].toString());
  assert(data["to"].integer == 4, "to 是实际读到的末行，不是请求里的");
  assert(data["lines"].array.length == 3, data["lines"].toString());
  assert(data["lines"].array[0].str == "two", data["lines"].toString());

  // SPA 的 tail -f：首次只取最后两行，之后客户端可以用 to+1 继续增量读
  auto tailRequest = parseJSON(`{"instance":"tools.server1","tail":2}`);
  auto tailReply = parseEnvelope(logReadResult(home, "r1-tail", tailRequest));
  auto tailData = tailReply.body["data"];
  assert(tailData["total"].integer == 5, tailData.toString());
  assert(tailData["from"].integer == 4, tailData.toString());
  assert(tailData["to"].integer == 5, tailData.toString());
  assert(tailData["lines"].array[0].str == "four", tailData.toString());
  assert(tailData["lines"].array[1].str == "five", tailData.toString());
}

@("logReadResult refuses to walk out of the log directory") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-trap");
  mkdirRecurse(buildPath(home, "logs"));
  write(buildPath(home, "secret.txt"), "seen".representation);

  // 实例名是目录名不是路径：带分隔符、`.` / `..`、空串一律拒——否则控制台能借日志接口读任意文件
  foreach (name; ["../../etc/passwd", "a/b", "..", "", "."]) {
    auto request = parseJSON(`{"instance":` ~ JSONValue(name).toString() ~ `}`);
    auto reply = parseEnvelope(logReadResult(home, "r2", request));
    assert(reply.body["ok"].type != JSONValue(true).type, name);
    assert(reply.body["error"].str == "bad-request", name ~ " -> " ~ reply.body["error"].str);
  }

  // 名字合法但没这个实例：不是「读了个空」，而是明说没有
  auto missing = parseJSON(`{"instance":"ghost.server1"}`);
  auto reply = parseEnvelope(logReadResult(home, "r3", missing));
  assert(reply.body["error"].str == "no-log", reply.body["error"].str);
}

@("agentLogResult reads the agent console without an instance name") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-own-log-" ~ randomUUID().toString);
  mkdirRecurse(buildPath(home, "logs", "agent"));
  write(buildPath(home, "logs", "agent", "console.out"), "hello\nworld\n".representation);

  auto request = parseJSON(`{"tail":1}`);
  auto reply = parseEnvelope(agentLogResult(home, "a1", request));
  assert(reply.body["ok"].boolean, reply.body.toString());
  assert(reply.body["data"]["total"].integer == 2, reply.body.toString());
  assert(reply.body["data"]["lines"].array[0].str == "world", reply.body.toString());
}

@("serviceResult rejects bad requests and unknown instances without touching the host") unittest {
  auto home = buildPath(tempDir(), "basctl-agent-service");
  mkdirRecurse(buildPath(home, "conf"));
  auto configFile = buildPath(home, "conf", "server.xml");
  write(configFile, "<bas version=\"0.14.0\"><engines/><farms/></bas>");

  auto bad = parseJSON(`{"instance":"../etc/passwd"}`);
  auto reply = parseEnvelope(serviceResult(configFile, "r1", "restart", bad));
  assert(!reply.body["ok"].boolean, reply.body.toString());
  assert(reply.body["error"].str == "bad-request", reply.body.toString());

  auto missing = parseJSON(`{"instance":"platform.server1"}`);
  reply = parseEnvelope(serviceResult(configFile, "r2", "stop", missing));
  assert(!reply.body["ok"].boolean, reply.body.toString());
  assert(reply.body["error"].str == "no-instance", reply.body.toString());

  write(configFile, `<bas version="0.14.0">
    <engines><engine name="t" type="tomcat" version="11"/></engines>
    <hosts><host name="remote" ip="192.0.2.1"/></hosts>
    <farms><farm name="platform" engine="t"><server name="server1" http="8080" host="remote"/></farm></farms>
  </bas>`);
  reply = parseEnvelope(serviceResult(configFile, "r3", "start", missing));
  assert(!reply.body["ok"].boolean, reply.body.toString());
  assert(reply.body["error"].str == "no-instance", reply.body.toString());
}

/**
 * 最小的 hub 服务端：握手 + 读文本帧，只够验「agent 说了什么」。
 *
 * 起在**另一个线程**上（阻塞收发），因为被测方 `runReport` 要独占主线程的事件循环。
 */
private final class FakeHub {
  /** 握手请求原文，用来断言方法与路径。 */
  string request;
  /** 收到的每条**文本**帧；控制帧（关闭）不进这里。 */
  string[] messages;
  /** 监听端口：配置里写 `http://127.0.0.1:<port>`，basctl 再拼 bashub 的能力域路径。 */
  ushort port;

  private Socket listener;

  this() {
    listener = new Socket(AddressFamily.INET, SocketType.STREAM);
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    // 超时只是为了让「agent 没来」变成测试失败而不是挂住：正常路径用不到它
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(20));
    port = (cast(InternetAddress) listener.localAddress).port;
  }

  /** 在服务线程里跑：接一条连接、握手、把帧读干净。 */
  void serve() {
    auto conn = listener.accept();
    scope (exit) conn.close();
    conn.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(20));

    auto reader = new FrameReader(conn);
    request = reader.readHead();
    conn.send("HTTP/1.1 101 Switching Protocols\r\n"
        ~ "Upgrade: websocket\r\n"
        ~ "Connection: Upgrade\r\n"
        ~ "Sec-WebSocket-Accept: " ~ acceptKey(headerValue(request, "Sec-WebSocket-Key"))
        ~ "\r\n\r\n");
    // 握手请求和头几帧常在同一次 receive 里回来，所以帧要从同一个 reader 接着读
    messages = readFrames(reader);
  }
}

/** 握手应答：`base64(sha1(Sec-WebSocket-Key + RFC 6455 的固定 GUID))`，与客户端校验的一致。 */
private string acceptKey(string challenge) {
  enum magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  return Base64.encode(sha1Of(challenge ~ magic)).idup;
}

/** 取一行头（头名不分大小写）；没有就返回空串。 */
private string headerValue(string head, string name) {
  import std.algorithm : splitter;
  import std.uni : toLower;

  foreach (line; head.splitter("\r\n")) {
    auto colon = line.indexOf(':');
    if (colon <= 0)
      continue;
    if (strip(line[0 .. colon]).toLower() == strip(name).toLower())
      return strip(line[colon + 1 .. $]);
  }
  return "";
}

/**
 * 读文本帧直到连接结束。
 *
 * 客户端发的帧一律带掩码（RFC 6455 的要求），所以每帧先取 4 字节掩码再逐字节还原；长度有
 * 7 / 16 / 64 位三种写法，都要认。控制帧（关闭）不进返回值，但看到关闭就停——那之后没有文本了。
 */
private string[] readFrames(FrameReader reader) {
  auto frames = appender!(string[])();
  while (true) {
    auto head = reader.take(2);
    if (head.length < 2)
      break;
    auto opcode = head[0] & 0x0F;
    auto masked = (head[1] & 0x80) != 0;
    ulong length = head[1] & 0x7F;

    if (length == 126) {
      auto raw = reader.take(2);
      if (raw.length < 2)
        break;
      length = (cast(ulong) raw[0] << 8) | raw[1];
    } else if (length == 127) {
      auto raw = reader.take(8);
      if (raw.length < 8)
        break;
      length = 0;
      foreach (part; raw)
        length = (length << 8) | part;
    }

    ubyte[4] mask;
    if (masked) {
      auto raw = reader.take(4);
      if (raw.length < 4)
        break;
      mask[] = raw[];
    }

    auto payload = reader.take(cast(size_t) length);
    if (payload.length < length)
      break;
    if (masked) {
      foreach (i; 0 .. payload.length)
        payload[i] ^= mask[i % 4];
    }
    if (opcode == 0x1)
      frames.put(cast(string) payload.idup);
    if (opcode == 0x8)
      break;
  }
  return frames.data;
}

/** 按需从 socket 攒字节的小工具：帧可能横跨两次 `receive`，所以要能「等到够了再取」。 */
private final class FrameReader {
  private Socket conn;
  private ubyte[] buffer;

  this(Socket conn) {
    this.conn = conn;
  }

  /** 再收一段进 {@link buffer}；连接断了（或超时）返回 false。 */
  private bool fill() {
    auto chunk = new ubyte[4096];
    while (true) {
      auto received = conn.receive(chunk);
      if (received > 0) {
        buffer ~= chunk[0 .. received];
        return true;
      }
      // 被信号打断（EINTR）不是连接结束，只是这一次没收到东西——D 的运行时（GC / 事件循环）会发信号，
      // 把它当成断开就会连刚发出的帧一起丢掉
      import core.stdc.errno : EINTR, errno;
      if (received != Socket.ERROR || errno != EINTR)
        return false;
    }
  }

  /**
   * 读到空行，返回**不含**结尾空行的头，并且只吃掉头——同一批 receive 里跟着来的帧留在
   * {@link buffer} 里给 {@link readFrames} 接着读（握手请求与首帧常常一次到达）。
   */
  string readHead() {
    while (true) {
      auto end = (cast(string) buffer).indexOf("\r\n\r\n");
      if (end >= 0) {
        auto head = cast(string) buffer[0 .. end].idup;
        buffer = buffer[end + 4 .. $];
        return head;
      }
      if (!fill())
        return cast(string) buffer.idup;
    }
  }

  /** 取 `count` 个字节；连接先断了就返回目前能拿到的（可能短于 `count`，由调用方判断）。 */
  ubyte[] take(size_t count) {
    while (buffer.length < count) {
      if (!fill())
        break;
    }
    auto available = buffer.length < count ? buffer.length : count;
    auto taken = buffer[0 .. available].dup;
    buffer = buffer[available .. $];
    return taken;
  }
}
