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
 * 控制通道的 agent 侧：**主动出站**连一条 WebSocket 到 bashub，报现状、听指令。
 *
 * 两个命令共用一个循环，只是跑几轮不同：
 *
 * - `basagent report`：连上、发 `hello` + 两份上报、断开；
 * - `basagent`：常驻，断线按 {@link reconnectDelay} 重连，周期上报并随时接指令。
 *
 * 三条不变量（见 `docs/channel-protocol.md`）：
 *
 * 1. **认不出的原语既不执行也不退出**——有 `id` 回 `result{ok:false}`，没有就记一行日志；
 * 2. 报文解析失败同样只记一行：agent 是常驻进程，一条坏消息不许把它弄死；
 * 3. 指令走白名单分支，没有「把控制台来的字符串交给 shell」这条路。
 *
 * 顺序也是设计的一部分：`hello`（身份与能力）→ 两份上报 → 之后按节拍。重连后重发整份快照，
 * 不做增量续传——上报是整份替换语义，接上就是一致的。
 */
module bas.agent;

import bas.channel;
import bas.config : Container, parseServerXmlFile;
import bas.hub : agentUrl;
import bas.logs : agentLog, consoleLog, countLines, maxLogLines, plainName, readLogWindow;
import bas.net : hostName, localAddresses;
import bas.pull : runPull;
import bas.remote : RemoteConfig, agentChannelUrl, bearerCredential, loadRemoteConf, remoteConfFileName,
  validateRemoteConf;
import bas.report : basReport, healthReport, osReport;
import bas.starter : serviceAction;

import vibe.core.core : exitEventLoop, runApplication, runTask, sleep;
import vibe.core.log : logInfo, logWarn;
import vibe.http.client : HTTPClientRequest, HTTPClientSettings;
import vibe.http.websockets : WebSocket, connectWebSocketEx;
import vibe.inet.url : URL;
import vibe.stream.tls : TLSContext, TLSPeerValidationMode;

import core.time : Duration, seconds;
import core.stdc.stdlib : abort;
import std.algorithm : filter;
import std.array : array, join;
import std.datetime.stopwatch : MonoTime;
import std.file : exists;
import std.json : JSONValue;
import std.path : absolutePath, buildPath, dirName;
import std.process : environment, spawnShell;
import std.stdio : stderr, writeln;
import std.conv : to;
import std.string : format, strip;

/** 心跳节拍：循环等消息的超时。等到了就处理消息，等不到就用来看计时器。 */
private enum tick = 1.seconds;

/** 多久没收到任何消息就认为这条连接已经废了，交给外层重连（中间设备会静默掐断空闲连接）。 */
private enum silentTimeout = 150.seconds;

/** 断线后的重连间隔：固定值，不做指数退避——少一个要调的参数。 */
private enum reconnectDelay = 10.seconds;

/** 一条 WebSocket 消息的上限；日志窗口与上报都远小于这个值。 */
private enum size_t maxChannelPayloadBytes = 256 * 1024;

/** 最近若干个请求的结果：重复的 `id` 只回放，不重复执行（尤其不能让 restart 做两遍）。 */
private enum int recentResultLimit = 128;

/**
 * 拨号的连接与读取超时。
 *
 * 控制台多数在机房里、也可能暂时不可达，所以「连不上」要有确定的上界：缺省值是
 * `Duration.max`，真按它等下去，一次 `report` 能让人等上好几分钟。
 */
private enum connectTimeout = 20.seconds;

/** 常见发行版的系统 CA 包；CentOS 7 使用 pki 路径。 */
private immutable string[] caBundlePaths = [
  "/etc/ssl/certs/ca-certificates.crt",
  "/etc/pki/tls/certs/ca-bundle.crt",
  "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
  "/etc/ssl/ca-bundle.pem"
];

/** 一次会话需要的全部输入。地址与 token 都来自同目录 `conf/basctl.conf`，没有第二处来源。 */
struct AgentContext {
  string endpoint;
  /** 握手凭证：`<project>:<Project.key>`。 */
  string credential;
  /** 当前配置路径；service:* 动作与 report:bas 都从同一份 server.xml 找实例。 */
  string configFile;
  string host;
  string basHome;
  string basVersion;
  string basctlVersion;
  /** 只跑一轮（`report`）；常驻（`agent`）为 false。 */
  bool once;
  /** 这一轮到底报上去了没有：`report` 据此定退出码。 */
  bool served;
  /** 请求号 → 已发出的 result；跨重连保留，按插入顺序淘汰。 */
  string[string] recentResults;
  string[] recentRequestIds;
}

