#!/bin/bash
# bas 控制脚本的共享环境：控制命令位置与仓库地址。
#
# 控制面 basctl 与运行器 jstart 都取 PATH 上的同名命令，可分别用 beangle_basctl /
# beangle_jstart 覆盖（例如指向未安装到 PATH 的本地构建产物）。
# 引擎与容器版本取自 conf/server.xml（<bas version> / <engine version>），
# 不在本文件里维护。

if [ "$(id -u)" = 0 ]; then
  echo -e "\033[31m Please run this command in a non root environment. \033[0m"
  exit 1
fi

if [ -z "$M2_REMOTE_REPO" ]; then
  export M2_REMOTE_REPO="https://maven.aliyun.com/nexus/content/groups/public"
fi
if [ -z "$M2_REPO" ]; then
  export M2_REPO="$HOME/.m2/repository"
fi

export basctl_cmd="${beangle_basctl:-basctl}"
