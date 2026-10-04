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
 * 配置生成：直接渲染 Tomcat 的 `server.xml`、`web.xml`，以及实例的 `setenv.sh`
 * 和 firewalld zone 片段。
 */
module bas.render;

import bas.config;
import bas.mimetypes;

import std.algorithm : canFind, sort, startsWith;
import std.array : Appender, appender, join;
import std.conv : to;
import std.string : replace;

/** 随二进制内嵌的资源：Tomcat 的 `catalina.properties`。 */
enum catalinaProperties = import("tomcat/conf/catalina.properties");

/** 随二进制内嵌的资源：`sas/mime.types`。 */
enum mimeTypesResource = import("sas/mime.types");

/** Renders the Tomcat `conf/server.xml` for one server. */
string renderServerXml(Container container, Farm farm, Server server) {
  auto sb = appender!string;
  sb.put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  sb.put("<Server port=\"-1\" shutdown=\"SHUTDOWN\">\n");
  sb.put("  <Listener className=\"org.beangle.sas.engine.tomcat.WebappFailFastListener\"/>\n");
  foreach (listener; farm.engine.listeners)
    sb.put("  <Listener className=\"" ~ esc(listener.className) ~ "\"" ~ renderProps(listener.properties) ~ "/>\n");

  auto resourceNames = container.farmResourceNames(farm);
  resourceNames.sort();
  if (resourceNames.length) {
    sb.put("  <GlobalNamingResources>\n");
    foreach (name; resourceNames) {
      auto resource = name in container.resources;
      if (resource is null)
        continue;
      sb.put("    <Resource name=\"" ~ esc(resource.name) ~ "\"" ~ renderProps(resource.properties) ~ "/>\n");
    }
    sb.put("  </GlobalNamingResources>\n");
  }

  sb.put("  <Service name=\"Catalina\">\n");
  if (server.http > 0 && farm.http !is null) {
    auto http = farm.http;
    sb.put("    <Connector port=\"" ~ server.http.to!string ~ "\" protocol=\"HTTP/1.1\"\n");
    sb.put("      URIEncoding=\"" ~ esc(http.uriEncoding) ~ "\" enableLookups=\""
        ~ boolText(http.enableLookups) ~ "\"");
    if (!http.acceptCount.isNull)
      sb.put(" acceptCount=\"" ~ http.acceptCount.get.to!string ~ "\"");
    sb.put("\n      connectionTimeout=\"" ~ http.connectionTimeout.to!string ~ "\"\n");
    sb.put("      disableUploadTimeout=\"" ~ boolText(http.disableUploadTimeout) ~ "\"");
    if (farm.engine.version_.startsWith("11"))
      sb.put(" useVirtualThreads=\"true\"");
    sb.put("/>\n");
  }

  sb.put("    <Engine name=\"Catalina\" defaultHost=\"localhost\">\n");
  sb.put("      <Host name=\"localhost\" appBase=\"webapps\" unpackWARs=\"true\" startStopThreads=\"0\""
      ~ " autoDeploy=\"false\" errorReportValveClass=\"org.beangle.sas.engine.tomcat.SwallowErrorValve\">\n");

  foreach (webapp; container.getWebapps(server)) {
    sb.put("        <Context path=\"" ~ esc(webapp.contextPath) ~ "\"");
    auto sciFilter = webapp.getContainerSciFilter(farm.engine);
    if (!sciFilter.isNull)
      sb.put(" containerSciFilter=\"" ~ esc(sciFilter.get) ~ "\"");
    if (!webapp.unpack.isNull && !webapp.unpack.get)
      sb.put(" unpackWAR=\"false\"");
    sb.put(" docBase=\"" ~ esc(webapp.docBase) ~ "\"" ~ renderProps(webapp.properties) ~ ">\n");

    foreach (resource; webapp.resources)
      sb.put("          <ResourceLink name=\"" ~ esc(resource.name) ~ "\" global=\"" ~ esc(resource.name)
          ~ "\" type=\"" ~ esc(resource.type()) ~ "\" />\n");

    auto ctx = farm.engine.context;
    if (ctx !is null) {
      if (ctx.jarScanner !is null)
        sb.put("          <JarScanner" ~ renderProps(ctx.jarScanner.properties) ~ "/>\n");
      if (ctx.loader !is null) {
        sb.put("          <Loader className=\"" ~ esc(ctx.loader.className) ~ "\"");
        if (!webapp.libs.isNull)
          sb.put(" libs=\"" ~ esc(webapp.libs.get) ~ "\"");
        sb.put(renderProps(ctx.loader.properties) ~ "/>\n");
      }
    }
    if (webapp.realms.length)
      sb.put("          " ~ webapp.realms ~ "\n");
    sb.put("        </Context>\n");
  }

  sb.put("      </Host>\n");
  sb.put("    </Engine>\n");
  sb.put("  </Service>\n");
  sb.put("</Server>\n");
  return sb.data;
}

/** 渲染 `bin/setenv.sh`。 */
string renderSetenvSh(Farm farm, Server server) {
  string options = farm.serverOptions.isNull ? "" : farm.serverOptions.get;
  if (farm.engine.typ != engineAny)
    return "SERVER_OPTS=\"-server -Djava.awt.headless=true -Xmx" ~ server.maxHeapSize
      ~ " -Djava.security.egd=file:/dev/./urandom " ~ options ~ "\"\n";
  if (!farm.serverOptions.isNull)
    return "SERVER_OPTS=\"" ~ options ~ "\"\n";
  return "";
}

/**
 * 渲染 Tomcat `conf/web.xml`。
 *
 * Servlet 命名空间按引擎大版本切换；MIME 映射来自内嵌的 `sas/mime.types`。
 */
