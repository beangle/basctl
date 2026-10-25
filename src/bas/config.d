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
 * `server.xml`（`<bas>`）的配置模型与解析（不含 Proxy）。格式定义见 `resources/bas-1.0.0.xsd`。
 *
 * 解析结果是一个可直接遍历的对象图：`Container` 持有 engines / hosts / farms /
 * webapps / resources 与可选的 setline 配置，`Farm` 引用 `Engine`，`Server` 引用
 * `Farm` 与 `Host`，`Webapp.runAt` 直接引用 `Server` 对象。
 */
module bas.config;

import bas.artifact;
import bas.endpoint : parseSetlinePort;
import bas.remote : RemoteConfig, remoteBaseUrl, remoteConfForServerXml;

import std.algorithm : canFind, endsWith, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.path : absolutePath;
import std.string : empty, indexOf, lastIndexOf, replace, split, strip, toLower;
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

/**
 * `<engine type>`：直接给出容器的运行形态，与 creator 名一一对应
 * （`basctl make <type>` / `engines.ini` 分节同名）。
 *
 * `tomcat-server` 走全量发行包（多应用），`tomcat` / `undertow` / `jetty` 是嵌入式单应用。
 */
enum containerTypeTomcatServer = "tomcat-server";
enum containerTypeTomcat = "tomcat";
enum containerTypeUndertow = "undertow";
enum containerTypeJetty = "jetty";
enum containerTypeNative = "native";

/**
 * setline 的缺省命名空间：`*` 匹配任意 Host，用 IP 或任意域名访问都能命中。
 * 多份 `BAS_HOME` 共享同一个 setline 时，各自显式写域名分组，避免互相整组覆盖。
 */
enum defaultSetlineHostname = "*";

/** 支持的引擎类型。`tomcat-server` 与 `tomcat` 是前缀关系，解析时按最长类型匹配。 */
enum supportedEngineTypes = [containerTypeTomcatServer, containerTypeTomcat, containerTypeUndertow,
  containerTypeJetty, containerTypeNative];

/** 是否 tomcat 系（JSP/SCI 等 tomcat 专有处理只对它们生效）。 */
bool isTomcatType(string typ) {
  return typ == containerTypeTomcatServer || typ == containerTypeTomcat;
}

/** A `<listener>` under `<engine>`：类名加任意属性。 */
class Listener {
  string className;
  string[string] properties;

  this(string className) {
    this.className = className;
  }
}

/** A `<loader>` under `<context>`：类名加任意属性。 */
class Loader {
  string className;
  string[string] properties;

  this(string className) {
    this.className = className;
  }
}

/** A `<jar-scanner>` under `<context>`：只有属性。 */
class JarScanner {
  string[string] properties;
}

/** An optional `<context>` under `<engine>`. */
class Context {
  Loader loader;
  JarScanner jarScanner;
}

/**
 * An engine jar reference（`<jar uri="...">`）。
 *
 * `uri` 可以是 `gav://`、`http(s)://` 或本地路径；`name` 推导出落地文件名。
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

/** An engine definition from `<engines><engine>`. */
class Engine {
  string name;
  /** 运行形态：`tomcat-server` / `tomcat` / `undertow` / `jetty`，见 {@link supportedEngineTypes}。 */
  string typ;
  /** 容器版本：tomcat 为发行包版本，undertow 为 undertow-servlet 版本，jetty 为 Jetty 版本。 */
  string version_;
  /**
   * 是否启用 WebSocket：缺省 `true`（保留 `engines.ini` 的完整默认集）。
   * 显式 `false` 时 {@link resolveEngineDeps} 会跳过 `<engine type>.websocket` 分节，
   * 不再引入 `tomcat-embed-websocket` / `undertow-websockets` / jetty websocket 等构件。
   * `tomcat-server` 的 WebSocket 随发行包提供，本开关对它无效果。
   */
  bool websocketSupport = true;
  bool jspSupport;
  Listener[] listeners;
  Jar[] jars;
  Context context;

  this(string name, string typ, string version_) {
    this.name = name;
    this.typ = typ;
    this.version_ = version_;
  }

  override string toString() const {
    return name;
  }
}

