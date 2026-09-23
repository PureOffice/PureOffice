#!/usr/bin/env bash
# ============================================================================
# 运行时资源缺口审计 —— 设备 web_console.txt 中的 rawfile miss 清单
#
# 背景（2026-09-05）：构建链长期只做「官方产物对拷」，运行时实际缺什么无感知。
# rawfileLoader 已把每次 WebView 请求的 miss 打进 web_console.txt —— 本脚本把
# 这些欠账聚合成清单（去重+计数），是「打包完整性」的证据通道。
#
# 用法：
#   bash scripts/onlyoffice/audit_missing_assets.sh <ip:port>
#     （设备地址必须显式给出；hdc 路径由 env.sh 探测，OHOS_HDC 可覆盖）
#   注意：需要在设备上跑过一轮操作（打开/新建三格式任意组合）后执行，日志才有代表
#   性；清空日志再跑一轮 = 本轮操作的完整缺口基线：
#   hdc shell "> /data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt"
#
# 已知预期的 miss（2026-09-05 审计结论，见 docs/ONLYOFFICE_OHOS_ASSETS_GAP_AUDIT.md）：
#   - _offline_media/*     引擎虚拟媒体缓存区（无供给层，P0，#1）
#   - sdkjs/slide/themes/themes.js  主题面板索引（主题转换链未落地，P1，#3）
#   - fonts_thumbnail_*    字体列表缩略图（P2，#4）
#   - plugins.json / favicon.ico / templates.onlyoffice.com / service worker  P3
#   此脚本只列举，不判定（判定 = 对照审计文档人工或后续基线演进）。
# ============================================================================
set -eo pipefail
. "$(dirname "$0")/env.sh" || exit 1
# 目标设备必须显式指定（位置参数或 OHOS_DEV），同 deploy_ohos.sh 的约定——
# 不给默认值，避免多设备环境下静默查错机器。
DEV="${1:-${OHOS_DEV:-}}"
if [ -z "$DEV" ]; then
  echo "错误：未指定目标设备。用法：bash $0 <ip:port>（或 OHOS_DEV=<ip:port> bash $0）" >&2
  exit 1
fi
CONSOLE=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt

echo "== 运行时 rawfile miss 清单（$DEV）=="
"$HDC" -t "$DEV" shell "grep -oE 'rawfile miss: [^ ]+' $CONSOLE | sort | uniq -c | sort -rn"
echo "== 结束（累计条目 = 每种资源的请求次数）=="
