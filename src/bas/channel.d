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
 * 控制通道协议：信封、原语名单与编解码。协议的**唯一权威**是
 * `docs/channel-protocol.md`，本模块是它在 basctl 这一侧的落地。
 *
 * 这里只做编解码，不碰网络也不碰本机事实：连接循环在 {@link bas.agent}，采集在
 * {@link bas.report}。分开是为了让协议能单独测——两侧（basctl 的 D、bashub 的 Scala）共用文档里
 * 那批报文样例，谁改协议谁同时改两边。
 *
 * 两条不变量（见 channel-protocol.md）：
 *
 * - **原语封闭**：`type` 只在 {@link agentPrimitives} / {@link hubPrimitives} 里，认不出即拒；
 * - **字段开放**：`body` 里不认识的键忽略；未知的 `type` 既不执行也不退出——agent 是常驻进程，
 *   任何一条消息都不许把它弄死。
 */
module bas.channel;

import bas.serverinfo : localIsoTimestamp;

import std.datetime : Clock;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

/** agent → hub 的原语。 */
immutable string[] agentPrimitives = ["hello", "report:os", "report:bas", "result", "pong"];

/**
 * hub 能下发的原语（本端认识的）。不在这里的 `type` 一律按「不支持」处理——这就是「原语封闭」：
 * 名单之外没有可执行的东西，也就没有「随便发个命令字符串」的余地。
 */
immutable string[] hubPrimitives = [
  "ping", "report:now", "log:read", "service:start", "service:stop", "service:restart"
];

/**
 * `hello.supports` 申报的能力：两个方向里本端能处理的原语。
 *
 * 不能只报 {@link agentPrimitives}：hub 要据此决定能不能下发 `log:read` / `report:now` /
 * `service:*`。
 */
immutable string[] supportedPrimitives = [
  "hello", "report:os", "report:bas", "result", "pong", "ping", "report:now", "log:read",
  "service:start", "service:stop", "service:restart"
];

/** 信封：`type` / `id` / `at` / `body`，所有消息共用。 */
struct Envelope {
  /** 原语名，取 {@link hubPrimitives} / {@link agentPrimitives}。 */
  string type;
  /** 请求号；**空串表示通知**（不等回执）。 */
  string id;
  /** 发起方的本机时刻，格式见 {@link nowStamp}。 */
  string at;
  /** 该原语的负载；没有负载就是空对象。 */
  JSONValue body;

  /** 有 `id` 就是请求，收到方必须回一条 `result`。 */
  bool isRequest() const @safe pure nothrow {
    return id.length > 0;
  }
}

/** `at` 的取值：本机时区的 ISO-8601，与 `server.info` 的 `started` 同一格式、同一个实现。 */
string nowStamp() {
  return localIsoTimestamp(Clock.currTime());
}

/** 本端认识这个原语吗。 */
bool knownPrimitive(string type) @safe pure nothrow {
  foreach (primitive; hubPrimitives) {
    if (primitive == type)
      return true;
  }
  return false;
}

/** 「不支持」的错误串：`unsupported:<type>`，原样放进 `result.error`。 */
string unsupportedError(string type) @safe pure nothrow {
  return "unsupported:" ~ type;
}

/**
 * 解析一条消息。
 *
 * 非法 JSON、不是对象、缺 `type` 一律抛异常——调用方把异常落成一行日志，**既不断连也不退出**
 * （稳定性条款）。字段本身是开放的：`id` / `at` 可以缺，`body` 缺了当空对象。
 */
Envelope parseEnvelope(string text) {
  JSONValue root;
  try {
    root = parseJSON(text);
  } catch (Exception e) {
    throw new Exception("not json: " ~ e.msg);
  }
  if (root.type != JSONType.object)
    throw new Exception("message is not a json object");
  auto type = textField(root, "type");
  if (!type.length)
    throw new Exception("message has no type");
  return Envelope(type, textField(root, "id"), textField(root, "at"), bodyOf(root));
}

/** 渲染一条消息：`id` 非空即请求，`at` 由这里补上（发起方时刻）。 */
string renderEnvelope(string type, string id, JSONValue body) {
  JSONValue msg = ["type": JSONValue(type), "at": JSONValue(nowStamp())];
  if (id.length)
    msg["id"] = JSONValue(id);
  msg["body"] = body;
  return msg.toString();
}

/** `hello`：连上后的第一条，自报身份与能力（`supports` = {@link supportedPrimitives}）。 */
string helloMessage(string host, string basctlVersion, string basHome, string basVersion) {
  JSONValue[] items;
  foreach (primitive; supportedPrimitives)
    items ~= JSONValue(primitive);
  JSONValue supports = JSONValue(items);

  JSONValue body = [
    "host": JSONValue(host),
    "basctl": JSONValue(basctlVersion),
    "basHome": JSONValue(basHome),
    "bas": JSONValue(basVersion),
    "supports": supports
  ];
  return renderEnvelope("hello", "", body);
}

/** `report:os` / `report:bas`：整份替换语义的通知，不带 `id`。 */
string reportMessage(string type, JSONValue body) {
  return renderEnvelope(type, "", body);
}

/** `pong`：保活应答，空 body。 */
string pongMessage() {
  return renderEnvelope("pong", "", emptyBody());
}

/** `result`：对所有带 `id` 请求的应答。成功可带 `data`，失败带 `error`。 */
string resultMessage(string id, bool ok, JSONValue data, string error) {
  JSONValue body = ["ok": JSONValue(ok)];
  if (ok)
    body["data"] = data;
  else
    body["error"] = JSONValue(error);
  return renderEnvelope("result", id, body);
}

/** 取 body 里的字符串字段；缺字段或类型不对返回空串（字段开放，少一个不该让整条消息炸掉）。 */
string bodyText(ref JSONValue body, string key) {
  return textField(body, key);
}

/** 取 body 里的整数字段；缺字段或类型不对返回 0。 */
long bodyNumber(ref JSONValue body, string key) {
  auto found = key in body.object;
  if (found is null)
    return 0;
  switch (found.type) {
  case JSONType.integer:
    return found.integer;
  case JSONType.float_:
    return cast(long) found.floating;
  default:
    return 0;
  }
}

private:

/** `{}`：没有负载的通知用它（`body` 恒为对象，省得读方到处判空）。 */
private JSONValue emptyBody() @safe pure nothrow {
  JSONValue[string] fields;
  return JSONValue(fields);
}

/** 取字符串字段；缺字段、null、非字符串都当「没有」（返回空串）——少一个字段不该让整条消息炸掉。 */
private string textField(ref JSONValue obj, string key) {
  auto found = key in obj.object;
  if (found is null || found.type != JSONType.string)
    return "";
  return strip(found.str);
}

/** 取 `body`；缺了或是 null 就当空对象。 */
private JSONValue bodyOf(ref JSONValue obj) {
  auto found = "body" in obj.object;
  if (found is null || found.type != JSONType.object)
    return emptyBody();
  return *found;
}
