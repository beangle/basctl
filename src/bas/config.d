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
 * `server.xml`（`<Sas>`）的配置模型与解析，对应 Scala 的
 * `org.beangle.sas.config` 包（**不含 Proxy**）。
 *
 * 解析结果是一个可直接遍历的对象图：`Container` 持有 engines / hosts / farms /
 * webapps / resources，`Farm` 引用 `Engine`，`Server` 引用 `Farm` 与 `Host`，
 * `Webapp.runAt` 直接引用 `Server` 对象，与 Scala 版的引用语义一致。
 */
module bas.config;

import bas.artifact;

import std.algorithm : canFind, endsWith, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.path : buildPath;
import std.process : environment;
import std.string : empty, indexOf, lastIndexOf, replace, split, strip;
import std.typecons : Nullable, nullable;

import dxml.dom : DOMEntity, parseDOM;
import dxml.parser : EntityType;

alias XmlElem = DOMEntity!string;

/** Raised when `server.xml` is invalid or violates loader constraints. */
class ServerXmlException : Exception {
  this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) {
    super(msg, file, line, nextInChain);
  }
}

/** Tomcat / Undertow / Jetty 引擎类型常量（Scala `EngineType`）。 */
enum engineTomcat = "tomcat";
enum engineUndertow = "undertow";
enum engineJetty = "jetty";
enum engineAny = "any";

/** A `<Listener>` under `<Engine>`：类名加任意属性。 */
class Listener {
  string className;
  string[string] properties;

  this(string className) {
    this.className = className;
  }
}

/** A `<Loader>` under `<Context>`：类名加任意属性。 */
class Loader {
  string className;
  string[string] properties;

  this(string className) {
    this.className = className;
  }
}

/** A `<JarScanner>` under `<Context>`：只有属性。 */
class JarScanner {
  string[string] properties;
}

/** An optional `<Context>` under `<Engine>`. */
class Context {
  Loader loader;
  JarScanner jarScanner;
}

/**
 * An engine jar reference（`<Jar uri="...">`）。
 *
 * `uri` 可以是 `gav://`、`http(s)://` 或本地路径；`name` 按 Scala `Jar.name`
 * 的规则推导出落地文件名。
 */
class Jar {
  string uri;

  this(string uri) {
    this.uri = uri;
  }

  /** Builds a `gav://` jar from a bare coordinate when needed. */
  static Jar gav(string str) {
    if (str.canFind(gavProtocol) && isGav(str))
      return new Jar(str);
    return new Jar(gavProtocol ~ str);
  }

  /** 落地文件名：gav 取 `artifactId-version.packaging`，其余取路径最后一段。 */
  string name() const {
    if (isGav(uri)) {
      auto a = toArtifact(uri);
      return a.artifactId ~ "-" ~ a.version_ ~ "." ~ a.packaging;
    }
    if (isRemote(uri))
      return uri[lastIndexOf(uri, '/') + 1 .. $];
    return baseNameOf(uri);
  }
}

/** 路径最后一段（`std.path.baseName` 的集中封装）。 */
private string baseNameOf(string path) {
  import std.path : baseName;

  return baseName(path);
}

/** An engine definition from `<Engines><Engine>`. */
class Engine {
  string name;
  string typ;
  string version_;
  bool jspSupport;
  Listener[] listeners;
  Jar[] jars;
  Context context;

  this(string name, string typ, string version_) {
    this.name = name;
    this.typ = typ;
    this.version_ = version_;
  }

  /** Engine home directory under `SAS_HOME`. */
  string path(string sasHome) const {
    return buildPath(sasHome, "engines", name ~ "-" ~ version_);
  }

  override string toString() const {
    return name;
  }
}

/** A named host mapping（`<Hosts><Host>`）。 */
class Host {
  string name;
  string ip;

  this(string name, string ip) {
    this.name = name;
    this.ip = ip;
  }

  /** Builds a host whose name equals its ip. */
  static Host apply(string ip) {
    return new Host(ip, ip);
  }

  static Host localhost() {
    return new Host("localhost", "127.0.0.1");
  }
}

/** A keyed resource（`<Resources><Resource>`），属性原样保留。 */
class Resource {
  string name;
  string[string] properties;

  this(string name) {
    this.name = name;
  }

  string url() const {
    return property("url");
  }

  string type() const {
    return property("type");
  }

  string username() const {
    return property("username");
  }

  string password() const {
    return property("password");
  }

