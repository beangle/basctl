/** basctl / basagent 共用的命令行路径解析。 */
module bas.cli;

import std.file : getcwd;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.string : endsWith, startsWith, strip;

/** `BAS_HOME` 有值时取其指向目录，否则取当前工作目录。 */
string resolveBasHome() @trusted {
  auto fromEnv = strip(environment.get("BAS_HOME", ""));
  if (fromEnv.length)
    return absolutePath(fromEnv);
  return absolutePath(getcwd());
}

/**
 * 取命令行里的配置文件：第一个位置参数以 `.xml` 结尾即视为 `server.xml`，否则用
 * `$BAS_HOME/conf/server.xml`。命中的参数会从 `rest` 摘掉。
 */
string takeConfigFile(ref string[] rest) {
  if (rest.length && !rest[0].startsWith("-") && rest[0].endsWith(".xml")) {
    auto value = rest[0];
    rest = rest[1 .. $];
    return value;
  }
  return buildPath(resolveBasHome(), "conf", "server.xml");
}
