#!/usr/bin/env bash
# CJK 字体全量源重建：SDK previewer → scripts/onlyoffice/templates_src/fonts/
#
# 用法：bash scripts/onlyoffice/make_cjk_font_src.sh
# 正确目录：仓库根（脚本自身按 $0 定位，任何 cwd 都可跑）
# 前置：pip3 install --break-system-packages fonttools otf2ttf
# 幂等：产物已存在则跳过；删掉对应产物文件即强制重建
#
# 产物（均**不入库**，见 .gitignore；子集化产物 *.subset.ttf 才入库）：
#   NotoSerifCJK-SC.ttf  宋体族源（SC 面，~31.5MB）
#   NotoSansCJK-SC.ttf   黑体族源（SC 面，~19.9MB）
# 下游：build_editors_ohos.py 的 make_cjk_subset 把它们子集化成
#   *.subset.ttf（GB2312 全集）随 HAP 打包。
#
# 为什么必须有这一步：引擎的 wasm libfont 是精简 freetype，**只吃静态 glyf
#   TrueType**——SDK previewer 里的 Noto CJK 是 CFF 的 .ttc（FT_Open_Face 失败，
#   m_pFaceInfo=null → 字体系统崩），HarmonyOS Sans 原版是可变字体（fvar/gvar →
#   渲染管线崩，2026-09-05 实测白屏）。所以必须先抽面 + CFF→glyf 转换。
#
# 踩坑（勿在别处手敲转换命令）：--face-index 与 TTC 内的面序强耦合，写错面会
#   **静默**换成日文/韩文字形（同一个 TTC 里 JP/KR/SC/TC/HK 依次排列，SC 恰为
#   index 2；Mono 系跟在后面）。下面的 family 名断言就是为挡这个——它同时挡住
#   "换了 SDK 版本、面序变了"的情况。
#
# 另两项字体的取得方式（不在本脚本内，产物同样不入库）：
#   - 仿宋/楷体 Fandol（CTAN fandol v0.3，GPL + font exception）：官方包是 CFF OTF，
#     同样要 CFF→glyf：
#       otf2ttf -o templates_src/fonts/FandolFang.ttf --face-index 0 --overwrite \
#         $CTAN_FANDOL/FandolFang-Regular.otf      # Kai 同理（FandolKai-Regular.otf）
#   - OpenSymbol（MPL-2.0，来自 Debian fonts-opensymbol 包）：
#       apt-get download fonts-opensymbol && dpkg-deb -x fonts-opensymbol*.deb /tmp/osym
#       cp /tmp/osym/x/usr/share/fonts/truetype/libreoffice/opens___.ttf \
#          templates_src/fonts/OpenSymbol.ttf
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DST="$ROOT/scripts/onlyoffice/templates_src/fonts"
# 字体源目录由 env.sh 探测（SDK previewer 自带字库；不写死本机路径）
. "$(dirname "$0")/env.sh" || exit 1
FONTS="${OHOS_CJK_FONTS_DIR:-}"

[ -d "$FONTS" ] || { echo "错误：字体源目录不存在或未探测到：'$FONTS'（可用 OHOS_CJK_FONTS_DIR 覆盖）" >&2; exit 1; }
mkdir -p "$DST"

# build_one <源 TTC 名> <产物名> <face 序> <期望 family 名>
build_one() {
  local src="$1" out="$2" face="$3" want="$4"
  if [ -f "$DST/$out" ]; then
    echo "跳过（已存在）：$out"
    return 0
  fi
  [ -f "$FONTS/$src" ] || { echo "错误：字体源缺失 $FONTS/$src" >&2; exit 1; }
  echo "转换 $src（face_index=$face）→ $out"
  otf2ttf -o "$DST/$out" --face-index "$face" --overwrite "$FONTS/$src"
  python3 - "$DST/$out" "$want" <<'PY'
import sys
from fontTools.ttLib import TTFont
p, want = sys.argv[1], sys.argv[2]
f = TTFont(p, lazy=True)
tabs = set(f.reader.keys())
fam = ([r.toUnicode() for r in f['name'].names if r.nameID == 1] or [''])[0]
assert 'glyf' in tabs and 'CFF ' not in tabs, '产物不是 glyf 轮廓（表：%s）' % sorted(tabs)
assert not ({'fvar', 'gvar'} & tabs), '产物含可变字体表（引擎渲染会崩）'
assert fam == want, 'face 序错：family=%r 期望=%r' % (fam, want)
print('  验证通过：%s  family=%s  glyphs=%d' % (p, fam, len(f.getGlyphOrder())))
PY
}

build_one NotoSerifCJK-Regular.ttc NotoSerifCJK-SC.ttf 2 "Noto Serif CJK SC"
build_one NotoSansCJK-Regular.ttc  NotoSansCJK-SC.ttf  2 "Noto Sans CJK SC"

echo "完成（子集化由 build_editors_ohos.py 的 make_cjk_subset 幂等生成）"
