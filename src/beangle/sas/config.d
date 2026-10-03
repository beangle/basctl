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

module beangle.sas.config;

import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.format : format;
import std.string : empty, indexOf, join, replace, split, strip;
import std.typecons : Nullable, nullable;

import dxml.dom : DOMEntity, parseDOM;
import dxml.parser : EntityType;

alias XmlElem = DOMEntity!string;

/** Maven-style engine jar reference (`gav://…` or other URI). */
struct JarRef {
  string uri;
}

/** Optional `<Listener>` under `<Engine>`. */
struct ListenerModel {
  string className;
  string[string] properties;
}

/** Optional `<Loader>` under `<Context>`. */
struct LoaderModel {
  string className;
  string[string] properties;
}

/** Optional `<JarScanner>` under `<Context>`. */
struct JarScannerModel {
  string[string] properties;
}

/** Optional `<Context>` under `<Engine>`. */
struct ContextModel {
  Nullable!LoaderModel loader;
  Nullable!JarScannerModel jarScanner;
}

/** Tomcat / Jetty / … engine definition from `<Engines>`. */
struct EngineModel {
  string name;
  string typ;
  string version_;
  bool jspSupport;
  ListenerModel[] listeners;
  JarRef[] jars;
  Nullable!ContextModel context;
}

/** `<Repository>` local / remote pair (aligned with Scala `Repository`). */
struct RepositoryModel {
  Nullable!string local;
  Nullable!string remote;
}

/** `<SnapshotRepo>` pair (aligned with Scala `SnapshotRepo`). */
struct SnapshotRepoModel {
  Nullable!string local;
  Nullable!string remote;
}

/** `<Hosts><Host>` entry. */
struct HostModel {
  string name;
  string ip;
}

/** `<Resources><Resource>` generic keyed resource. */
struct ResourceModel {
  string name;
  string[string] properties;
}

/** HTTP connector attributes mirrored from Scala `readHttpConnector`. */
struct HttpConnectorModel {
  bool enableLookups;
  Nullable!int acceptCount;
  int maxThreads = 200;
  Nullable!int maxConnections;
  int minSpareThreads = 10;
  bool disableUploadTimeout = true;
  int connectionTimeout = 20000;
  string compression = "off";
  int compressionMinSize = 2048;
  string compressionMimeType = "text/html,text/xml,text/javascript,text/css,text/plain";
}

/** Optional HTTP/2 connector with TLS file hints. */
struct Http2ConnectorModel {
  HttpConnectorModel http;
  string caKeyFile;
  string caFile;
}

/** Single JVM instance under a farm (`<Server>`). */
struct ServerModel {
  string farmName;
  string name;
  int http;
  int http2;
  /** Empty means bind default host (`localhost` / `127.0.0.1`). */
  string hostName;
  string maxHeapSize;
  Nullable!bool enableAccessLog;
  Nullable!int proxyHttpPort;
  Nullable!string proxyOptions;

  /** Returns `farm.server` qualified name (Scala `Server.qualifiedName`). */
  string qualifiedName() const scope @safe {
    return farmName.length ? farmName ~ "." ~ name : name;
  }
}

/** Farm groups servers sharing one engine (`<Farm>`). */
struct FarmModel {
  string name;
  string engineName;
  string maxHeapSize;
  Nullable!bool enableAccessLog;
  Nullable!string serverOptions;
  Nullable!string proxyOptions;
  HttpConnectorModel http;
  Nullable!Http2ConnectorModel http2;
  ServerModel[] servers;
}

/** Deployed web application (`<Webapp>`). */
struct WebappModel {
  string uri;
  /** Optional display name from `@name`. */
  string displayName;
  /** Normalized context path (Scala `Webapp.updatePath`). */
  string contextPath;
  /** Raw `@runAt` before resolution. */
  string runAtRaw;
  Nullable!bool unpack;
  Nullable!string libs;
  bool resolveSupport = true;
  string[string] extraAttributes;
  string[] resourceRefNames;
  /** Populated by `resolveWebappRunAt`. */
  string[] runAtQualifiedServers;
}

/** Top-level document matching `server.xml` `<Sas>` (Scala `Container` subset). */
struct SasConfig {
  string version_;
  Nullable!int sasPort;
  RepositoryModel repository;
  SnapshotRepoModel snapshotRepo;
  EngineModel[] engines;
  HostModel[] hosts;
  ResourceModel[] resources;
  FarmModel[] farms;
  WebappModel[] webapps;
}