/**
 * 把 bas 对 Tomcat 引擎的默认要求补进配置模型（幂等，可重复调用）。
 *
 * 补 Server 级 Listener 与 Context 的 `ExtendableWebappLoader` /
 * `DependencyClassLoader`、全关闭的 JarScanner。引擎依赖由
 * {@link resolveEngineDeps} 从 `engines.ini` + `<engine><jar>` 计算，不在这里累加。
 */
void applyEngineDefault(Container container, Engine engine) {
  // 这些默认项（listener / Loader / JarScanner）都是 Tomcat 专有，仅 Tomcat 系需要
  if (!isTomcatType(engine.typ))
    return;

  if (!engine.listeners.length) {
    engine.listeners ~= new Listener("org.apache.catalina.core.JreMemoryLeakPreventionListener");
    engine.listeners ~= new Listener("org.apache.catalina.core.ThreadLocalLeakPreventionListener");
  }

  if (engine.context is null)
    engine.context = new Context();

  auto context = engine.context;
  if (context.loader is null) {
    context.loader = new Loader("org.beangle.bas.engine.tomcat.ExtendableWebappLoader");
    context.loader.properties["loaderClass"] = "org.beangle.bas.engine.tomcat.DependencyClassLoader";
  }
  if (context.jarScanner is null) {
    auto scanner = new JarScanner();
    scanner.properties["scanBootstrapClassPath"] = "false";
    scanner.properties["scanAllDirectories"] = "false";
    scanner.properties["scanAllFiles"] = "false";
    scanner.properties["scanClassPath"] = "false";
    scanner.properties["scanManifest"] = "false";
    context.jarScanner = scanner;
  }
}

/** 编译期内嵌的容器默认依赖集（`resources/engines.ini`）。 */
private enum enginesIniResource = import("engines.ini");

/**
 * 读取 `engines.ini` 中 `section` 的依赖行（原样，未展开占位符）。
 * 空行与 `#` / `;` 注释跳过；分节之外的行不参与。
 */
string[] engineDefaultDeps(string section) {
  string[] deps;
  bool inSection;
  foreach (raw; enginesIniResource.split("\n")) {
    auto line = strip(raw);
    if (!line.length || line.startsWith("#") || line.startsWith(";"))
      continue;
    if (line.startsWith("[")) {
      auto close = line.indexOf(']');
      if (close > 0)
        inSection = strip(line[1 .. close]) == section;
      continue;
    }
    if (inSection)
      deps ~= line;
  }
  return deps;
}

/**
 * `<engine type>` 本身就是 creator 类型：校验为 {@link supportedEngineTypes} 之一后原样返回，
 * 其余抛 `ServerXmlException`。
 */
string containerTypeOf(Engine engine) {
  foreach (t; supportedEngineTypes)
    if (engine.typ == t)
      return t;
  throw new ServerXmlException("engine " ~ engine.name ~ " type \"" ~ engine.typ
      ~ "\" is not supported (expected " ~ supportedEngineTypes.join(", ") ~ ")");
}

/**
 * 引擎引用：`<type>-<version>`，如 `tomcat-server-11.0.26`、`jetty-12.1.14`。
 *
 * 与 `basctl run --engine=` 同形（解析规则见 `bas.embed.EngineRef`），也是 `server.info` 里
 * `engine` 字段的取值：一个字符串同时说出容器形态与版本。
 */
string engineRefText(Engine engine) {
  return engine.typ ~ "-" ~ engine.version_;
}

/** `<engine><jar>` 归一化成 jstart `[engine]` 依赖行（gav 去掉前缀，其余原样）。 */
private string jarDepLine(Jar jar) {
  if (isGav(jar.uri))
    return toArtifact(jar.uri).asGav();
  if (!isRemote(jar.uri))
    return absolutePath(jar.uri);
  return jar.uri;
}

/**
 * 计算引擎依赖：`engines.ini` 的默认集（展开 `{version}` / `{bas}`）与
 * `<engine><jar>` 合并——GA 相同则就地覆盖（保持默认项顺序），否则追加；
 * url / 本地路径直接追加，重复项只保留一次。
 *
 * `engine.websocketSupport` 为 false 时跳过 `<containerType>.websocket` 分节，
 * 从而剔除 `tomcat-embed-websocket` / `undertow-websockets` / jetty websocket 等构件。
 */
