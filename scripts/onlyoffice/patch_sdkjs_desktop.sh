#!/usr/bin/env bash
# sdkjs 补丁应用：third_party/sdkjs 官方 release/v9.4.0 + 本工程 desktop 构建适配。
#
# 背景：third_party/sdkjs 是官方 submodule（github.com/ONLYOFFICE/sdkjs,
# release/v9.4.0）。本工程对它的修改保存在
# scripts/onlyoffice/patches/sdkjs-desktop/*.patch（官方树保持干净）；跑官方
# sdkjs 构建（third_party/sdkjs/build/build.py --desktop，即 grunt-build.sh 的
# 2/6 步）前必须先应用——configs/*.json 决定 desktop 构建清单，缺补丁则产物缺段
# （打开链空白/崩溃）。
#
# 用法: bash scripts/onlyoffice/patch_sdkjs_desktop.sh
# 幂等：已应用的补丁自动跳过；补丁无法应用（源码被修改/版本漂移）则报错退出。
#
# 补丁清单：
#   01_desktop-build-adaptation.patch  configs/{word,cell,slide}.json 清单裁剪（desktop
#     段仅 license.js；Local/common.js 为打开崩溃源）+ common/apiBase.js：getEmpty
#     补 word/document/editor.js 段（仅打开链所需）+ 空文档 bSerFormat 显式 true
#     （9.4.0 DOCY;v2 字符串签名嗅探恒 false）。
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDKJS="$ROOT/third_party/sdkjs"
PATCHES="$ROOT/scripts/onlyoffice/patches/sdkjs-desktop"

if [ ! -d "$SDKJS/.git" ]; then
  echo "!! $SDKJS 不是 git 仓库 —— submodule 未初始化：先执行 git submodule update --init third_party/sdkjs" >&2
  exit 1
fi

cd "$SDKJS"
for p in "$PATCHES"/*.patch; do
  n="$(basename "$p")"
  if git apply --reverse --check "$p" 2>/dev/null; then
    echo "== $n 已应用，跳过"
    continue
  fi
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"
    echo "== $n applied"
  else
    echo "!! $n 无法应用（third_party/sdkjs 源码已被修改？先 git -C third_party/sdkjs status 检查）" >&2
    exit 1
  fi
done
echo "patch_sdkjs_desktop: done"
