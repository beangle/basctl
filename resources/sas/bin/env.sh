#!/bin/bash
# sas 控制脚本的共享环境：控制命令位置与仓库地址。
#
# 控制面 basctl 与运行器 jstart 都取 PATH 上的同名命令，可分别用 sas_basctl /
# sas_jstart 覆盖（例如指向未安装到 PATH 的本地构建产物）。
# 嵌入式运行（basctl run）的构件版本由 basctl 内置，可用 sas_*_version 覆盖；
# 多实例模式的引擎版本取自 conf/server.xml，二者都不在本文件里维护。

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

export basctl_cmd="${sas_basctl:-basctl}"
