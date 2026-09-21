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
# 目标设备必须显式指定，无默认值（2026-09-05 用户要求：默认 192.168.1.8 导致
# 忘设 OHOS_DEV 时静默装错设备；用法前缀：OHOS_DEV=192.168.1.4:44959 bash deploy_ohos.sh）
DEV="${OHOS_DEV:-}"
if [ -z "$DEV" ]; then
  echo "错误：未指定目标设备。用法：OHOS_DEV=<ip:port> bash $0" >&2
  exit 1
fi
BUNDLE=app.fuqidian.pureoffice

cd "$ROOT"
# —— 增量资源装配（= grunt-build.sh --no-upstream 的 4/5 步，2026-09-06 合并；
#    make_ascshim 已于 2026-09-21 阶段 2-n 随 ascshim 退役删除——ohos 模块展开与
#    smoke/inject-head.js 生成并入 build_editors_ohos.py）——
# 必须都跑，只跑 assembleHap 是旧坑（2026-09-05 踩过）：
#   make_empty_templates：模板源 → empty.{docx,xlsx,pptx}
#   build_editors_ohos：ohos 模块/smoke head **注入 webapps 各 index.html** + 字体/精灵/版本号
echo "== assemble (templates + inject) =="
python3 "$ROOT/scripts/onlyoffice/make_empty_templates.py" 2>&1 | tail -4
python3 "$ROOT/scripts/onlyoffice/build_editors_ohos.py" 2>&1 | tail -4
# 构建日志 tee 落盘（pipefail 保 rc；失败时 /tmp/deploy_build.log 留完整证据——2026-09-05 审查补）
LOG=/tmp/deploy_build.log
echo "== build =="
"$HVIGORW" assembleHap -p product=default --mode module --no-daemon 2>&1 | tee "$LOG" | tail -3
echo "== install =="
# hdc install 失败时 **rc 仍为 0**（2026-09-12 实测：设备上是 release 包、装 debug 包报
# `code:9568332 install sign info inconsistent` 时 rc=0）——`| tail -1` + pipefail 兜不住，
# 只能查输出文本，否则安装失败被吞成假成功（同类坑见文件头 2026-09-05 注）
INST_OUT="$("$HDC" -t "$DEV" install -r "$HAP" 2>&1)"
echo "$INST_OUT" | tee -a "$LOG" | tail -1
case "$INST_OUT" in
  *"install bundle successfully"*) ;;
  *"sign info inconsistent"*)
    echo "错误：设备上已有签名不同的包（release ↔ debug 不能互相覆盖安装）。" >&2
    echo "须先卸载（**会清空应用沙箱数据**）：$HDC -t $DEV uninstall $BUNDLE" >&2
    exit 1 ;;
  *)
    echo "错误：安装失败（完整输出见 $LOG）" >&2
    exit 1 ;;
esac
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