string renderWebXml(Engine engine) {
  auto sb = appender!string;
  sb.put("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n\n");
  auto engineVersion = engine.version_;
  if (engineVersion.startsWith("11")) {
    sb.put("<web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee\n");
    sb.put("                      https://jakarta.ee/xml/ns/jakartaee/web-app_6_1.xsd\"\n");
    sb.put("  version=\"6.1\">\n\n");
    putCharacterEncoding(sb);
  } else if (engineVersion.startsWith("10.1")) {
    sb.put("<web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee\n");
    sb.put("                      https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd\"\n");
    sb.put("  version=\"6.0\">\n\n");
    putCharacterEncoding(sb);
  } else if (engineVersion.startsWith("10")) {
    sb.put("<web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee\n");
    sb.put("                      https://jakarta.ee/xml/ns/jakartaee/web-app_5_0.xsd\"\n");
    sb.put("  version=\"5.0\">\n\n");
    putCharacterEncoding(sb);
  } else {
    sb.put("<web-app xmlns=\"http://xmlns.jcp.org/xml/ns/javaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"http://xmlns.jcp.org/xml/ns/javaee\n");
    sb.put("                      http://xmlns.jcp.org/xml/ns/javaee/web-app_4_0.xsd\"\n");
    sb.put("  version=\"4.0\">\n");
  }

  sb.put("    <servlet>\n");
  sb.put("        <servlet-name>default</servlet-name>\n");
  sb.put("        <servlet-class>org.apache.catalina.servlets.DefaultServlet</servlet-class>\n");
  sb.put("        <init-param>\n");
  sb.put("            <param-name>debug</param-name>\n");
  sb.put("            <param-value>0</param-value>\n");
  sb.put("        </init-param>\n");
  sb.put("        <init-param>\n");
  sb.put("            <param-name>listings</param-name>\n");
  sb.put("            <param-value>false</param-value>\n");
  sb.put("        </init-param>\n");
  sb.put("        <load-on-startup>1</load-on-startup>\n");
  sb.put("    </servlet>\n\n");

  if (engine.jspSupport) {
    sb.put("    <servlet>\n");
    sb.put("        <servlet-name>jsp</servlet-name>\n");
    sb.put("        <servlet-class>org.apache.jasper.servlet.JspServlet</servlet-class>\n");
    sb.put("        <init-param>\n");
    sb.put("            <param-name>fork</param-name>\n");
    sb.put("            <param-value>false</param-value>\n");
    sb.put("        </init-param>\n");
    sb.put("        <init-param>\n");
    sb.put("            <param-name>xpoweredBy</param-name>\n");
    sb.put("            <param-value>false</param-value>\n");
    sb.put("        </init-param>\n");
    sb.put("        <load-on-startup>3</load-on-startup>\n");
    sb.put("    </servlet>\n\n");
  }

  sb.put("    <servlet-mapping>\n");
  sb.put("        <servlet-name>default</servlet-name>\n");
  sb.put("        <url-pattern>/</url-pattern>\n");
  sb.put("    </servlet-mapping>\n\n");

  if (engine.jspSupport) {
    sb.put("    <servlet-mapping>\n");
    sb.put("        <servlet-name>jsp</servlet-name>\n");
    sb.put("        <url-pattern>*.jsp</url-pattern>\n");
    sb.put("        <url-pattern>*.jspx</url-pattern>\n");
    sb.put("    </servlet-mapping>\n\n");
  }

  sb.put("    <session-config>\n");
  sb.put("        <session-timeout>30</session-timeout>\n");
  sb.put("    </session-config>\n\n");

  foreach (entry; parseMimeTypes(mimeTypesResource)) {
    sb.put("    <mime-mapping>\n");
    sb.put("        <extension>" ~ esc(entry.key) ~ "</extension>\n");
    sb.put("        <mime-type>" ~ esc(entry.mimeType) ~ "</mime-type>\n");
    sb.put("    </mime-mapping>\n");
  }
  sb.put("\n    <welcome-file-list>\n");
  sb.put("        <welcome-file>index.html</welcome-file>\n");
  sb.put("        <welcome-file>index.htm</welcome-file>\n");
  if (engine.jspSupport)
    sb.put("        <welcome-file>index.jsp</welcome-file>\n");
  sb.put("    </welcome-file-list>\n\n");
  sb.put("</web-app>\n");
  return sb.data;
}

/** 写入请求/响应字符编码声明（Servlet 4.0+/Jakarta 命名空间）。 */
private void putCharacterEncoding(ref Appender!string sb) {
  sb.put("  <request-character-encoding>UTF-8</request-character-encoding>\n");
  sb.put("  <response-character-encoding>UTF-8</response-character-encoding>\n");
}

/** 渲染 firewalld zone 片段。 */
string renderFirewallConf(const(int)[] ports) {
  auto sb = appender!string;
  sb.put("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
  sb.put("<zone>\n");
  sb.put("  <short>Public</short>\n");
  foreach (port; ports)
    sb.put("  <port protocol=\"tcp\" port=\"" ~ port.to!string ~ "\"/>\n");
  sb.put("</zone>\n");
  return sb.data;
}

/** 把属性表渲染为 ` key="value"` 片段；键排序以保证同一配置输出稳定。 */
private string renderProps(string[string] map) {
  if (!map.length)
    return "";
  auto keys = map.keys;
  keys.sort();
  string[] parts;
  foreach (key; keys)
    parts ~= key ~ "=\"" ~ esc(map[key]) ~ "\"";
  return " " ~ parts.join(" ");
}

/** D 的 `bool` 转 Tomcat 期望的 `true` / `false`。 */
private string boolText(bool value) {
  return value ? "true" : "false";
}

/** 转义 XML 属性值中的 `&`、`"`、`<`。 */
private string esc(string value) {
  return value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;");
}
