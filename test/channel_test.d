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
 * Unit tests for bas.channel：信封的编解码、原语名单，以及「认不出的原语既不执行也不炸」。
 *
 * 这里的报文样例与 bashub 侧测试共用（见 docs/channel-protocol.md）：改协议就同时改两边。
 */
module test.channel_test;

import bas.channel;

import std.algorithm : canFind, map;
import std.exception : assertThrown;
import std.json : JSONType, parseJSON;

@("hello declares both directions' capabilities and carries the identity") unittest {
  auto text = helloMessage("app1", "0.0.1", "/opt/bas", "0.14.0");
  auto msg = parseEnvelope(text);

  assert(msg.type == "hello");
  assert(!msg.isRequest());
  assert(msg.at.length == 25, msg.at);
  assert(msg.body["host"].str == "app1");
  assert(msg.body["basctl"].str == "0.0.1");
  assert(msg.body["basHome"].str == "/opt/bas");
  assert(msg.body["bas"].str == "0.14.0");
  foreach (primitive; supportedPrimitives)
    assert(msg.body["supports"].array.map!(s => s.str).canFind(primitive), primitive);
  assert(msg.body["supports"].array.map!(s => s.str).canFind("log:read"));
  assert(msg.body["supports"].array.map!(s => s.str).canFind("agent:log"));
  assert(msg.body["supports"].array.map!(s => s.str).canFind("report:now"));
  assert(msg.body["supports"].array.map!(s => s.str).canFind("service:start"));
  assert(msg.body["supports"].array.map!(s => s.str).canFind("service:stop"));
  assert(msg.body["supports"].array.map!(s => s.str).canFind("service:restart"));
}

@("a notification has no id while a request does") unittest {
  auto report = parseEnvelope(reportMessage("report:os", parseJSON(`{"cpu":{"cores":8}}`)));
  assert(report.type == "report:os");
  assert(!report.isRequest());
  assert(report.body["cpu"]["cores"].integer == 8);

  auto request = parseEnvelope(`{"type":"pdf:read","id":"r1","at":"2026-10-16T10:00:00+08:00","body":{}}`);
  assert(request.isRequest());
  assert(request.id == "r1");
  assert(!knownPrimitive(request.type));
  assert(unsupportedError(request.type) == "unsupported:pdf:read");
}

@("hub primitives are closed: everything else is unsupported") unittest {
  foreach (primitive; hubPrimitives)
    assert(knownPrimitive(primitive), primitive);
  assert(!knownPrimitive("service:reload"));
  assert(!knownPrimitive("shell"));
  assert(!knownPrimitive(""));
}

@("result carries data on success and error on failure") unittest {
  auto ok = parseEnvelope(resultMessage("r1", true, parseJSON(`{"total":42}`), ""));
  assert(ok.type == "result");
  assert(ok.id == "r1");
  assert(ok.body["ok"].boolean);
  assert(ok.body["data"]["total"].integer == 42);

  auto bad = parseEnvelope(resultMessage("r2", false, parseJSON("null"), "bad-request"));
  assert(!bad.body["ok"].boolean);
  assert(bad.body["error"].str == "bad-request");
  assert("data" !in bad.body.object);

  auto detailed = parseEnvelope(resultMessage("r3", false,
      parseJSON(`{"detail":"boom","logTail":["line"],"truncated":false}`), "start-failed"));
  assert(!detailed.body["ok"].boolean);
  assert(detailed.body["error"].str == "start-failed");
  assert(detailed.body["data"]["detail"].str == "boom");
}

@("missing optional fields are tolerated, a missing type is not") unittest {
  auto msg = parseEnvelope(`{"type":"ping"}`);
  assert(msg.type == "ping");
  assert(msg.id == "");
  assert(msg.body.type == JSONType.object);

  auto plain = parseEnvelope(`{"type":"ping","id":null,"body":"whatever"}`);
  assert(plain.id == "");
  assert(plain.body.type == JSONType.object);

  assertThrown(parseEnvelope(`{"id":"r1"}`));
  assertThrown(parseEnvelope(`[]`));
  assertThrown(parseEnvelope(`not json`));
}

@("unknown body fields are ignored, not rejected") unittest {
  auto msg = parseEnvelope(`{"type":"log:read","id":"r1","at":"2026-10-16T10:00:00+08:00",
      "body":{"instance":"platform.server1","from":1,"to":50,"encoding":"utf-8"}}`);
  assert(msg.body["instance"].str == "platform.server1");
  assert(msg.body["from"].integer == 1);
  assert(msg.body["to"].integer == 50);
}
