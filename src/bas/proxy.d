/* Copyright (C) 2026 Beangle
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

/// `basctl proxy`：从 bashub 下载完整代理配置包，落盘并 reload。
///
/// 不读取 conf/server.xml，也不理解代理拓扑；bundle 由 bashub 渲染。
module bas.proxy;

import bas.download : curlDownload;
import bas.fsutil : setPrivateFile;
import bas.remote : RemoteConfig, bearerCredential, hubApiRoot, loadRemoteEnv;

import core.sys.posix.unistd : geteuid;
import std.algorithm : canFind, startsWith;
import std.array : join;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdirRecurse, read, readText, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.process : execute;
import std.stdio : stderr, writeln;
import std.string : strip, toStringz;
import std.uuid : randomUUID;
import std.zip : ZipArchive;

private enum haproxyConfig = "/etc/haproxy/haproxy.cfg";
private enum nginxConfig = "/etc/nginx/nginx.conf";
private enum certificateRoot = "/etc/basproxy/certs";

/// 当前 bundle 的本地落点。
struct ProxyPaths {
  string config;
  string certificate;
  string key;
}

private ProxyPaths pathsFor(string engine, string endpoint) {
  ProxyPaths paths;
  auto plain = endpoint.length ? endpoint : "default";
  if (engine == "haproxy") {
    paths.config = haproxyConfig;
    paths.certificate = certificateRoot ~ "/" ~ (plain == "default" ? "bundle.pem" : plain ~ ".bundle.pem");
  } else {
    paths.config = nginxConfig;
    paths.certificate = certificateRoot ~ "/" ~ (plain == "default" ? "cert.pem" : plain ~ ".pem");
    paths.key = certificateRoot ~ "/" ~ (plain == "default" ? "key.pem" : plain ~ ".key.pem");
  }
  return paths;
}

int runProxy(string[] args) {
  if (!args.length) {
    proxyUsage();
    return 1;
  }
  auto command = args[0];
  string engine;
  string endpoint;
  string bundleFile;
  bool dryRun;
  foreach (arg; args[1 .. $]) {
    if (arg.startsWith("--engine="))
      engine = arg["--engine=".length .. $].strip;
    else if (arg.startsWith("--endpoint="))
      endpoint = arg["--endpoint=".length .. $].strip;
    else if (arg.startsWith("--bundle="))
      bundleFile = arg["--bundle=".length .. $].strip;
    else if (arg == "--dry-run")
      dryRun = true;
    else if (arg == "--help" || arg == "-h") {
      proxyUsage();
      return 0;
    } else {
      stderr.writeln("Unknown proxy option: " ~ arg);
      proxyUsage();
      return 1;
    }
  }
  if (engine != "haproxy" && engine != "nginx") {
    stderr.writeln("basctl proxy: --engine must be haproxy or nginx");
    return 1;
  }
  auto paths = pathsFor(engine, endpoint);
  if (command == "status") {
    writeln("engine:      " ~ engine);
    writeln("config:      " ~ paths.config ~ (exists(paths.config) ? " (present)" : " (missing)"));
    writeln("certificate: " ~ paths.certificate ~ (exists(paths.certificate) ? " (present)" : " (missing)"));
    if (paths.key.length)
      writeln("private key: " ~ paths.key ~ (exists(paths.key) ? " (present)" : " (missing)"));
    return 0;
  }
  if (command != "apply") {
    stderr.writeln("Unknown proxy command: " ~ command);
    proxyUsage();
    return 1;
  }
  if (geteuid() != 0 && !dryRun) {
    stderr.writeln("basctl proxy apply: root is required");
    return 2;
  }
  return applyBundle(engine, endpoint, paths, dryRun, bundleFile);
}

private struct ProxyBundle {
  string config;
  string certificate;
  string privateKey;
}

private ProxyBundle readBundle(string path, string engine) {
  auto zip = new ZipArchive(cast(ubyte[]) read(path));
  auto manifestMember = zip.directory["manifest.json"];
  if (manifestMember is null)
    throw new Exception("manifest.json is missing");
  zip.expand(manifestMember);
  auto doc = parseJSON(cast(string) manifestMember.expandedData);
  auto bundleEngine = text(doc, "engine");
  if (bundleEngine != engine)
    throw new Exception("bundle engine mismatch: " ~ bundleEngine);
  auto files = doc["files"];
  if (files.type != JSONType.object)
    throw new Exception("manifest.files is missing");
  ProxyBundle bundle;
  bundle.config = zipMember(zip, files, "config");
  bundle.certificate = zipMember(zip, files, "certificate");
  bundle.privateKey = zipMember(zip, files, "privateKey");
  if (bundle.config.length == 0)
    throw new Exception("bundle is missing config");
  return bundle;
}

private string zipMember(ZipArchive zip, JSONValue files, string role) {
  auto item = files[role];
  if (item.type != JSONType.object)
    throw new Exception("manifest file role is missing: " ~ role);
  auto name = text(item, "path");
  auto expected = text(item, "sha256");
  if (name.length == 0 || expected.length == 0)
    throw new Exception("manifest file entry is incomplete: " ~ role);
  if (name.startsWith("/") || name.canFind(".."))
    throw new Exception("unsafe bundle path: " ~ name);
  auto member = zip.directory[name];
  if (member is null)
    throw new Exception("bundle member is missing: " ~ name);
  zip.expand(member);
  auto content = cast(string) member.expandedData;
  if (sha256(content) != expected)
    throw new Exception("bundle hash mismatch: " ~ name);
  return content;
}

private int applyBundle(string engine, string endpoint, ProxyPaths paths, bool dryRun, string bundleFile) {
  auto temp = bundleFile.length ? bundleFile
      : "/tmp/basctl-proxy-" ~ randomUUID().toString ~ ".zip";
  if (bundleFile.length == 0) {
    RemoteConfig remote;
    try {
      remote = loadRemoteEnv();
      if (!remote.complete)
        throw new Exception("BAS_PRINCIPAL/BAS_TOKEN are not set");
    } catch (Exception e) {
      stderr.writeln("basctl proxy: " ~ e.msg);
      return 1;
    }
    scope (exit) if (exists(temp)) remove(temp);
    auto url = hubApiRoot(remote) ~ "/config/" ~ remote.project ~ "/proxy-bundle?engine=" ~ engine;
    if (endpoint.length)
      url ~= "&endpoint=" ~ endpoint;
    if (!curlDownload(url, temp, ["Authorization: Bearer " ~ bearerCredential(remote)], false, 8 * 1024 * 1024)) {
      stderr.writeln("basctl proxy: failed to download bundle from " ~ url);
      return 1;
    }
  }

  ProxyBundle bundle;
  try
    bundle = readBundle(temp, engine);
  catch (Exception e) {
    stderr.writeln("basctl proxy: invalid bundle: " ~ e.msg);
    return 1;
  }
  auto config = bundle.config;
  auto certificate = bundle.certificate;
  auto privateKey = bundle.privateKey;

  auto certPem = engine == "haproxy" ? privateKey.strip ~ "\n" ~ certificate.strip ~ "\n" : certificate;
  if (dryRun) {
    writeln("would install " ~ paths.config);
    writeln("would install " ~ paths.certificate);
    return 0;
  }

  string[string] previous;
  foreach (path; [paths.config, paths.certificate, paths.key]) {
    if (path.length && exists(path))
      previous[path] = readText(path);
  }
  try {
    if (certificate.length && privateKey.length) {
      writePrivate(paths.certificate, certPem);
      if (paths.key.length)
        writePrivate(paths.key, privateKey);
    }
    writeAtomic(paths.config, config);
    checkAndReload(engine, paths.config);
  } catch (Exception e) {
    foreach (path, content; previous)
      writeAtomic(path, content);
    stderr.writeln("basctl proxy: apply failed, previous files restored: " ~ e.msg);
    return 1;
  }
  writeln("proxy applied: " ~ engine ~ " (" ~ paths.config ~ ")");
  return 0;
}

private void writeAtomic(string path, string content) {
  mkdirRecurse(dirName(path));
  auto temp = path ~ ".tmp";
  scope (exit) if (exists(temp)) remove(temp);
  write(temp, content);
  setPrivateFile(temp);
  rename(temp, path);
}

private void writePrivate(string path, string content) {
  writeAtomic(path, content);
}

private void checkAndReload(string engine, string config) {
  string[] check = engine == "haproxy"
      ? ["haproxy", "-c", "-f", config]
      : ["nginx", "-t", "-c", config];
  auto checkResult = execute(check);
  if (checkResult.status != 0)
    throw new Exception("config check failed: " ~ checkResult.output.strip);
  auto reload = execute(["/bin/sh", "-c", engine == "haproxy"
      ? "systemctl reload haproxy" : "systemctl reload nginx"]);
  if (reload.status != 0)
    throw new Exception("reload failed: " ~ reload.output.strip);
}

private string text(JSONValue value, string key) {
  auto item = value[key];
  return item.type == JSONType.string ? item.str : "";
}

private string sha256(string value) {
  return toHexString!(LetterCase.lower)(sha256Of(value)).idup;
}

private void proxyUsage() {
  stderr.writeln("Usage: basctl proxy apply --engine=haproxy|nginx [--endpoint=NAME] [--bundle=FILE] [--dry-run]");
  stderr.writeln("       basctl proxy status --engine=haproxy|nginx [--endpoint=NAME]");
}
