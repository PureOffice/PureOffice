#!/usr/bin/env bash
# web-apps 补丁应用：third_party/web-apps 官方 release/v9.4.0 + 本工程桌面适配。
#
# 背景：third_party/web-apps 是官方 submodule。本工程对它的修改保存在
# scripts/onlyoffice/patches/webapps-desktop/*.patch（官方树保持干净的预期态，
# 与 core/sdkjs 补丁同一工作流）。
#
# 补丁打在**源树**（apps/…）：grunt-build.sh 步骤 1/6 的 grunt deploy 以源树为
# 输入拷贝出 deploy/web-apps/，源补则产物永远一致。
# deploy/web-apps/ 产物同步做一次相同替换：日常部署链（deploy_ohos.sh）不重跑
# grunt，产物是上次 grunt 的遗留副本——脚本直接把已就位的产物也补上，避免
# 「补丁已入库但日常链产物仍是旧文件」的缝隙。
#
# 用法: bash scripts/onlyoffice/patch_webapps_desktop.sh
# 幂等：已应用自动跳过；无法应用（源码被改动/上游版本漂移）报错退出。
#
# 补丁清单：
#   01_colorpaletteext-declare-baseview.patch  ColorPaletteExt.js define([]) 显式
#     声明 BaseView 依赖（零依赖声明+全局命名空间写法在多文件加载下偶发顺序颠倒
#     → Uncaught 异常 → app 启动链死 → 打开偶发卡骨架屏；根因与证据见
#     记忆 onlyoffice-open-skeleton-hang / patches 文件头注释）。
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WEBAPPS="$ROOT/third_party/web-apps"
PATCHES="$ROOT/scripts/onlyoffice/patches/webapps-desktop"
NEW='define(['"'"'common/main/lib/component/BaseView'"'"'], function () { '"'"'use strict'"'"';'
OLD='define([], function () { '"'"'use strict'"'"';'

if [ ! -d "$WEBAPPS/.git" ]; then
  echo "!! $WEBAPPS 不是 git 仓库 —— submodule 未初始化：先执行 git submodule update --init third_party/web-apps" >&2
  exit 1
fi

# —— 源树：git apply 双向 check（与 patch_sdkjs_desktop.sh 同一判据）——
cd "$WEBAPPS"
for p in "$PATCHES"/*.patch; do
  n="$(basename "$p")"
  if out=$(git apply --check "$p" 2>&1) && [ -z "$out" ]; then
    git apply "$p"
    echo "== $n applied (source)"
  elif out=$(git apply --reverse --check "$p" 2>&1) && [ -z "$out" ]; then
    echo "== $n 已应用，跳过 (source)"
  else
    echo "!! $n 无法应用也无法回退 —— 源树被改动或上游版本漂移，请人工核对" >&2
    echo "$out" >&2
    exit 1
  fi
done

# —— deploy 产物：字符串替换幂等（deploy 被 grunt 重置后，下一次调用即重新补上）——
DEPLOY="$WEBAPPS/deploy/web-apps/apps/common/main/lib/component/ColorPaletteExt.js"
if [ -f "$DEPLOY" ]; then
  if grep -qF "$NEW" "$DEPLOY"; then
    echo "== deploy 产物已应用，跳过"
  elif grep -qF "$OLD" "$DEPLOY"; then
    python3 - "$DEPLOY" "$OLD" "$NEW" <<'PYEOF'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
assert s.count(old) == 1, 'expect exactly 1 occurrence in ' + p
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print('== deploy 产物 patched:', p)
PYEOF
  else
    echo "!! deploy 产物既非原样也非已补 —— 上游版本漂移，请人工核对：$DEPLOY" >&2
    exit 1
  fi
else
  echo "== deploy 产物不存在（未跑过 grunt），跳过（grunt-build 步骤 1/6 产物由已补源树生成）"
fi