/** Raised when `server.xml` is invalid or violates loader constraints. */
class ServerXmlException : Exception {
  this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) {
    super(msg, file, line, nextInChain);
  }
}

/** Parses `server.xml` text into `SasConfig` (Scala `Container.apply` analogue). */
SasConfig parseServerXml(string xmlText) {
  auto dom = parseDOM(xmlText);
  auto sasElem = requireRootElement(dom, "Sas");
  SasConfig cfg;
  cfg.version_ = requireAttr(sasElem, "version", "<Sas>");
  cfg.sasPort = optPositiveIntAttr(sasElem, "port");

  foreach (c; elementChildren(sasElem)) {
    switch (c.name) {
    case "Repository":
      cfg.repository = parseRepository(c);
      break;
    case "SnapshotRepo":
      cfg.snapshotRepo = parseSnapshotRepo(c);
      break;
    case "Engines":
      foreach (eng; elementChildren(c))
        if (eng.name == "Engine")
          cfg.engines ~= parseEngine(eng);
      break;
    case "Hosts":
      foreach (h; elementChildren(c))
        if (h.name == "Host")
          cfg.hosts ~= parseHost(h);
      break;
    case "Resources":
      foreach (r; elementChildren(c))
        if (r.name == "Resource")
          cfg.resources ~= parseResource(r);
      break;
    case "Farms":
      foreach (f; elementChildren(c))
        if (f.name == "Farm")
          cfg.farms ~= parseFarm(cfg, f);
      break;
    case "Webapps":
      foreach (w; elementChildren(c))
        if (w.name == "Webapp")
          cfg.webapps ~= parseWebapp(cfg, w);
      break;
    default:
      break;
    }
  }

  if (!cfg.hosts.length)
    cfg.hosts = [HostModel("localhost", "127.0.0.1")];

  resolveWebappRunAt(cfg);
  return cfg;
}

/** Reads the file path then delegates to `parseServerXml`. */
SasConfig parseServerXmlFile(string path) {
  return parseServerXml(readText(path));
}

/** Expands `@runAt` into concrete `farm.server` names (Scala webapp registration). */
void resolveWebappRunAt(ref SasConfig cfg) {
  foreach (ref app; cfg.webapps) {
    app.runAtQualifiedServers.length = 0;
    foreach (part; splitRunTokens(app.runAtRaw)) {
      auto tok = strip(part);
      if (tok.empty)
        continue;
      auto farmHit = findFarm(cfg, tok);
      if (!farmHit.isNull) {
        foreach (s; farmHit.get.servers)
          app.runAtQualifiedServers ~= s.qualifiedName;
        continue;
      }
      auto srv = findServer(cfg, tok);
      enforce!ServerXmlException(!srv.isNull, "Cannot find server named " ~ tok);
      app.runAtQualifiedServers ~= srv.get.qualifiedName;
    }
  }
}

/** Finds an engine by `@name`, or `Nullable.null`. */
Nullable!EngineModel findEngine(SasConfig cfg, string engineName) {
  foreach (ref e; cfg.engines) {
    if (e.name == engineName)
      return nullable(e);
  }
  return Nullable!EngineModel.init;
}

/** Finds a farm by `@name`, or `Nullable.null`. */
Nullable!FarmModel findFarm(SasConfig cfg, string farmName) {
  foreach (ref f; cfg.farms) {
    if (f.name == farmName)
      return nullable(f);
  }
  return Nullable!FarmModel.init;
}

/** Looks up `farm.server` qualified name (Scala `Container.getServer`). */
Nullable!ServerModel findServer(SasConfig cfg, string qualified) {
  foreach (ref farm; cfg.farms) {
    foreach (ref s; farm.servers) {
      if (s.qualifiedName == qualified)
        return nullable(s);
    }
  }
  return Nullable!ServerModel.init;
}

private:

XmlElem[] elementChildren(XmlElem parent) {
  XmlElem[] res;
  if (parent.type != EntityType.elementStart)
    return res;
  foreach (c; parent.children) {
    if (c.type == EntityType.elementStart || c.type == EntityType.elementEmpty)
      res ~= c;
  }
  return res;
}

