#!/usr/bin/env bash
# core(OHOS) 补丁应用：third_party/core 官方 release/v9.4.0 + 本工程所需 OHOS 修复。
#
# 背景：third_party/core 是官方 submodule（github.com/ONLYOFFICE/core, release/v9.4.0）。
# 所有本地修复保存在 scripts/onlyoffice/patches/core-ohos/*.patch（官方树保持干净）；
# 编译 core（gen_cmake.py + cmake + cmake --build build/core3d）前必须先运行本脚本。
#
# 用法: bash scripts/onlyoffice/patch_core_ohos.sh
# 幂等：已应用的补丁自动跳过；补丁无法应用（源码被修改/版本漂移）则报错退出。
#
# 补丁清单（POC-2/迭代2 沉淀）：
#   01_harfbuzz-make-ensure-patch-preserved.patch   harfbuzz make.py 补丁保留（apply_patch 前重新应用）
#   02_openssl-md2-compat.patch                     doctrenderer/hash.cpp: openssl 3.0 OPENSSL_NO_MD2 时 MD2 软件回落
#   03_configure-exec-bit.patch                     freetype builds/unix/configure 可执行位（100644->100755）
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/third_party/core"
PATCHES="$ROOT/scripts/onlyoffice/patches/core-ohos"

if [ ! -d "$CORE/.git" ]; then
  echo "!! $CORE 不是 git 仓库 —— submodule 未初始化：先执行 git submodule update --init third_party/core" >&2
  exit 1
fi

cd "$CORE"
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
    echo "!! $n 无法应用（third_party/core 源码已被修改？先 git -C third_party/core status 检查）" >&2
    exit 1
  fi
done
echo "patch_core_ohos: done"