/** `basagent [server.xml]`：常驻，连上就报，断线重连。 */
int runAgent(string configFile, string basctlVersion, string[] rest) {
  if (rest.length) {
    stderr.writeln("Unknown option: " ~ rest[0]);
    return 1;
  }
  if (!exists(configFile)) {
    stderr.writeln("basagent: cannot find config file " ~ configFile);
    return 1;
  }
  auto remotePath = agentRemotePath(configFile);
  auto remote = loadRemoteConf(remotePath);
  if (!channelEnabled(remote)) {
    stderr.writeln("basagent: warning: remote is not configured in " ~ remotePath
        ~ "; agent not started.");
    return 0;
  }
  AgentContext ctx;
  try {
    validateRemoteConf(remote, remotePath);
    ctx = agentContext(parseServerXmlFile(configFile), remote, configFile, basctlVersion, false);
  } catch (Exception e) {
    stderr.writeln("basagent: " ~ e.msg);
    return 1;
  }
  writeln("channel: reporting to " ~ ctx.endpoint);
  runTask({ agentLoop(ctx); });
  return runApplication(null);
}

/** `basagent report [server.xml]`：连一次、发两份上报、断开。 */
int runReport(string configFile, string basctlVersion, string[] rest) {
  if (rest.length) {
    stderr.writeln("Unknown option: " ~ rest[0]);
    return 1;
  }
  if (!exists(configFile)) {
    stderr.writeln("basagent report: cannot find config file " ~ configFile);
    return 1;
  }
  AgentContext ctx;
  try {
    ctx = agentContext(parseServerXmlFile(configFile), configFile, basctlVersion, true);
  } catch (Exception e) {
    stderr.writeln("basagent report: " ~ e.msg);
    return 1;
  }
  runTask({ agentLoop(ctx); });
  auto code = runApplication(null);
  // 连不上时事件循环同样正常退出，所以退出码得看「报上去了没有」，不能只看循环的返回值
  if (!ctx.served) {
    stderr.writeln("no snapshot published: " ~ ctx.endpoint);
    return 1;
  }
  return code;
}

/** `[remote] url/project/token` 齐全即启用通道；文件不存在或字段缺失都静默跳过。 */
bool channelEnabled(const RemoteConfig remote) {
  return remote.complete;
}

/** 与 `server.xml` 同目录的 `basctl.conf`。 */
private string agentRemotePath(string configFile) {
  return buildPath(dirName(configFile), remoteConfFileName);
}

/** 组装上下文：地址、Project 与 token 全部来自同目录 `basctl.conf`。 */
AgentContext agentContext(const Container conf, string configFile, string basctlVersion, bool once) {
  auto remotePath = agentRemotePath(configFile);
  auto remote = loadRemoteConf(remotePath);
  validateRemoteConf(remote, remotePath);
  return agentContext(conf, remote, configFile, basctlVersion, once);
}

/** 已读取并校验过的远程配置。 */
private AgentContext agentContext(const Container conf, const RemoteConfig remote, string configFile,
    string basctlVersion, bool once) {
  AgentContext ctx;
  ctx.endpoint = agentUrl(agentChannelUrl(remote));
  ctx.credential = bearerCredential(remote);
  ctx.configFile = configFile;
  ctx.host = hostName();
  ctx.basHome = dirName(dirName(absolutePath(configFile)));
  ctx.basVersion = conf.version_;
  ctx.basctlVersion = basctlVersion;
  ctx.once = once;
  return ctx;
}

/**
 * 连接循环：连一次、跑一次会话；常驻模式下失败或断开都只是等一会儿再来。
 *
 * 整个循环 `nothrow`（交给 vibe 的 `runTask`）：日志与 `sleep` 自己也可能抛，所以逐段兜住——
 * **agent 退出只发生在收到信号时**，网络与磁盘的毛病都不该让它退出。
 */
private void agentLoop(ref AgentContext ctx) @system nothrow {
  while (true) {
    try {
      connectOnce(ctx);
    } catch (Throwable t) {
      swallow({ logWarn("channel: %s", t.msg); });
    }
    if (ctx.once)
      break;
    swallow({ sleep(reconnectDelay); });
  }
  exitEventLoop(true);
}