string[] resolveEngineDeps(Container container, Engine engine, string containerType) {
  string[] deps;
  int[string] gaPos;

  void mergeDefaults(string[] raws) {
    foreach (raw; raws) {
      auto dep = raw.replace("{version}", engine.version_).replace("{bas}", container.version_);
      auto ga = gaOf(dep);
      if (ga.length && (ga in gaPos))
        deps[gaPos[ga]] = dep;
      else {
        if (ga.length)
          gaPos[ga] = cast(int) deps.length;
        deps ~= dep;
      }
    }
  }

  mergeDefaults(engineDefaultDeps(containerType));
  if (engine.websocketSupport)
    mergeDefaults(engineDefaultDeps(containerType ~ ".websocket"));

  foreach (jar; engine.jars) {
    auto dep = jarDepLine(jar);
    auto ga = gaOf(dep);
    if (ga.length && (ga in gaPos))
      deps[gaPos[ga]] = dep;
    else {
      if (ga.length)
        gaPos[ga] = cast(int) deps.length;
      if (!deps.canFind(dep))
        deps ~= dep;
    }
  }
  return deps;
}

/** A named host mapping（`<hosts><host>`）。 */
class Host {
  string name;
  string ip;
  string agentGroup = "default_group";
  /** setline 对外 listen 端口；与 adminPort 同时为空或同时非空。 */
  Nullable!ushort setlineListenPort;
  /** setline 管理口（adminListen）端口；basctl 只拨 127.0.0.1。 */
  Nullable!ushort setlineAdminPort;

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

  /** 当前 Host 是否声明了完整的 setline 端点。 */
  bool setlineConfigured() const {
    return !setlineListenPort.isNull && !setlineAdminPort.isNull;
  }
}

/** A keyed resource（`<resources><resource>`），属性原样保留。 */
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

/** HTTP 连接器参数。 */
class HttpConnector {
  string protocol = "HTTP/1.1";
  string uriEncoding = "UTF-8";
  bool enableLookups;
  Nullable!int acceptCount;
  Nullable!int maxConnections;
  int connectionTimeout = 60000;
  bool disableUploadTimeout = true;
}

/** A farm groups servers sharing one engine（`<farm>`）。 */
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

/** A single JVM instance under a farm（`<server>`）。 */
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

  /** `farm.server` 形式的限定名。 */
  string qualifiedName() const {
    return farm.name.length ? farm.name ~ "." ~ name : name;
  }

  override string toString() const {
    return qualifiedName();
  }
}

/** A deployed web application（`<webapp>`）。 */
class Webapp {
  string uri;
  string[string] properties;
  bool resolveSupport = true;
  string docBase;
  bool jspSupport;
  Server[] runAt;
  string contextPath;
  string[] urls;
  Nullable!bool unpack;
  Nullable!string libs;
  /** 仅 native engine：可执行文件相对路径；缺省用 artifactId。 */
  Nullable!string exec;

  this(string uri) {
    this.uri = uri;
  }

  /**
   * 路由（setline、反代）使用的 URL 前缀：声明了 `<url>` 就用它们，否则退回部署上下文。
   *
   * 上下文为 `/` 的 webapp 内部 URL 没有公共前缀（如 `/context1`、`/context2`）时，只有显式
   * 声明才能被按路径转发；未声明时它占用 `/`，与其他 webapp 争用同一路径会在生成路由时报冲突。
   */
  string[] routePaths() const {
    if (urls.length)
      return urls.dup;
    return [contextPath.length ? contextPath : "/"];
  }

  /** Tomcat SCI filter：禁用 JSP 时需要屏蔽 JasperInitializer。 */
  Nullable!string getContainerSciFilter(Engine engine) const {
    if (isTomcatType(engine.typ) && !jspSupport)
      return nullable("JasperInitializer");
    return Nullable!string.init;
  }

  /** 规范化 context path。 */
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

/** 正式版仓库配置（server.xml 的 `<repository>`）。 */
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

  /** 与 {@link remotes} 按位置对应的读令牌；空段表示该仓库匿名。 */
  string[] tokens() const {
    if (token.isNull)
      return [];
    return splitTokenList(token.get);
  }

  /** 传给 jstart 的 `[token@]url` 列表；无 token 的仓库保持裸 URL。 */
  string[] repoSpecs() const {
    return mergeRepos(remotes, tokens);
  }
}