  string driverClassName() const {
    return property("driverClassName");
  }

  private string property(string key) const {
    auto v = key in properties;
    return v is null ? "" : *v;
  }

  override string toString() const {
    return name;
  }
}

/** HTTP connector attributes（Scala `HttpConnector`）。 */
class HttpConnector {
  string protocol = "HTTP/1.1";
  string uriEncoding = "UTF-8";
  bool enableLookups;
  Nullable!int acceptCount;
  Nullable!int maxConnections;
  int connectionTimeout = 20000;
  bool disableUploadTimeout = true;
}

/** A farm groups servers sharing one engine（`<Farm>`）。 */
class Farm {
  string name;
  Engine engine;
  HttpConnector http;
  Server[] servers;
  string maxHeapSize;
  Nullable!string serverOptions;

  this(string name, Engine engine) {
    this.name = name;
    this.engine = engine;
    this.http = new HttpConnector;
  }

  override string toString() const {
    return name;
  }
}

/** A single JVM instance under a farm（`<Server>`）。 */
class Server {
  Farm farm;
  string name;
  int http;
  Host host;
  string maxHeapSize;

  this(Farm farm, string name) {
    this.farm = farm;
    this.name = name;
  }

  /** `farm.server` qualified name（Scala `Server.qualifiedName`）。 */
  string qualifiedName() const {
    return farm.name.length ? farm.name ~ "." ~ name : name;
  }

  override string toString() const {
    return qualifiedName();
  }
}

/** A deployed web application（`<Webapp>`）。 */
class Webapp {
  string uri;
  string[string] properties;
  bool resolveSupport = true;
  string docBase;
  string realms;
  bool jspSupport;
  Server[] runAt;
  string contextPath;
  Nullable!bool unpack;
  Nullable!string libs;
  Resource[] resources;

  this(string uri) {
    this.uri = uri;
  }

  /** Names of the referenced resources, in declaration order. */
  string[] resourceNames() const {
    string[] names;
    foreach (r; resources)
      names ~= r.name;
    return names;
  }

  /** Tomcat SCI filter：禁用 JSP 时需要屏蔽 JasperInitializer。 */
  Nullable!string getContainerSciFilter(Engine engine) const {
    if (engine.typ == engineTomcat && !jspSupport)
      return nullable("JasperInitializer");
    return Nullable!string.init;
  }

  /** Normalizes a context path（Scala `Webapp.updatePath`）。 */
  void updatePath(string path) {
    auto p = strip(path);
    if (p.empty || p == "/")
      contextPath = "";
    else if (p.endsWith("/"))
      contextPath = p[0 .. $ - 1];
    else
      contextPath = p;
  }

  override string toString() const {
    return uri;
  }
}

/** 正式版仓库配置（server.xml 的 `<Repository>`）。 */
class Repository {
  Nullable!string local;
  Nullable!string remote;
  Nullable!string token;

  this() {
  }

  this(Nullable!string local, Nullable!string remote, Nullable!string token = Nullable!string.init) {
    this.local = local;
    this.remote = remote;
    this.token = token;
  }

  /** 远程仓库列表，原样透传给 jstart（不去重、不追加 Central）。 */
  string[] remotes() const {
    if (remote.isNull)
      return [];
    return splitRepos(remote.get);
  }
}

/** 开发版（SNAPSHOT）仓库配置（server.xml 的 `<SnapshotRepo>`）。 */
class SnapshotRepo {
  Nullable!string local;
  Nullable!string remote;
  Nullable!string token;

  this() {
  }

  this(Nullable!string local, Nullable!string remote, Nullable!string token = Nullable!string.init) {
    this.local = local;
    this.remote = remote;
    this.token = token;
  }

  /** 开发版上游列表；空表示不代理（调用方据此走 `--offline`）。 */
  string[] remotes() const {
    if (remote.isNull)
      return [];
    return splitRepos(remote.get);
  }
}

/** 拆分逗号分隔的仓库地址列表，丢弃空段（不追加 Central，交由 jstart 处理）。 */
private string[] splitRepos(string urls) {
  string[] res;
  foreach (part; urls.split(",")) {
    auto t = strip(part);
    if (t.length)
      res ~= t;
  }
  return res;
}

/** Parsed `server.xml` root：engines / hosts / farms / webapps / resources（Scala `Container`）。 */
class Container {
  string version_;
  Repository repository;
  SnapshotRepo snapshotRepo;
  Engine[] engines;
  Host[] hosts;
  Farm[] farms;
  Webapp[] webapps;
  Resource[string] resources;