XmlElem requireRootElement(XmlElem docRoot, string elemName) {
  foreach (c; elementChildren(docRoot)) {
    if (c.name == elemName)
      return c;
  }
  throw new ServerXmlException("Missing <" ~ elemName ~ "> document element");
}

string attrText(XmlElem.Attribute a) {
  return a.value.idup;
}

Nullable!string optAttr(XmlElem elem, string name) {
  foreach (a; elem.attributes) {
    if (a.name == name)
      return nullable(attrText(a));
  }
  return Nullable!string.init;
}

string requireAttr(XmlElem elem, string name, string where) {
  auto v = optAttr(elem, name);
  enforce!ServerXmlException(!v.isNull, format!"Missing attribute '%s' on %s"(name, where));
  return v.get;
}

Nullable!int optPositiveIntAttr(XmlElem elem, string name) {
  auto v = optAttr(elem, name);
  if (v.isNull)
    return Nullable!int.init;
  auto s = strip(v.get);
  if (s.empty)
    return Nullable!int.init;
  return nullable(to!int(s));
}

RepositoryModel parseRepository(XmlElem elem) {
  RepositoryModel r;
  r.local = optAttr(elem, "local");
  r.remote = optAttr(elem, "remote");
  return r;
}

SnapshotRepoModel parseSnapshotRepo(XmlElem elem) {
  SnapshotRepoModel r;
  r.local = optAttr(elem, "local");
  auto remote = optAttr(elem, "remote");
  if (!remote.isNull) {
    auto expanded = expandSasRemoteUrl(remote.get);
    if (expanded.isNull)
      r.remote = Nullable!string.init;
    else
      r.remote = expanded;
  }
  return r;
}

Nullable!string expandSasRemoteUrl(string remote) {
  enum marker = "${sas_remote_url}";
  if (!remote.canFind(marker))
    return nullable(remote);
  import std.process : environment;

  auto remoteUrl = environment.get("sas_remote_url", "");
  if (remoteUrl.empty) {
    return Nullable!string.init;
  }
  auto cut = remoteUrl.indexOf("/api/");
  if (cut >= 0)
    remoteUrl = remoteUrl[0 .. cut];
  return nullable(remote.replace(marker, remoteUrl));
}

EngineModel parseEngine(XmlElem elem) {
  EngineModel e;
  e.name = requireAttr(elem, "name", "<Engine>");
  e.typ = requireAttr(elem, "type", "<Engine>");
  e.version_ = requireAttr(elem, "version", "<Engine>");
  auto jsp = optAttr(elem, "jspSupport");
  e.jspSupport = !jsp.isNull && jsp.get == "true";

  foreach (c; elementChildren(elem)) {
    switch (c.name) {
    case "Listener":
      ListenerModel l;
      l.className = requireAttr(c, "className", "<Listener>");
      l.properties = attrsExcept(c, ["className"]);
      e.listeners ~= l;
      break;
    case "Context":
      ContextModel ctx;
      foreach (x; elementChildren(c)) {
        if (x.name == "Loader") {
          LoaderModel ld;
          ld.className = requireAttr(x, "className", "<Loader>");
          ld.properties = attrsExcept(x, ["className"]);
          ctx.loader = nullable(ld);
        } else if (x.name == "JarScanner") {
          JarScannerModel js;
          js.properties = attrsExcept(x, []);
          ctx.jarScanner = nullable(js);
        }
      }
      e.context = nullable(ctx);
      break;
    case "Jar":
      e.jars ~= JarRef(requireAttr(c, "uri", "<Jar>"));
      break;
    default:
      break;
    }
  }
  return e;
}

HostModel parseHost(XmlElem elem) {
  return HostModel(requireAttr(elem, "name", "<Host>"), requireAttr(elem, "ip", "<Host>"));
}

ResourceModel parseResource(XmlElem elem) {
  ResourceModel r;
  r.name = requireAttr(elem, "name", "<Resource>");
  r.properties = attrsExcept(elem, ["name"]);
  return r;
}