/** 拨号、握手（`Authorization: Bearer <project>:<Project.key>`），连上后交给 {@link serve}。 */
private void connectOnce(ref AgentContext ctx) {
  swallow({ logInfo("channel: connecting to %s", ctx.endpoint); });
  auto settings = new HTTPClientSettings;
  settings.connectTimeout = connectTimeout;
  // WebSocket 复用底层 TCP 的 readTimeout。若这里仍用 20s，而 hub 的 ping 是 60s，
  // 空闲连接会在第一轮心跳前就被客户端自己掐断，表现为每 60s 重连一次。
  settings.readTimeout = silentTimeout;
  settings.webSocketPayloadMaxLength = maxChannelPayloadBytes;

  // vibe-http 新客户端的默认值是 none；不覆盖就等于接受任意自签证书。
  // 这里恢复完整校验，并从系统 CA 包加载信任根。找不到 CA 时保持 trustedCert，
  // 让握手失败而不是静默降级。
  immutable caBundle = findCaBundle();
  if (!caBundle.length)
    logWarn("channel: no system CA bundle found; TLS certificate validation will fail closed");
  settings.tlsContextSetup = (TLSContext tls) @safe nothrow {
    try
      tls.peerValidationMode = TLSPeerValidationMode.trustedCert;
    catch (Exception) {
      // 这个 setter 当前不会抛；真抛了就终止进程，绝不带着 none 继续连接。
      abort();
    }
    if (caBundle.length) {
      try
        tls.useTrustedCertificateFile(caBundle);
      catch (Exception) {
        // 保持 trustedCert；加载失败时握手会失败，不能退回 none。
      }
    }
  };
  // 身份：project + 本机 IP。hub 用 ip 区分同一 project 的多台 agent，只顶掉同 IP 的旧连接；
  // 多网卡时全部上报，由 hub 取与 project / hosts 配置命中的那个。@safe 闭包里不做系统调用，
  // 所以先算好。
  // 回环地址有意不发：它不构成一台机器的对外身份，留着只会让所有机器都命中 project 里的
  // 127.0.0.1 配置；只有回环的开发机才如实上报，否则 hub 无从识别。
  auto allIps = localAddresses();
  auto serverIps = allIps.filter!(ip => ip != "127.0.0.1").array;
  immutable localIps = join(serverIps.length ? serverIps : allIps, ",");
  auto ws = connectWebSocketEx(URL(ctx.endpoint),
      (scope HTTPClientRequest req) @safe {
        req.headers["Authorization"] = "Bearer " ~ ctx.credential;
        req.headers["ip"] = localIps;
      }, settings);
  scope (exit) {
    if (ws.connected)
      ws.close();
  }
  serve(ctx, ws);
}

/** 优先使用显式环境变量，其次按发行版常见路径查找系统 CA 包。 */
private string findCaBundle() {
  foreach (name; ["SSL_CERT_FILE", "CURL_CA_BUNDLE"]) {
    auto value = environment.get(name, "").strip;
    if (value.length) {
      try {
        if (exists(value))
          return value;
      } catch (Exception) {
        // 坏的环境变量不阻止继续找系统路径。
      }
    }
  }
  foreach (path; caBundlePaths) {
    try {
      if (exists(path))
        return path;
    } catch (Exception) {
      // 没权限或路径异常时继续试下一个。
    }
  }
  return "";
}

/** 执行一段可能抛异常的动作，把异常压成一行日志——循环里的每一步都不许把 agent 弄死。 */
private void swallow(scope void delegate() action) @system nothrow {
  try {
    action();
  } catch (Throwable t) {
    try {
      logWarn("channel: %s", t.msg);
    } catch (Throwable) {
      // 连日志都写不出去就不再纠缠：这一层的职责是「不让异常逃出去」
    }
  }
}

/** 一条连接的生命周期：`hello` → 完整快照 → 响应 hub 下发的固定原语。 */
private void serve(ref AgentContext ctx, scope WebSocket ws) {
  ws.send(helloMessage(ctx.host, ctx.basctlVersion, ctx.basHome, ctx.basVersion));
  sendReports(ctx, ws);
  ctx.served = true;
  logInfo("channel: connected as %s", ctx.host.length ? ctx.host : ctx.basHome);

  if (ctx.once)
    return;

  auto lastTraffic = MonoTime.currTime;
  while (ws.connected) {
    if (ws.waitForData(tick)) {
      handle(ctx, ws, ws.receiveText());
      lastTraffic = MonoTime.currTime;
    } else if (MonoTime.currTime - lastTraffic > silentTimeout) {
      throw new Exception("no traffic from hub for " ~ silentTimeout.to!string);
    }
  }
}

/** 两份上报：`report:os`（主机）与 `report:bas`（实例清单）。整份替换，失败不影响下一条。 */
private void sendReports(const AgentContext ctx, scope WebSocket ws) {
  ws.send(reportMessage("report:os", osReport()));
  Container container;
  try {
    // 每次重读配置：与 service:* 一样以当前 server.xml 为准，也能反映运行期的声明变化
    container = parseServerXmlFile(ctx.configFile);
  } catch (Exception e) {
    logWarn("channel: cannot read declared instances from %s: %s", ctx.configFile, e.msg);
  }
  ws.send(reportMessage("report:bas", basReport(ctx.basHome, container)));
}