  /** Finds an engine by name, or null. */
  Engine engine(string name) {
    foreach (e; engines) {
      if (e.name == name)
        return e;
    }
    return null;
  }

  /** Looks up a `farm.server` qualified name, or null. */
  Server getServer(string name) {
    foreach (farm; farms) {
      foreach (s; farm.servers) {
        if (s.qualifiedName == name)
          return s;
      }
    }
    return null;
  }

  /** Returns servers whose qualified name equals the pattern or is under it. */
  Server[] getMatchedServers(string pattern) {
    Server[] res;
    auto patterns = pattern.split(",");
    foreach (farm; farms) {
      foreach (s; farm.servers) {
        auto fullname = s.qualifiedName;
        foreach (oneRaw; patterns) {
          auto one = strip(oneRaw);
          if (one == fullname || fullname.startsWith(one ~ ".")) {
            res ~= s;
            break;
          }
        }
      }
    }
    return res;
  }

  /** Looks up a host by name; throws when missing. */
  Host getHost(string name) {
    foreach (h; hosts) {
      if (h.name == name)
        return h;
    }
    throw new ServerXmlException("Cannot find host " ~ name);
  }

  /** Webapps deployed to the given server, in declaration order. */
  Webapp[] getWebapps(Server server) {
    Webapp[] res;
    foreach (app; webapps) {
      foreach (s; app.runAt) {
        if (s is server) {
          res ~= app;
          break;
        }
      }
    }
    return res;
  }

  /** All declared http ports, sorted and de-duplicated. */
  int[] ports() const {
    int[] res;
    foreach (farm; farms) {
      foreach (s; farm.servers) {
        if (s.http > 0 && !res.canFind(s.http))
          res ~= s.http;
      }
    }
    res.sort();
    return res;
  }

  /** Names of all declared resources. */
  string[] resourceNames() const {
    string[] res;
    foreach (name, _; resources)
      res ~= name;
    return res;
  }

  /** Resource names referenced by webapps deployed to the given farm. */
  string[] farmResourceNames(Farm farm) const {
    string[] res;
    foreach (app; webapps) {
      if (app.runAt.length && (app.runAt[0].farm is farm)) {
        foreach (rn; app.resourceNames()) {
          if (!res.canFind(rn))
            res ~= rn;
        }
      }
    }
    return res;
  }

  /** Whether any host is neither loopback nor localhost. */
  bool hasExternHost() const {
    foreach (h; hosts) {
      if (h.ip != "127.0.0.1" && h.ip != "localhost")
        return true;
    }
    return false;
  }
}

/** Parses `server.xml` text into a `Container`（Scala `Container.apply`）. */
Container parseServerXml(string xmlText) {
  auto dom = parseDOM(xmlText);
  auto sasElem = requireRootElement(dom, "Sas");

  auto conf = new Container;
  conf.version_ = requireAttr(sasElem, "version", "<Sas>");

  // 1. repositories
  conf.repository = new Repository;
  foreach (c; elementChildren(sasElem)) {
    if (c.name == "Repository")
      conf.repository = parseRepository(c);
    else if (c.name == "SnapshotRepo")
      conf.snapshotRepo = parseSnapshotRepo(c);
  }
  if (conf.snapshotRepo is null)
    conf.snapshotRepo = new SnapshotRepo;

  // 2. engines
  foreach (section; elementChildren(sasElem)) {
    switch (section.name) {
    case "Engines":
      foreach (e; elementChildren(section)) {
        if (e.name == "Engine")
          conf.engines ~= parseEngine(e);
      }
      break;
    case "Hosts":
      foreach (h; elementChildren(section)) {
        if (h.name == "Host")
          conf.hosts ~= parseHost(h);
      }
      break;
    case "Resources":
      foreach (r; elementChildren(section)) {
        if (r.name == "Resource") {
          auto res = parseResource(r);
          conf.resources[res.name] = res;
        }
      }
      break;
    case "Farms":
      foreach (f; elementChildren(section)) {
        if (f.name == "Farm")
          conf.farms ~= parseFarm(conf, f);
      }
      break;
    case "Webapps":
      foreach (w; elementChildren(section)) {
        if (w.name == "Webapp")
          conf.webapps ~= parseWebapp(conf, w);
      }
      break;
    default:
      break;
    }
  }

  if (!conf.hosts.length)
    conf.hosts ~= Host.localhost();

  return conf;
}