/** 开发版（SNAPSHOT）仓库配置（server.xml 的 `<snapshot-repo>`）。 */
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

  /** 与 {@link remotes} 按位置对应的开发版读令牌；空段表示该仓库匿名。 */
  string[] tokens() const {
    if (token.isNull)
      return [];
    return splitTokenList(token.get);
  }

  /** 传给 jstart 的 `[token@]url` 列表；无 token 的仓库保持裸 URL。 */
  string[] repoSpecs() const {
    return mergeRepos(remotes, tokens);
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

/** 拆分逗号分隔的 token 列表；保留空段，保证与 {@link splitRepos} 的结果按位置对齐。 */
private string[] splitTokenList(string tokens) {
  string[] res;
  size_t start = 0;
  foreach (i, ch; tokens) {
    if (ch == ',') {
      res ~= strip(tokens[start .. i]);
      start = i + 1;
    }
  }
  if (start < tokens.length || tokens.length > 0)
    res ~= strip(tokens[start .. $]);
  return res;
}

/** 将按位置对应的仓库与 token 合成 jstart 的 `[token@]url` 列表。 */
private string[] mergeRepos(const(string)[] repos, const(string)[] tokens) {
  string[] specs;
  foreach (i, repo; repos) {
    auto token = i < tokens.length ? strip(tokens[i]) : "";
    specs ~= token.length ? token ~ "@" ~ repo : repo;
  }
  return specs;
}

/** `server.xml` 根对象：engines / hosts / farms / webapps / resources。 */
class Container {
  string version_;
  ushort agentListenPort = 19080;
  /**
   * setline 的路由命名空间。新格式来自根元素 `setline-hostname`；旧格式兼容
   * `<setline hostname="...">`。是否启用由本机 Host 的两个端口决定，不单看该字段。
   */
  Nullable!string setlineHostname;
  /**
   * 旧格式 `<setline port="...">` 的管理口端口。保留用于兼容；新格式把管理口写在
   * `<host setline-admin-port="...">` 上，本字段为空。
   *
   * 这是 setline 的**管理口**（`adminListen`）：basctl 拨 `127.0.0.1:<port>` 推路由、读路由表，
   * 它不是 setline 对外接业务的那个 `listen`（那由 setline 自己那份配置决定）。管理口只认回环来
   * 的写，所以地址没有可配的余地，只有端口。解析见 {@link bas.endpoint.resolveSetlinePort}。
   */
  Nullable!string setlinePort;

  Repository repository;
  SnapshotRepo snapshotRepo;
  Repository nativeRepo;
  Engine[] engines;
  Host[] hosts;
  Farm[] farms;
  Webapp[] webapps;
  Resource[string] resources;

  /** `<setline port>` 的原始写法（没写返回空串），供 {@link bas.endpoint} 解析。 */
  string setlinePortText() const {
    return setlinePort.isNull ? "" : strip(setlinePort.get);
  }

  /** 路由命名空间；没有显式配置时返回 `*`。 */
  string setlineHostnameText() const {
    if (setlineHostname.isNull)
      return defaultSetlineHostname;
    auto value = strip(setlineHostname.get);
    return value.length ? value : defaultSetlineHostname;
  }

  /** 是否至少有一个 Host 声明了完整的 setline 端点。 */
  bool hasHostSetline() const {
    foreach (host; hosts)
      if (host.setlineConfigured())
        return true;
    return false;
  }

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

  /** Whether any host is neither loopback nor localhost. */
  bool hasExternHost() const {
    foreach (h; hosts) {
      if (h.ip != "127.0.0.1" && h.ip != "localhost")
        return true;
    }
    return false;
  }
}

/** 解析 `server.xml` 文本为 `Container`。 */
Container parseServerXml(string xmlText, RemoteConfig remote = RemoteConfig.init) {
  auto dom = parseDOM(xmlText);
  auto basElem = requireRootElement(dom, "bas");

  auto conf = new Container;
  conf.version_ = requireAttr(basElem, "version", "<bas>");
  auto agentPort = optAttr(basElem, "agent-listen-port");
  if (!agentPort.isNull && agentPort.get.strip.length > 0) {
    try
      conf.agentListenPort = parseSetlinePort(agentPort.get);
    catch (Exception)
      throw new ServerXmlException("<bas> has an invalid agent-listen-port");
  }
  auto rootSetlineHostname = optAttr(basElem, "setline-hostname");
  if (!rootSetlineHostname.isNull)
    conf.setlineHostname = nullable(parseSetlineHostnameText(rootSetlineHostname.get));

  // 1. repositories
  conf.repository = new Repository;
  foreach (c; elementChildren(basElem)) {
    if (c.name == "repository")
      conf.repository = parseRepository(c, remote);
    else if (c.name == "snapshot-repo")
      conf.snapshotRepo = parseSnapshotRepo(c, remote);
    else if (c.name == "native-repo")
      conf.nativeRepo = parseNativeRepo(c, remote);
  }
  if (conf.snapshotRepo is null)
    conf.snapshotRepo = new SnapshotRepo;
  if (conf.nativeRepo is null)
    conf.nativeRepo = new Repository;

  // 2. engines
  foreach (section; elementChildren(basElem)) {
    switch (section.name) {
    case "engines":
      foreach (e; elementChildren(section)) {
        if (e.name == "engine")
          conf.engines ~= parseEngine(e);
      }
      break;
    case "hosts":
      foreach (h; elementChildren(section)) {
        if (h.name == "host")
          conf.hosts ~= parseHost(h);
      }
      break;
    case "resources":
      foreach (r; elementChildren(section)) {
        if (r.name == "resource") {
          auto res = parseResource(r);
          conf.resources[res.name] = res;
        }
      }
      break;
    case "farms":
      foreach (f; elementChildren(section)) {
        if (f.name == "farm")
          conf.farms ~= parseFarm(conf, f, remote);
      }
      break;
    case "webapps":
      foreach (w; elementChildren(section)) {
        if (w.name == "webapp")
          conf.webapps ~= parseWebapp(conf, w);
      }
      break;
    case "setline":
      auto hostname = optAttr(section, "hostname");
      auto port = parseSetlinePortAttr(section);
      if (hostname.isNull && port.length == 0)
        throw new ServerXmlException("<setline> must declare hostname, port, or both");
      if (!hostname.isNull) {
        auto parsed = parseSetlineHostnameText(hostname.get);
        if (!conf.setlineHostname.isNull && conf.setlineHostname.get != parsed)
          throw new ServerXmlException("setline-hostname conflicts with <setline hostname>");
        conf.setlineHostname = nullable(parsed);
      }
      conf.setlinePort = port.length ? nullable(port) : Nullable!string.init;
      break;
    default:
      break;
    }
  }

  if (!conf.hosts.length)
    conf.hosts ~= Host.localhost();

  if (!conf.setlinePort.isNull && conf.hasHostSetline())
    throw new ServerXmlException("legacy <setline port> cannot be combined with host setline ports");
  if (conf.hasHostSetline())
    conf.setlineHostname = nullable(conf.setlineHostnameText());
  else if (!conf.setlinePort.isNull)
    conf.setlineHostname = nullable(conf.setlineHostnameText());
  else if (!conf.setlineHostname.isNull)
    throw new ServerXmlException("setline-hostname requires host setline ports or a legacy <setline port>");

  return conf;
}

/** Reads the file path then delegates to `parseServerXml`. */
Container parseServerXmlFile(string path) {
  import std.file : readText;

  return parseServerXml(readText(path), remoteConfForServerXml(path));
}

/** 本机 setline 的实际入口；`enabled=false` 表示本机不参与 setline。 */
struct LocalSetline {
  bool enabled;
  ushort adminPort;
  string hostname;
  string source;
}

/**
 * 按本机地址选择 Host 的 setline 配置。
 *
 * 新格式下端口是机器级事实：一台机器可能匹配多个 Host，但其中最多只能有一个启用了 setline；
 * 没有匹配到启用项就是“本机不启用”，不是配置错误。旧格式没有 Host 端口时继续读取根级
 * `<setline port>`，避免旧配置在升级 basctl 后立即失效。
 */
LocalSetline localSetlineConfig(const Container container, const(string)[] localIps) {
  if (container.hasHostSetline()) {
    size_t matchedCount;
    string selectedName;
    ushort selectedPort;
    foreach (host; container.hosts) {
      if (host.setlineConfigured() && localIps.canFind(host.ip)) {
        matchedCount++;
        selectedName = host.name;
        selectedPort = host.setlineAdminPort.get;
      }
    }
    if (matchedCount > 1)
      throw new ServerXmlException("multiple local hosts enable setline");
    if (matchedCount == 0)
      return LocalSetline(false, 0, container.setlineHostnameText(), "local host does not enable setline");
    return LocalSetline(true, selectedPort, container.setlineHostnameText(), "host " ~ selectedName);
  }
  if (!container.setlinePort.isNull)
    return LocalSetline(true, parseSetlinePort(container.setlinePortText()),
        container.setlineHostnameText(), "legacy <setline port>");
  return LocalSetline(false, 0, container.setlineHostnameText(), "setline is not configured");
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

/**
 * setline 路由命名空间：缺省 {@link defaultSetlineHostname}，`*` 表示匹配任意 Host；其余只接受
 * 域名允许的字符（小写字母、数字、`-`、`.`）。写坏了直接报错，不悄悄替换成别的名字。
 */
private string parseSetlineHostnameText(string value) {
  auto text = toLower(strip(value));
  if (text.empty)
    return defaultSetlineHostname;
  if (text == "*")
    return text;
  foreach (ch; text) {
    if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '-')
      continue;
    throw new ServerXmlException("Invalid setline hostname \"" ~ value
        ~ "\": use a hostname (letters, digits, '.' and '-'), \"*\" for any Host,"
        ~ " or drop the attribute");
  }
  return text;
}

/**
 * 旧格式 `<setline port>`：兼容早期配置文件；新格式把端口写在 Host 上。
 * 没写 port 时返回空串，最终由“必须存在 Host 端口”这一约束校验。
 */
private string parseSetlinePortAttr(XmlElem elem) {
  auto value = optAttr(elem, "port");
  if (value.isNull || strip(value.get).empty)
    return "";
  auto attr = value.get;
  auto text = strip(attr);
  try
    parseSetlinePort(text);
  catch (Exception)
    throw new ServerXmlException("Invalid <setline port=\"" ~ attr
        ~ "\">: use the adminListen port (1-65535)");
  return text;
}

/** Wraps an optional attribute into a `Nullable` holding only non-blank text. */
Nullable!string nonBlankAttr(XmlElem elem, string name) {
  auto v = optAttr(elem, name);
  if (v.isNull || strip(v.get).empty)
    return Nullable!string.init;
  return nullable(strip(v.get));
}

/** 解析正式版 `<repository>`：本地目录、远端地址与可选令牌。 */
Repository parseNativeRepo(XmlElem elem, RemoteConfig remoteConf) {
  auto local = nonBlankAttr(elem, "local");
  auto url = expandBasRemoteUrl(nonBlankAttr(elem, "remote"), remoteConf.url);
  auto token = resolveToken(optAttr(elem, "token"), remoteConf.token);
  return new Repository(local, url, token);
}

Repository parseRepository(XmlElem elem, RemoteConfig remoteConf) {
  auto local = nonBlankAttr(elem, "local");
  auto remote = nonBlankAttr(elem, "remote");
  auto token = resolveToken(optAttr(elem, "token"), remoteConf.token);
  return new Repository(local, remote, token);
}

/** 解析开发版 `<snapshot-repo>`：`remote` 展开 `${bas_remote_url}`。 */
SnapshotRepo parseSnapshotRepo(XmlElem elem, RemoteConfig remoteConf) {
  auto local = nonBlankAttr(elem, "local");
  auto url = expandBasRemoteUrl(nonBlankAttr(elem, "remote"), remoteConf.url);
  auto token = resolveToken(optAttr(elem, "token"), remoteConf.token);
  return new SnapshotRepo(local, url, token);
}

/** 解析仓库的 `token` 属性，支持 `${bas_remote_token}` 占位。 */
Nullable!string resolveToken(Nullable!string token, string remoteToken) {
  if (token.isNull || strip(token.get).empty)
    return Nullable!string.init;
  auto result = token.get;
  enum marker = "${bas_remote_token}";
  if (result.canFind(marker)) {
    if (remoteToken.empty)
      return Nullable!string.init;
    result = result.replace(marker, remoteToken);
  }
  if (strip(result).empty)
    return Nullable!string.init;
  return nullable(result);
}

/** 展开 `${bas_remote_url}` 为控制台根地址；未配置时返回空。 */
Nullable!string expandBasRemoteUrl(Nullable!string remote, string remoteUrl) {
  if (remote.isNull)
    return Nullable!string.init;
  enum marker = "${bas_remote_url}";
  auto value = remote.get;
  if (!value.canFind(marker))
    return nullable(value);
  if (remoteUrl.empty)
    return Nullable!string.init;
  return nullable(value.replace(marker, remoteBaseUrl(remoteUrl)));
}

/** 解析 `<engine>` 及其 `<listener>` / `<context>` / `<jar>` 子节点。 */
Engine parseEngine(XmlElem elem) {
  auto e = new Engine(requireAttr(elem, "name", "<engine>"),
      requireAttr(elem, "type", "<engine>"),
      requireAttr(elem, "version", "<engine>"));
  auto jsp = optAttr(elem, "jsp-support");
  e.jspSupport = !jsp.isNull && jsp.get == "true";
  // 缺省 true：不写该属性即保留 engines.ini 的完整默认集（含 websocket）
  auto websocket = optAttr(elem, "websocket-support");
  if (!websocket.isNull)
    e.websocketSupport = websocket.get == "true";

  foreach (c; elementChildren(elem)) {
    switch (c.name) {
    case "listener":
      auto l = new Listener(requireAttr(c, "class-name", "<listener>"));
      l.properties = attrsExcept(c, ["class-name"]);
      e.listeners ~= l;
      break;
    case "context":
      auto ctx = new Context;
      foreach (x; elementChildren(c)) {
        if (x.name == "loader") {
          auto ld = new Loader(requireAttr(x, "class-name", "<loader>"));
          ld.properties = attrsExcept(x, ["class-name"]);
          ctx.loader = ld;
        } else if (x.name == "jar-scanner") {
          auto js = new JarScanner;
          js.properties = attrsExcept(x, []);
          ctx.jarScanner = js;
        }
      }
      e.context = ctx;
      break;
    case "jar":
      e.jars ~= new Jar(requireAttr(c, "uri", "<jar>"));
      break;
    default:
      break;
    }
  }
  return e;
}

/** 解析 `<host>`（名称 + 绑定 IP）。 */
Host parseHost(XmlElem elem) {
  auto host = new Host(requireAttr(elem, "name", "<host>"), requireAttr(elem, "ip", "<host>"));
  auto group = optAttr(elem, "agent-group");
  if (!group.isNull && group.get.strip.length > 0)
    host.agentGroup = group.get.strip;
  auto listen = nonBlankAttr(elem, "setline-listen-port");
  auto admin = nonBlankAttr(elem, "setline-admin-port");
  if (listen.isNull != admin.isNull)
    throw new ServerXmlException("host " ~ host.name
        ~ " must set both setline-listen-port and setline-admin-port");
  if (!listen.isNull) {
    try {
      host.setlineListenPort = nullable(parseSetlinePort(listen.get));
      host.setlineAdminPort = nullable(parseSetlinePort(admin.get));
    } catch (Exception) {
      throw new ServerXmlException("host " ~ host.name
          ~ " has an invalid setline port (expected 1-65535)");
    }
  }
  return host;
}

/** 解析 `<resource>`：`name` 单独取出，其余属性原样透传给 Tomcat。 */
Resource parseResource(XmlElem elem) {
  auto r = new Resource(requireAttr(elem, "name", "<resource>"));
  r.properties = attrsExcept(elem, ["name"]);
  return r;
}

/** 解析 `<farm>`：绑定引擎、`server-options`，并递归解析各 `<server>`。 */
Farm parseFarm(Container conf, XmlElem elem, RemoteConfig remote) {
  auto name = requireAttr(elem, "name", "<farm>");
  enforce!ServerXmlException(!name.canFind('.'), "farm name " ~ name ~ " cannot contains dot");
  auto engName = requireAttr(elem, "engine", "<farm>");
  auto eng = conf.engine(engName);
  enforce!ServerXmlException(eng !is null, "Cannot find engine for " ~ engName);

  auto farm = new Farm(name, eng);
  auto mhs = nonBlankAttr(elem, "max-heap-size");
  farm.maxHeapSize = mhs.isNull ? "300M" : mhs.get;

  auto serverOptions = findFirstChildText(elem, "server-options");
  if (serverOptions.length)
    farm.serverOptions = nullable(expandServerOptions(serverOptions, remote.url));

  foreach (c; elementChildren(elem)) {
    if (c.name == "http")
      readHttpConnector(c, farm.http);
    else if (c.name == "server")
      farm.servers ~= parseServer(conf, farm, c);
  }

  foreach (s; farm.servers) {
    if (s.maxHeapSize.empty)
      s.maxHeapSize = farm.maxHeapSize;
  }
  return farm;
}

/** 展开 `server-options` 中的 `${bas_remote_url}`；未配置时原样返回。 */
string expandServerOptions(string opts, string remoteUrl) {
  enum marker = "${bas_remote_url}";
  auto trimmed = trimLines(opts);
  if (!trimmed.canFind(marker))
    return trimmed;
  if (remoteUrl.empty)
    return trimmed;
  return trimmed.replace(marker, remoteBaseUrl(remoteUrl));
}

/** 解析 `<server>`：http 端口、host 归属与堆大小（缺省继承 farm）。 */
Server parseServer(Container conf, Farm farm, XmlElem elem) {
  auto s = new Server(farm, requireAttr(elem, "name", "<server>"));
  s.http = parseIntAttr(elem, "http", 0);

  auto hostName = nonBlankAttr(elem, "host");
  s.host = hostName.isNull ? Host.localhost() : conf.getHost(hostName.get);

  auto mhs = nonBlankAttr(elem, "max-heap-size");
  s.maxHeapSize = mhs.isNull ? farm.maxHeapSize : mhs.get;
  return s;
}

/** 读取 `<http>` 上的连接器参数，只覆盖显式给出的项。 */
void readHttpConnector(XmlElem elem, HttpConnector http) {
  auto el = optAttr(elem, "enable-lookups");
  if (!el.isNull)
    http.enableLookups = el.get == "true";

  auto ac = optPositiveIntAttr(elem, "accept-count");
  if (!ac.isNull)
    http.acceptCount = ac;

  auto mc = optPositiveIntAttr(elem, "max-connections");
  if (!mc.isNull)
    http.maxConnections = mc;

  auto dut = optAttr(elem, "disable-upload-timeout");
  if (!dut.isNull)
    http.disableUploadTimeout = dut.get == "true";

  auto ct = optPositiveIntAttr(elem, "connection-timeout");
  if (!ct.isNull)
    http.connectionTimeout = ct.get;
}

Webapp parseWebapp(Container conf, XmlElem elem) {
  auto w = new Webapp(requireAttr(elem, "uri", "<webapp>"));

  static immutable reserved = ["name", "uri", "reloadable", "path", "run-at", "doc-base", "libs",
    "jsp-support", "resolve-support"];
  w.properties = attrsExcept(elem, reserved);

  auto jsp = optAttr(elem, "jsp-support");
  w.jspSupport = !jsp.isNull && jsp.get == "true";

  auto resolve = optAttr(elem, "resolve-support");
  w.resolveSupport = resolve.isNull || strip(resolve.get) != "false";

  auto libs = nonBlankAttr(elem, "libs");
  if (!libs.isNull)
    w.libs = libs;

  foreach (c; elementChildren(elem)) {
    if (c.name == "url") {
      auto path = normalizeUrlPath(requireAttr(c, "path", "<url>"));
      enforce!ServerXmlException(path.startsWith("/"),
          "<url path> must start with /: '" ~ path ~ "' in webapp " ~ w.uri);
      if (!w.urls.canFind(path))
        w.urls ~= path;
    }
  }

  w.updatePath(nonBlankAttr(elem, "path").isNull ? "" : nonBlankAttr(elem, "path").get);

  auto runAt = optAttr(elem, "run-at");
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

  auto exec = nonBlankAttr(elem, "exec");
  if (!exec.isNull)
    w.exec = nullable(strip(exec.get));

  auto unpack = optAttr(elem, "unpack");
  if (!unpack.isNull && !strip(unpack.get).empty)
    w.unpack = nullable(strip(unpack.get) == "true");

  return w;
}

/** 规范化一条对外 URL 前缀：去掉尾部 `/`，`/` 本身保留。 */
private string normalizeUrlPath(string path) {
  auto p = strip(path);
  if (p.length > 1 && p.endsWith("/"))
    p = p[0 .. $ - 1];
  return p;
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