/** 响应 hub 的 `report:health`：只报实例 id 与 running/stopped，不重复采集 OS 和 webapps。 */
private void sendHealth(const AgentContext ctx, scope WebSocket ws) {
  Container container;
  try {
    container = parseServerXmlFile(ctx.configFile);
  } catch (Exception e) {
    logWarn("channel: cannot read declared instances from %s: %s", ctx.configFile, e.msg);
  }
  ws.send(reportMessage("report:health", healthReport(ctx.basHome, container)));
}

/**
 * 远程 start/restart 前拉一次配置：配置拉不下来就不执行动作，避免拿旧拓扑冒充当前意图。
 * `stop` 不走这里——停机必须按当前运行信息完成，不能被一次配置更新挡住。
 */
private bool refreshBeforeService(ref AgentContext ctx) {
  auto remotePath = agentRemotePath(ctx.configFile);
  try {
    auto remote = loadRemoteConf(remotePath);
    validateRemoteConf(remote, remotePath);
  } catch (Exception e) {
    logWarn("channel: service postponed, remote config is not usable: %s", e.msg);
    return false;
  }

  auto basHome = dirName(dirName(absolutePath(ctx.configFile)));
  if (runPull([basHome]) != 0) {
    logWarn("channel: service postponed, pull failed");
    return false;
  }
  try {
    ctx.basVersion = parseServerXmlFile(ctx.configFile).version_;
  } catch (Exception e) {
    logWarn("channel: service postponed, pulled server.xml is invalid: %s", e.msg);
    return false;
  }
  return true;
}

/** 处理一条来自 hub 的消息：白名单分支 + 认不出就拒绝（既不执行，也不退出）。 */
private void handle(ref AgentContext ctx, scope WebSocket ws, string text) {
  Envelope msg;
  try {
    msg = parseEnvelope(text);
  } catch (Exception e) {
    logWarn("channel: %s", e.msg);
    return;
  }

  // 破坏性动作也走这一条：同一个 id 重发（控制台重试、网络抖动）只回放上次结果。
  if (msg.isRequest()) {
    if (auto previous = msg.id in ctx.recentResults) {
      ws.send(*previous);
      return;
    }
  }

  switch (msg.type) {
  case "ping":
    ws.send(pongMessage());
    break;
  case "report:now":
    sendReports(ctx, ws);
    break;
  case "report:health":
    sendHealth(ctx, ws);
    break;
  case "log:read":
    auto reply = logReadResult(ctx.basHome, msg.id, msg.body);
    rememberResult(ctx, msg.id, reply);
    ws.send(reply);
    break;
  case "agent:log":
    auto reply = agentLogResult(ctx.basHome, msg.id, msg.body);
    rememberResult(ctx, msg.id, reply);
    ws.send(reply);
    break;
  case "service:start":
  case "service:stop":
  case "service:restart":
    if (!msg.isRequest()) {
      logWarn("channel: ignore %s without id", msg.type);
      break;
    }
    if (!requestTimestampFresh(msg.at)) {
      auto reply = resultMessage(msg.id, false, JSONValue(null), "bad-request: stale or missing timestamp");
      rememberResult(ctx, msg.id, reply);
      ws.send(reply);
      break;
    }
    auto action = msg.type["service:".length .. $];
    if ((action == "start" || action == "restart") && !refreshBeforeService(ctx)) {
      auto reply = resultMessage(msg.id, false, JSONValue(null), "pull-failed");
      rememberResult(ctx, msg.id, reply);
      ws.send(reply);
      break;
    }
    auto reply = serviceResult(ctx.configFile, msg.id, action, msg.body);
    rememberResult(ctx, msg.id, reply);
    ws.send(reply);
    // 结果是「动作做完了」，不是「快照已经推到」；重发完整快照，保证摘要不会停在动作前。
    sendReports(ctx, ws);
    break;
  default:
    if (msg.isRequest())
      ws.send(resultMessage(msg.id, false, JSONValue(null), unsupportedError(msg.type)));
    else
      logWarn("channel: ignore %s", msg.type);
    break;
  }
}