/** Reads the file path then delegates to `parseServerXml`. */
Container parseServerXmlFile(string path) {
  import std.file : readText;

  return parseServerXml(readText(path));
}

private:

/** 仅返回子元素节点，忽略文本与注释。 */
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

/** 在 DOM 根下查找指定名称的文档元素，否则抛 `ServerXmlException`。 */
XmlElem requireRootElement(XmlElem docRoot, string elemName) {
  foreach (c; elementChildren(docRoot)) {
    if (c.name == elemName)
      return c;
  }
  throw new ServerXmlException("Missing <" ~ elemName ~ "> document element");
}

/** 属性的不变字符串副本（dxml 的 `value` 是原缓冲切片）。 */
string attrText(XmlElem.Attribute a) {
  return a.value.idup;
}

/** 可选属性：缺失时返回空 `Nullable`。 */
Nullable!string optAttr(XmlElem elem, string name) {
  foreach (a; elem.attributes) {
    if (a.name == name)
      return nullable(attrText(a));
  }
  return Nullable!string.init;
}

/** 必需属性：缺失时抛 `ServerXmlException`，`where` 用于错误提示。 */
string requireAttr(XmlElem elem, string name, string where) {
  auto v = optAttr(elem, name);
  enforce!ServerXmlException(!v.isNull, format!"Missing attribute '%s' on %s"(name, where));
  return v.get;
}

/** Wraps an optional attribute into a `Nullable` holding only non-blank text. */
Nullable!string nonBlankAttr(XmlElem elem, string name) {
  auto v = optAttr(elem, name);
  if (v.isNull || strip(v.get).empty)
    return Nullable!string.init;
  return nullable(strip(v.get));
}

/** 解析正式版 `<Repository>`：本地目录、远端地址与可选令牌。 */
Repository parseRepository(XmlElem elem) {
  auto local = nonBlankAttr(elem, "local");
  auto remote = nonBlankAttr(elem, "remote");
  auto token = resolveToken(optAttr(elem, "token"));
  return new Repository(local, remote, token);
}

/** 解析开发版 `<SnapshotRepo>`：`remote` 先展开 `${sas_remote_url}`。 */
SnapshotRepo parseSnapshotRepo(XmlElem elem) {
  auto local = nonBlankAttr(elem, "local");
  auto remote = expandSasRemoteUrl(nonBlankAttr(elem, "remote"));
  auto token = resolveToken(optAttr(elem, "token"));
  return new SnapshotRepo(local, remote, token);
}

/** 解析仓库的 `token` 属性，支持 `${sas_remote_token}` 占位。 */
Nullable!string resolveToken(Nullable!string token) {
  if (token.isNull || strip(token.get).empty)
    return Nullable!string.init;
  auto result = token.get;
  enum marker = "${sas_remote_token}";
  if (result.canFind(marker)) {
    auto envToken = environment.get("sas_remote_token", "");
    if (envToken.empty)
      return Nullable!string.init;
    result = result.replace(marker, envToken);
  }
  if (strip(result).empty)
    return Nullable!string.init;
  return nullable(result);
}

/** 展开 `${sas_remote_url}`，取到 `/api/` 之前；离线时返回空。 */
Nullable!string expandSasRemoteUrl(Nullable!string remote) {
  if (remote.isNull)
    return Nullable!string.init;
  enum marker = "${sas_remote_url}";
  auto value = remote.get;
  if (!value.canFind(marker))
    return nullable(value);
  auto remoteUrl = environment.get("sas_remote_url", "");
  if (remoteUrl.empty)
    return Nullable!string.init;
  auto cut = remoteUrl.indexOf("/api/");
  if (cut >= 0)
    remoteUrl = remoteUrl[0 .. cut];
  return nullable(value.replace(marker, remoteUrl));
}

