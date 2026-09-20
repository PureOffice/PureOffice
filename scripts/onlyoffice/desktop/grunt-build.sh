#!/usr/bin/env bash
# ============================================================================
# 上游官方仓库重建 + 本机装配 —— rawfile 运行时资源一键链（唯一入口）
#
# 用法：
#   bash scripts/onlyoffice/desktop/grunt-build.sh   # 全链（官方 grunt 产物重建→装配）
#   bash scripts/onlyoffice/desktop/grunt-build.sh --no-upstream
#                                                   # 跳过官方构建（grunt 产物已就位，
#                                                   # 仅 make_ascshim + build_editors_ohos.py）
#
# 步骤与产物：
#   1. web-apps 官方 grunt（build/ 内，default=deploy 各 app）
#      → third_party/web-apps/deploy/web-apps/
#   2. sdkjs 官方 build（--desktop 含 Local/*.js 桌面链）
#      → third_party/sdkjs/deploy/sdkjs/
#   3. loginpage（desktop-apps common）官方 grunt（default=desktop startpage）
#      → third_party/desktop-apps/common/loginpage/deploy/
#   4. make_ascshim.py → entry/.../rawfile/onlyoffice/ascshim.js（node --check 硬校验）
#   4.5 make_empty_templates.py → rawfile/onlyoffice/templates/empty.{docx,xlsx,pptx}
#      （新建卡片空模板；骨架在 scripts/onlyoffice/templates_src/。必须先于装配生成，
#       否则 version.json 哈希不含模板内容 —— 2026-09-05 原为手工步骤，易忘跑）
#   5. build_editors_ohos.py → rawfile/onlyoffice/{webapps,sdkjs,fonts,index.html,
#      smoke,version.json}（注入 ascshim/字体/版本号）
# 之后组装 HAP 与上真机：bash scripts/onlyoffice/deploy_ohos.sh
#
# 正确目录：各官方工程在自己的 build/ 目录内运行 grunt（Gruntfile 相对路径假设）；
# sdkjs 的 build.py 从脚本自身目录推导 ROOT。勿从仓库根运行 grunt。
#
# 前置：
#   - 官方子模块已克隆（git submodule update --init --recursive）
#   - npm 依赖就位（third_party/*/build/ 下 node_modules；首次运行 npm install 于各 build/）
#   - node/npm/python3 在 PATH
# 踩坑记录：hvigor clean 会清 native 产物（勿用）；grunt 慢（web-apps 全量 ~5min），
# 只改本机装配逻辑时用 --no-upstream。
# ============================================================================
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UPSTREAM=1
if [ "${1:-}" = "--no-upstream" ]; then UPSTREAM=0; fi

if [ "$UPSTREAM" = "1" ]; then
  # 子模块补丁前置：仅剩 core 的 OHOS 补丁（native 链编译，core3d）。sdkjs/web-apps
  # 的 desktop 定制已固化为 fork 提交（third_party/{sdkjs,web-apps} 的 ohos 分支，
  # 2026-09-21 fork 化阶段 0）：checkout 即定制态，无需现场应用 patch——
  # patch_sdkjs_desktop.sh / patch_webapps_desktop.sh 与 patches/{sdkjs,webapps}-desktop
  # 已随之退役删除（git 历史可查）。
  echo "== 0/6 子模块补丁（core OHOS）=="
  bash "$ROOT/scripts/onlyoffice/patch_core_ohos.sh"

  echo "== 1/6 web-apps grunt (deploy) =="
  (cd "$ROOT/third_party/web-apps/build" && npx grunt) 2>&1 | tail -3
  [ -f "$ROOT/third_party/web-apps/deploy/web-apps/apps/documenteditor/main/index.html" ] \
    || { echo "!! web-apps deploy 产物缺失" >&2; exit 1; }

  echo "== 2/6 sdkjs build (--desktop) =="
  (cd "$ROOT/third_party/sdkjs" && python3 build/build.py --desktop) 2>&1 | tail -3
  # 断言取引擎主文件：deploy/sdkjs/common/ 里只有子目录（plugins.js 是**源树**
  # 文件 third_party/sdkjs/common/plugins.js，不进 deploy 产物——原断言指它属过时
  # 路径，2026-09-12 补丁化演练中暴露）
  [ -f "$ROOT/third_party/sdkjs/deploy/sdkjs/word/sdk-all.js" ] \
    || { echo "!! sdkjs deploy 产物缺失（word/sdk-all.js）" >&2; exit 1; }

  echo "== 3/6 loginpage grunt (desktop startpage) =="
  (cd "$ROOT/third_party/desktop-apps/common/loginpage/build" && npx grunt) 2>&1 | tail -3
  [ -f "$ROOT/third_party/desktop-apps/common/loginpage/deploy/index.html" ] \
    || { echo "!! loginpage deploy 产物缺失" >&2; exit 1; }
fi

echo "== 4/6 ascshim (make_ascshim.py) =="
python3 "$ROOT/scripts/onlyoffice/desktop/make_ascshim.py"

echo "== 5/6 empty templates (make_empty_templates.py) =="
python3 "$ROOT/scripts/onlyoffice/make_empty_templates.py"

echo "== 6/6 assemble (build_editors_ohos.py) =="
python3 "$ROOT/scripts/onlyoffice/build_editors_ohos.py"

echo "== 完成（deploy: bash scripts/onlyoffice/deploy_ohos.sh）=="
