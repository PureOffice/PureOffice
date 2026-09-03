#!/usr/bin/env bash
# 迭代1：真机部署闭环（构建→安装→重启→探针摘要）
# 用法: bash scripts/onlyoffice/deploy_ohos.sh [--probe]
#   默认: assembleHap + hdc install -r + force-stop + start
#   --probe: 追加读取 probe.txt 关键事件（od:true/ood:*/p5:*/f3:*）
# 注意: 不要对 hvigor 用 clean（会清掉 build/core3d 的 native 产物 libx2t.a 等，
#       重建需 10+ 分钟：gen_cmake.py → cmake configure → cmake --build）。已踩坑。
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
# 工具链/设备环境（可用环境变量覆盖；默认值=当前开发机路径）
HDC="${OHOS_HDC:-/apps/harmony/sdk/default/openharmony/toolchains/hdc}"
HVIGORW="${OHOS_HVIGORW:-/apps/harmony/bin/hvigorw}"
DEV="${OHOS_DEV:-192.168.1.8:33363}"
BUNDLE=app.hackeris.winehua

cd "$ROOT"
echo "== build =="
"$HVIGORW" assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -1
echo "== install =="
"$HDC" -t "$DEV" install -r "$HAP" 2>&1 | tail -1
echo "== restart =="
"$HDC" -t "$DEV" shell "aa force-stop $BUNDLE; sleep 1; aa start -a EntryAbility -b $BUNDLE" 2>&1 | tail -1

if [ "${1:-}" = "--probe" ]; then
  echo "== wait+probe =="
  sleep 45
  "$HDC" -t "$DEV" shell \
    "grep -o 'od:[^|]*\|ood:[^|]*\|p5:[^|]*' /data/app/el2/100/base/$BUNDLE/haps/entry/files/probe.txt | tail -8" || true
fi
echo "== done =="