FarmModel parseFarm(ref SasConfig cfg, XmlElem elem) {
  FarmModel farm;
  farm.name = requireAttr(elem, "name", "<Farm>");
  enforce!ServerXmlException(!farm.name.canFind('.'),
      format!"farm name %s cannot contains dot"(farm.name));
  farm.engineName = requireAttr(elem, "engine", "<Farm>");
  auto eng = findEngine(cfg, farm.engineName);
  enforce!ServerXmlException(!eng.isNull, "Cannot find engine for " ~ farm.engineName);

  auto mhs = optAttr(elem, "maxHeapSize");
  farm.maxHeapSize = mhs.isNull || strip(mhs.get).empty ? "300M" : strip(mhs.get);

  auto eal = optAttr(elem, "enableAccessLog");
  if (!eal.isNull)
    farm.enableAccessLog = nullable(eal.get == "true");

  auto srvOpts = findFirstChildText(elem, "ServerOptions");
  if (!srvOpts.empty)
    farm.serverOptions = nullable(expandServerOptionsEnv(srvOpts));

  auto proxyOptsElem = findFirstChildText(elem, "ProxyOptions");
  if (!proxyOptsElem.empty)
    farm.proxyOptions = nullable(trimLines(proxyOptsElem));

  foreach (c; elementChildren(elem)) {
    if (c.name == "Http") {
      parseHttpConnector(farm.http, c);
    } else if (c.name == "Http2") {
      Http2ConnectorModel h2;
      parseHttpConnector(h2.http, c);
      auto ck = optAttr(c, "caKeyFile");
      if (!ck.isNull)
        h2.caKeyFile = ck.get;
      auto cf = optAttr(c, "caFile");
      if (!cf.isNull)
        h2.caFile = cf.get;
      farm.http2 = nullable(h2);
    } else if (c.name == "Server") {
      farm.servers ~= parseServer(farm, c);
    }
  }

  foreach (ref s; farm.servers) {
    if (s.enableAccessLog.isNull && !farm.enableAccessLog.isNull)
      s.enableAccessLog = farm.enableAccessLog;
    if (s.maxHeapSize.empty)
      s.maxHeapSize = farm.maxHeapSize;
  }

  return farm;
}

string expandServerOptionsEnv(string opts) {
  enum marker = "${sas_remote_url}";
  auto trimmed = trimLines(opts);
  if (!trimmed.canFind(marker))
    return trimmed;
  import std.process : environment;

  auto remoteUrl = environment.get("sas_remote_url", "");
  if (remoteUrl.empty)
    return trimmed;
  return trimmed.replace(marker, remoteUrl);
}

ServerModel parseServer(FarmModel farm, XmlElem elem) {
  ServerModel s;
  s.farmName = farm.name;
  s.name = requireAttr(elem, "name", "<Server>");
  s.http = parseIntAttr(elem, "http", 0);
  s.http2 = parseIntAttr(elem, "http2", 0);

  auto host = optAttr(elem, "host");
  s.hostName = host.isNull ? "" : strip(host.get);

  auto se = optAttr(elem, "enableAccessLog");
  if (!se.isNull)
    s.enableAccessLog = nullable(se.get == "true");

  auto sm = optAttr(elem, "maxHeapSize");
  s.maxHeapSize = sm.isNull ? "" : strip(sm.get);

  auto po = optAttr(elem, "proxyOptions");
  if (!po.isNull && !strip(po.get).empty)
    s.proxyOptions = nullable(strip(po.get));

  auto php = optAttr(elem, "proxyHttpPort");
  if (!php.isNull && !strip(php.get).empty)
    s.proxyHttpPort = nullable(to!int(strip(php.get)));

  return s;
}

void parseHttpConnector(ref HttpConnectorModel http, XmlElem elem) {
  auto el = optAttr(elem, "enableLookups");
  if (!el.isNull)
    http.enableLookups = el.get == "true";

  auto ac = optAttr(elem, "acceptCount");
  if (!ac.isNull && !strip(ac.get).empty)
    http.acceptCount = nullable(to!int(strip(ac.get)));

  auto mt = optAttr(elem, "maxThreads");
  if (!mt.isNull && !strip(mt.get).empty)
    http.maxThreads = to!int(strip(mt.get));

  auto mc = optAttr(elem, "maxConnections");
  if (!mc.isNull && !strip(mc.get).empty)
    http.maxConnections = nullable(to!int(strip(mc.get)));

  auto ms = optAttr(elem, "minSpareThreads");
  if (!ms.isNull && !strip(ms.get).empty)
    http.minSpareThreads = to!int(strip(ms.get));

  auto dut = optAttr(elem, "disableUploadTimeout");
  if (!dut.isNull)
    http.disableUploadTimeout = dut.get == "true";

  auto ct = optAttr(elem, "connectionTimeout");
  if (!ct.isNull && !strip(ct.get).empty)
    http.connectionTimeout = to!int(strip(ct.get));

  auto cp = optAttr(elem, "compression");
  if (!cp.isNull && !strip(cp.get).empty)
    http.compression = strip(cp.get);

  auto cms = optAttr(elem, "compressionMinSize");
  if (!cms.isNull && !strip(cms.get).empty)
    http.compressionMinSize = to!int(strip(cms.get));

  auto cmt = optAttr(elem, "compressionMimeType");
  if (!cmt.isNull && !strip(cmt.get).empty)
    http.compressionMimeType = strip(cmt.get);
}