/** 解析 `<Engine>` 及其 `<Listener>` / `<Context>` / `<Jar>` 子节点。 */
Engine parseEngine(XmlElem elem) {
  auto e = new Engine(requireAttr(elem, "name", "<Engine>"),
      requireAttr(elem, "type", "<Engine>"),
      requireAttr(elem, "version", "<Engine>"));
  auto jsp = optAttr(elem, "jspSupport");
  e.jspSupport = !jsp.isNull && jsp.get == "true";

  foreach (c; elementChildren(elem)) {
    switch (c.name) {
    case "Listener":
      auto l = new Listener(requireAttr(c, "className", "<Listener>"));
      l.properties = attrsExcept(c, ["className"]);
      e.listeners ~= l;
      break;
    case "Context":
      auto ctx = new Context;
      foreach (x; elementChildren(c)) {
        if (x.name == "Loader") {
          auto ld = new Loader(requireAttr(x, "className", "<Loader>"));
          ld.properties = attrsExcept(x, ["className"]);
          ctx.loader = ld;
        } else if (x.name == "JarScanner") {
          auto js = new JarScanner;
          js.properties = attrsExcept(x, []);
          ctx.jarScanner = js;
        }
      }
      e.context = ctx;
      break;
    case "Jar":
      e.jars ~= new Jar(requireAttr(c, "uri", "<Jar>"));
      break;
    default:
      break;
    }
  }
  return e;
}

/** 解析 `<Host>`（名称 + 绑定 IP）。 */
Host parseHost(XmlElem elem) {
  return new Host(requireAttr(elem, "name", "<Host>"), requireAttr(elem, "ip", "<Host>"));
}

/** 解析 `<Resource>`：`name` 单独取出，其余属性原样透传给 Tomcat。 */
Resource parseResource(XmlElem elem) {
  auto r = new Resource(requireAttr(elem, "name", "<Resource>"));
  r.properties = attrsExcept(elem, ["name"]);
  return r;
}

/** 解析 `<Farm>`：绑定引擎、`ServerOptions`，并递归解析各 `<Server>`。 */
Farm parseFarm(Container conf, XmlElem elem) {
  auto name = requireAttr(elem, "name", "<Farm>");
  enforce!ServerXmlException(!name.canFind('.'), "farm name " ~ name ~ " cannot contains dot");
  auto engName = requireAttr(elem, "engine", "<Farm>");
  auto eng = conf.engine(engName);
  enforce!ServerXmlException(eng !is null, "Cannot find engine for " ~ engName);

  auto farm = new Farm(name, eng);
  auto mhs = nonBlankAttr(elem, "maxHeapSize");
  farm.maxHeapSize = mhs.isNull ? "300M" : mhs.get;

  auto serverOptions = findFirstChildText(elem, "ServerOptions");
  if (serverOptions.length)
    farm.serverOptions = nullable(expandServerOptionsEnv(serverOptions));

  foreach (c; elementChildren(elem)) {
    if (c.name == "Http")
      readHttpConnector(c, farm.http);
    else if (c.name == "Server")
      farm.servers ~= parseServer(conf, farm, c);
  }

  foreach (s; farm.servers) {
    if (s.maxHeapSize.empty)
      s.maxHeapSize = farm.maxHeapSize;
  }
  return farm;
}

/** 展开 `ServerOptions` 中的 `${sas_remote_url}`；环境变量缺失时原样返回。 */
string expandServerOptionsEnv(string opts) {
  enum marker = "${sas_remote_url}";
  auto trimmed = trimLines(opts);
  if (!trimmed.canFind(marker))
    return trimmed;
  auto remoteUrl = environment.get("sas_remote_url", "");
  if (remoteUrl.empty)
    return trimmed;
  return trimmed.replace(marker, remoteUrl);
}

/** 解析 `<Server>`：http 端口、host 归属与堆大小（缺省继承 farm）。 */
Server parseServer(Container conf, Farm farm, XmlElem elem) {
  auto s = new Server(farm, requireAttr(elem, "name", "<Server>"));
  s.http = parseIntAttr(elem, "http", 0);

  auto hostName = nonBlankAttr(elem, "host");
  s.host = hostName.isNull ? Host.localhost() : conf.getHost(hostName.get);

  auto mhs = nonBlankAttr(elem, "maxHeapSize");
  s.maxHeapSize = mhs.isNull ? farm.maxHeapSize : mhs.get;
  return s;
}

/** 读取 `<Http>` 上的连接器参数，只覆盖显式给出的项。 */
void readHttpConnector(XmlElem elem, HttpConnector http) {
  auto el = optAttr(elem, "enableLookups");
  if (!el.isNull)
    http.enableLookups = el.get == "true";

  auto ac = optPositiveIntAttr(elem, "acceptCount");
  if (!ac.isNull)
    http.acceptCount = ac;

  auto mc = optPositiveIntAttr(elem, "maxConnections");
  if (!mc.isNull)
    http.maxConnections = mc;

  auto dut = optAttr(elem, "disableUploadTimeout");
  if (!dut.isNull)
    http.disableUploadTimeout = dut.get == "true";

  auto ct = optPositiveIntAttr(elem, "connectionTimeout");
  if (!ct.isNull)
    http.connectionTimeout = ct.get;
}

