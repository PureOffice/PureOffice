#!/bin/bash
# ONLYOFFICE core 第三方源码拉取（官方各 3dParty/fetch.py 等价实现：
#   md/md4c、html/{gumbo-parser,katana-parser}、apple/{glm,mdds,librevenge,libodfgen,libetonyek}
# 拉取后补丁见 fetch_3dparty_patch.py
set -e
CORE="$(cd "$(dirname "$0")/../.." && pwd)/third_party/core"

get() { # $1=github repo, $2=commit, $3=core 相对目录
  local dir="$CORE/$3"
  if [ ! -d "$dir" ]; then
    git clone --quiet --filter=blob:none "https://github.com/$1" "$dir"
  fi
  git -C "$dir" checkout --quiet "$2"
  echo "ok: $3"
}

get mity/md4c                    481fbfbdf72daab2912380d62bb5f2187d438408 Common/3dParty/md/md4c
get google/gumbo-parser          aa91b27b02c0c80c482e24348a457ed7c3c088e0 Common/3dParty/html/gumbo-parser
get jasenhuang/katana-parser     be6df458d4540eee375c513958dcb862a391cdd1 Common/3dParty/html/katana-parser
get g-truc/glm                   33b4a621a697a305bc3a7610d290677b96beb181 Common/3dParty/apple/glm
get kohei-us/mdds                0783158939c6ce4b0b1b89e345ab983ccb0f0ad0 Common/3dParty/apple/mdds
get Distrotech/librevenge        becd044b519ab83893ad6398e3cbb499a7f0aaf4 Common/3dParty/apple/librevenge
get Distrotech/libodfgen         8ef8c171ebe3c5daebdce80ee422cf7bb96aa3bc Common/3dParty/apple/libodfgen
get LibreOffice/libetonyek       cb396b4a9453a457469b62a740d8fb933c9442c3 Common/3dParty/apple/libetonyek

echo DONE
