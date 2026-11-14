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
import bas.remote : loadRemoteEnv;
import std.exception : assertThrown;
import std.process : environment;

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
import std.process : environment;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel,
  SocketType;
import std.string : indexOf, representation, strip;
import std.uuid : randomUUID;

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