WebappModel parseWebapp(ref SasConfig cfg, XmlElem elem) {
  WebappModel w;
  w.uri = requireAttr(elem, "uri", "<Webapp>");
  auto dn = optAttr(elem, "name");
  w.displayName = dn.isNull ? "" : dn.get;

  static immutable reserved = ["name", "uri", "reloadable", "path", "runAt", "docBase", "libs"];
  w.extraAttributes = attrsExcept(elem, reserved);

  auto libs = optAttr(elem, "libs");
  if (!libs.isNull && !strip(libs.get).empty)
    w.libs = nullable(strip(libs.get));

  auto path = optAttr(elem, "path");
  w.contextPath = normalizeContextPath(path.isNull ? "" : path.get);

  auto runAtAttr = optAttr(elem, "runAt");
  w.runAtRaw = runAtAttr.isNull ? "" : runAtAttr.get;
  foreach (c; elementChildren(elem)) {
    if (c.name == "ResourceRef") {
      w.resourceRefNames ~= requireAttr(c, "ref", "<ResourceRef>");
    } else if (c.name == "Realm") {
      /* Realm markup not retained (unused by control-plane bootstrap); extend if needed. */
    } else if (c.name == "resolveSupport") {
      w.resolveSupport = strip(deepText(c)).to!bool;
    }
  }

  auto unpack = optAttr(elem, "unpack");
  if (!unpack.isNull && !strip(unpack.get).empty)
    w.unpack = nullable(to!bool(strip(unpack.get)));

  foreach (rn; w.resourceRefNames) {
    bool ok;
    foreach (r; cfg.resources) {
      if (r.name == rn) {
        ok = true;
        break;
      }
    }
    enforce!ServerXmlException(ok, "Missing resource ref '" ~ rn ~ "' for webapp " ~ w.uri);
  }

  return w;
}

string normalizeContextPath(string path) {
  import std.algorithm : endsWith;

  auto p = strip(path);
  if (p.empty || p == "/")
    return "";
  if (p.endsWith("/"))
    return p[0 .. $ - 1];
  return p;
}

string[string] attrsExcept(XmlElem elem, const(string)[] exclude) {
  string[string] map;
  outer: foreach (a; elem.attributes) {
    auto an = a.name.idup;
    foreach (ex; exclude) {
      if (an == ex)
        continue outer;
    }
    map[an] = attrText(a);
  }
  return map;
}

string findFirstChildText(XmlElem parent, string childName) {
  foreach (c; elementChildren(parent)) {
    if (c.name == childName)
      return trimLines(deepText(c));
  }
  return "";
}

string deepText(XmlElem n) {
  import std.array : appender;

  auto w = appender!string;
  void walk(XmlElem x) {
    if (x.type == EntityType.text)
      w.put(x.text);
    if (x.type != EntityType.elementStart)
      return;
    foreach (ch; x.children)
      walk(ch);
  }

  walk(n);
  return w.data;
}

string trimLines(string content) {
  return content.split("\n").map!(l => strip(l)).array.join("\n");
}

string[] splitRunTokens(string runAt) {
  import std.regex : regex, split;

  static auto re = regex(r"\s*,\s*");
  auto parts = split(runAt, re);
  string[] res;
  foreach (p; parts) {
    auto t = strip(p);
    if (!t.empty)
      res ~= t;
  }
  return res;
}

int parseIntAttr(XmlElem elem, string name, int defaultValue) {
  auto v = optAttr(elem, name);
  if (v.isNull || strip(v.get).empty)
    return defaultValue;
  return to!int(strip(v.get));
}
