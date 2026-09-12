#!/usr/bin/env bash
# 发布包（release 签名，hish 证书）——覆盖发布签名配置 → hvigorw → 无条件还原
# 用法: bash scripts/onlyoffice/pack_release_app.sh [--hap]
#   默认出 .app（上架用）: build/outputs/default/office-default-signed.app
#   --hap 只出 HAP      : entry/build/default/outputs/default/entry-default-signed.hap
# 前置: .temp/publish-signing/build-profile.json5（凭证档，不入库；说明见其 README.md）
# 注意: 本脚本只负责「打包」。rawfile 资源（ascshim / 空模板 / 字体 / webapps 注入）
#   由 deploy_ohos.sh 或 grunt-build.sh 生成——**打之前先确保跑过一次资源生成**，
#   否则打进去的是旧资源（hvigor 不重跑这些 python 生成器）。
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HVIGORW="${OHOS_HVIGORW:-/apps/harmony/bin/hvigorw}"
PUB="$ROOT/.temp/publish-signing/build-profile.json5"
cd "$ROOT"
if [ ! -f "$PUB" ]; then
  echo "错误：缺发布签名配置 $PUB（见 .temp/publish-signing/README.md）" >&2
  exit 1
fi
# 还原必须无条件执行：构建失败/中断都不许把发布凭证留在项目 build-profile.json5 里
# （留着会被 git status 看见并可能被误提交）
trap 'git checkout -- build-profile.json5 && echo "== build-profile.json5 已还原（debug 档）=="' EXIT
cp "$PUB" build-profile.json5
echo "== 发布签名档已挂载 =="
if [ "${1:-}" = "--hap" ]; then
  "$HVIGORW" assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -3
  APPOUT="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
else
  "$HVIGORW" assembleApp -p product=default --no-daemon 2>&1 | tail -3
  APPOUT="$ROOT/build/outputs/default/office-default-signed.app"
fi
[ -f "$APPOUT" ] || { echo "错误：产物缺失 $APPOUT" >&2; exit 1; }
echo "产物: $APPOUT"
echo "      $(stat -c%s "$APPOUT") bytes / $(date -r "$APPOUT" '+%F %T')"