Webapp parseWebapp(Container conf, XmlElem elem) {
  auto w = new Webapp(requireAttr(elem, "uri", "<Webapp>"));

  static immutable reserved = ["name", "uri", "reloadable", "path", "runAt", "docBase", "libs", "jspSupport"];
  w.properties = attrsExcept(elem, reserved);

  auto jsp = optAttr(elem, "jspSupport");
  w.jspSupport = !jsp.isNull && jsp.get == "true";

  auto libs = nonBlankAttr(elem, "libs");
  if (!libs.isNull)
    w.libs = libs;

  foreach (c; elementChildren(elem)) {
    if (c.name == "ResourceRef") {
      auto refName = requireAttr(c, "ref", "<ResourceRef>");
      auto res = refName in conf.resources;
      enforce!ServerXmlException(res !is null, "Missing resource ref '" ~ refName ~ "' for webapp " ~ w.uri);
      w.resources ~= *res;
    } else if (c.name == "Realm") {
      w.realms = "<Realm " ~ renderAttrs(c) ~ "/>";
    } else if (c.name == "resolveSupport") {
      w.resolveSupport = strip(deepText(c)) == "true";
    }
  }

  w.updatePath(nonBlankAttr(elem, "path").isNull ? "" : nonBlankAttr(elem, "path").get);

  auto runAt = optAttr(elem, "runAt");
  if (!runAt.isNull) {
    foreach (token; splitRunTokens(runAt.get)) {
      Farm matchedFarm;
      foreach (f; conf.farms) {
        if (f.name == token) {
          matchedFarm = f;
          break;
        }
      }
      if (matchedFarm !is null) {
        w.runAt ~= matchedFarm.servers;
      } else {
        auto server = conf.getServer(token);
        enforce!ServerXmlException(server !is null, "Cannot find server named " ~ token);
        w.runAt ~= server;
      }
    }
  }

  auto unpack = optAttr(elem, "unpack");
  if (!unpack.isNull && !strip(unpack.get).empty)
    w.unpack = nullable(strip(unpack.get) == "true");

  return w;
}

/** 把元素属性原样重排，供 `<Realm .../>` 这类模板片段复用。 */
string renderAttrs(XmlElem elem) {
  string[] parts;
  foreach (a; elem.attributes)
    parts ~= a.name ~ "=\"" ~ attrText(a) ~ "\"";
  return parts.join(" ");
}

/** 收集除 `exclude` 之外的属性，构造 Tomcat 透传属性表（有序性不敏感）。 */
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

/** 第一个同名子节点的文本内容（逐行 strip 后保留换行）。 */
string findFirstChildText(XmlElem parent, string childName) {
  foreach (c; elementChildren(parent)) {
    if (c.name == childName)
      return trimLines(deepText(c));
  }
  return "";
}

/** 递归收集节点内所有文本片段（dxml 的文本散落在子节点里）。 */
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

/** 去掉每行首尾空白，保留换行结构。 */
string trimLines(string content) {
  return content.split("\n").map!(l => strip(l)).array.join("\n");
}

/** 逗号分隔的 `runAt` 目标（farm 名或 `farm.server` 限定名）。 */
string[] splitRunTokens(string runAt) {
  import std.regex : regex, split;

  static auto re = regex(r"\s*,\s*");
  string[] res;
  foreach (p; split(runAt, re)) {
    auto t = strip(p);
    if (!t.empty)
      res ~= t;
  }
  return res;
}

/** 读取整数属性，缺失或空串时用 `defaultValue`。 */
int parseIntAttr(XmlElem elem, string name, int defaultValue) {
  auto v = nonBlankAttr(elem, name);
  if (v.isNull)
    return defaultValue;
  return to!int(v.get);
}

/** 读取整数属性；缺失时返回空，用于「只覆盖显式配置」的参数。 */
Nullable!int optPositiveIntAttr(XmlElem elem, string name) {
  auto v = nonBlankAttr(elem, name);
  if (v.isNull)
    return Nullable!int.init;
  return nullable(to!int(v.get));
}
