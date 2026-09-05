#!/usr/bin/env bash
# 迭代1：真机部署闭环（构建→安装→重启→探针摘要）
# 用法: bash scripts/onlyoffice/deploy_ohos.sh [--probe]
#   默认: assembleHap + hdc install -r + force-stop + start
#   --probe: 追加读取 web_console.txt 当前链关键事件（open/save/bridge 链 LSO_*/SAVE_BIN_* 等；
#            页面日志统一落 files/dir/web_console.txt，EditorPage.ets onConsole）
# 注意: 不要对 hvigor 用 clean（会清掉 build/core3d 的 native 产物 libx2t.a 等，
#       重建需 10+ 分钟：gen_cmake.py → cmake configure → cmake --build）。已踩坑。
# pipefail：hvigor/build 失败时管道（| tail -1）不再吞掉退出码（2026-09-05 踩坑：
#   构建失败仍走 install 旧 HAP 并报成功）
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
# 工具链/设备环境（可用环境变量覆盖；默认值=当前开发机路径）
HDC="${OHOS_HDC:-/apps/harmony/sdk/default/openharmony/toolchains/hdc}"
HVIGORW="${OHOS_HVIGORW:-/apps/harmony/bin/hvigorw}"
DEV="${OHOS_DEV:-192.168.1.8:33363}"
BUNDLE=app.hackeris.winehua

cd "$ROOT"
# ascshim 先行生成（src/*.js 改动必须先进包——2026-09-05 踩坑：改了页面探针
# 未生成 ascshim，旧包白跑一轮；ascshim.js 是生成产物勿手改）
echo "== shim =="
python3 "$ROOT/scripts/onlyoffice/desktop/make_ascshim.py" 2>&1 | tail -2
# 新建空模板同样随包走（make_empty_templates.py 幂等生成 empty.{docx,xlsx,pptx}；
# 与 grunt-build.sh 主链同源，部署前重跑保证模板源改动进包——2026-09-05 补）
echo "== empty templates =="
python3 "$ROOT/scripts/onlyoffice/make_empty_templates.py" 2>&1 | tail -4
# 构建日志 tee 落盘（pipefail 保 rc；失败时 /tmp/deploy_build.log 留完整证据——2026-09-05 审查补）
LOG=/tmp/deploy_build.log
echo "== build =="
"$HVIGORW" assembleHap -p product=default --mode module --no-daemon 2>&1 | tee "$LOG" | tail -3
echo "== install =="
"$HDC" -t "$DEV" install -r "$HAP" 2>&1 | tee -a "$LOG" | tail -1
echo "== restart =="
"$HDC" -t "$DEV" shell "aa force-stop $BUNDLE; sleep 1; aa start -a EntryAbility -b $BUNDLE" 2>&1 | tee -a "$LOG" | tail -1

if [ "${1:-}" = "--probe" ]; then
  echo "== wait+probe =="
  sleep 45
  # 诊断输出，非门禁（grep 无匹配不退出非零——验收语义请用 smoke 链路判定，2026-09-05 注）
  "$HDC" -t "$DEV" shell \
    "grep -oE 'LSO_OPEN_DOCUMENT_OK|LSO_NATIVE_SAVE[^|]*|SAVE_BIN_X2T[^|]*|SAVE_BIN_BACK[^|]*|PAGE_END[^|]*|PROF_SNAP[^|]*' /data/app/el2/100/base/$BUNDLE/haps/entry/files/web_console.txt | tail -12" || true
fi
echo "== done =="