/** 记下请求结果；`id` 为空（通知）不记，超过上限丢掉最旧的一条。 */
private void rememberResult(ref AgentContext ctx, string id, string reply) {
  if (id.length == 0)
    return;
  if ((id in ctx.recentResults) is null)
    ctx.recentRequestIds ~= id;
  ctx.recentResults[id] = reply;
  if (ctx.recentRequestIds.length > recentResultLimit) {
    auto oldest = ctx.recentRequestIds[0];
    ctx.recentRequestIds = ctx.recentRequestIds[1 .. $];
    ctx.recentResults.remove(oldest);
  }
}

/**
 * `log:read`：读 `logs/<实例>/console.out` 的第 from–to 行，回
 * `{total, from, to, lines:[...]}`。
 *
 * `tail` 是给「先看尾部、之后只取新增行」的客户端用的：from/to 都没给时，它把窗口定位到最后
 * `tail` 行；给出 from 后仍按区间读，不重读历史。
 *
 * 实例名来自控制台，只允许**普通名字**（不含路径分隔符、不是 `.` / `..`）——它是目录名，不是路径，
 * 否则控制台就能借日志接口读机器上任何文件。定位、数行与截断都在 {@link bas.logs} 里，和
 * `basctl logs` 共用同一份读法。
 *
 * 只收 `basHome` 与 body，不碰连接：这条路径是控制台唯一能指到文件的地方，越是想少出岔子，
 * 越要能脱离容器与事件循环单独测（见 `test/agent_test.d`）。
 */
string logReadResult(string basHome, string id, ref JSONValue body) {
  auto instance = bodyText(body, "instance");
  if (!plainName(instance))
    return resultMessage(id, false, JSONValue(null), "bad-request");
  return logWindowResult(consoleLog(basHome, instance), id, body);
}

/** `agent:log`：读取 basagent 自身日志，请求体与 `log:read` 同形但不接受实例名。 */
string agentLogResult(string basHome, string id, ref JSONValue body) {
  return logWindowResult(agentLog(basHome), id, body);
}

/** 从一个固定日志文件读取 `from/to/tail` 窗口；路径只由调用方拼出，不接受控制台输入。 */
private string logWindowResult(string path, string id, ref JSONValue body) {
  if (!exists(path))
    return resultMessage(id, false, JSONValue(null), "no-log");

  auto from = bodyNumber(body, "from");
  auto to = bodyNumber(body, "to");
  auto tail = bodyNumber(body, "tail");
  if (tail > maxLogLines)
    tail = maxLogLines;
  if (from <= 0) {
    if (tail > 0) {
      auto total = countLines(path);
      from = total > tail ? total - tail + 1 : 1;
    } else {
      from = 1;
    }
  }
  if (to <= 0 || to - from + 1 > maxLogLines)
    to = from + maxLogLines - 1;

  long total;
  string[] lines;
  bool truncated;
  try {
    auto window = readLogWindow(path, from, to);
    total = window.total;
    lines = window.lines;
    truncated = window.truncated;
  } catch (Exception e) {
    return resultMessage(id, false, JSONValue(null), "read-failed: " ~ e.msg);
  }

  JSONValue[] items;
  foreach (line; lines)
    items ~= JSONValue(line);
  JSONValue data = [
    "total": JSONValue(total),
    "from": JSONValue(from),
    "to": JSONValue(from + lines.length - 1),
    "lines": JSONValue(items),
    "truncated": JSONValue(truncated)
  ];
  return resultMessage(id, true, data, "");
}

/**
 * `service:start|stop|restart`：按 body 里的实例名调用本机启停，回
 * `{state:"running"|"stopped", pid?}`。
 *
 * 实例名只是 `server.xml` 里的限定名，动作由 {@link bas.starter.serviceAction} 分支处理；
 * 这里没有把控制台输入拼进命令行的路径。请求必须带 `id`（破坏性动作不接受无回执的通知）。
 */
string serviceResult(string configFile, string id, string action, ref JSONValue body) {
  auto instance = bodyText(body, "instance");
  if (!plainName(instance))
    return resultMessage(id, false, JSONValue(null), "bad-request");

  auto result = serviceAction(configFile, action, instance);
  if (!result.ok) {
    JSONValue data = JSONValue(null);
    if (result.detail.length || result.logTail.length || result.truncated) {
      JSONValue[] lines;
      foreach (line; result.logTail)
        lines ~= JSONValue(line);
      data = [
        "detail": JSONValue(result.detail),
        "logTail": JSONValue(lines),
        "truncated": JSONValue(result.truncated)
      ];
    }
    return resultMessage(id, false, data, result.error);
  }

  JSONValue data = ["state": JSONValue(result.state)];
  if (result.pid > 0)
    data["pid"] = JSONValue(cast(long) result.pid);
  return resultMessage(id, true, data, "");
}
