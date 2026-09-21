#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""官方桌面链装配：web-apps deploy 产物 → rawfile/onlyoffice/

== 唯一部署入口（2026-09-05 起；pack_web.py 已废弃，见其头部） ==

用法（正确命令/目录）：
  bash scripts/onlyoffice/desktop/grunt-build.sh          # 全链：官方 grunt 产物→本装配
  bash scripts/onlyoffice/desktop/grunt-build.sh --no-upstream  # 仅装配（grunt 产物已就位）
  bash scripts/onlyoffice/build_editors_ohos.py           # 本装配单独运行（dev 迭代用）
产物路径一览（生成物）：
  entry/src/main/resources/rawfile/onlyoffice/
    webapps/ sdkjs/ fonts/ index.html smoke/ version.json ascshim.js
  （ascshim.js 由 make_ascshim.py 生成；本脚本消费并断言其存在）

流程：
  1. third_party/web-apps/deploy/web-apps/（官方 grunt 产物）→ rawfile/onlyoffice/webapps
  2. 删除  ie/mobile/embed 子变体（官方 build_js.py:65-66 同）
  3. apps/api/documents/index.html.desktop → index.html（官方 build_js.py:68 同）
  4. 编辑器 main/index.html 注入 ascshim.js（<head> 前导；不改官方源）
  5. sdkjs deploy（--desktop 构建，含 Local/*.js 保存链）→ rawfile/onlyoffice/sdkjs
  6. 字体（AllFonts.js + fonts/ 预加密）→ rawfile/onlyoffice/
  7. loginpage/deploy/index.html → rawfile/onlyoffice/index.html（欢迎页）
  8. 【阶段3】version.json 生成（资源内容哈希 → 编辑页 URL ?v= cache-bust，
     EditorPage.ets 构建期不再手工递增 VERSION_BUMP）
  9. 【阶段3】smoke 页面脚本 → rawfile/onlyoffice/smoke/（自动验收诊断注入源；
     见 scripts/onlyoffice/smoke/*.js）
  10. smoke 验收样本（样本 docx/xlsx/pptx、demo-cn.*）集中 at rawfile/onlyoffice/smoke/
     （2026-09-06 用户：smoke 相关文件单独目录存放；EditorPage.ets 读取路径同步
     onlyoffice/smoke/ 前缀；样本源为手工维护文件，随包资源直接放在该目录）
  11. 【2026-09-06】官方 AI 插件 → rawfile/onlyoffice/plugins/ + plugins.json
     （web 语义插件装配清单；资产源 scripts/onlyoffice/plugins/，详见 install_ai_plugin）

== AI 插件（2026-09-06 正式接入） ==
  2026-09-05 曾撤回（用户决策：专注基础功能）；本版按官方 web 语义重新接入：
  plugins.json（web-apps Plugins.js:165 server 链）→ plugins/ai（官方 ai.plugin
  3.2.2 发布包，AGPL）+ plugins/v1（官方 web 插件框架）→ isSupportPlugins 已提真
  （ascBridge.ets；sdkjs common/plugins.js:977 run() 第一道门——9-04/9-05「按钮
  无反应」硬根因）。不做任何定时器/装配包装（官方链 onDocumentContentReady→
  app:ready→setApi→loadPlugins 自足）。后端由用户在 AI 插件设置页自配
  （Ollama/DeepSeek 等；插件请求直接 fetch，无代理依赖）。
"""
import os
import re
import hashlib
import json
import shutil
import argparse
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'third_party', 'web-apps', 'deploy', 'web-apps')
SDK_SRC = os.path.join(ROOT, 'third_party', 'sdkjs', 'deploy', 'sdkjs')
DST = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice')
W3D = os.path.join(DST, 'webapps')
SDK_DST = os.path.join(DST, 'sdkjs')
PLUGIN_SRC = os.path.join(ROOT, 'scripts', 'onlyoffice', 'plugins')
PLUGIN_DST = os.path.join(DST, 'plugins')          # 本地插件目录（web 语义 server_plugins 链消费）
LOGIN = os.path.join(ROOT, 'third_party', 'desktop-apps', 'common', 'loginpage', 'deploy', 'index.html')
# 产品版本号（About 面板版本行展示；与资源哈希 version.json.v 分开：v 是 URL
# 缓存指纹（不展示），ver 是对用户展示的产品版本）。单一数据源 = AppScope/app.json5
# 的 versionName——AGC 上架要求递增的同一处，改一处即两处同步（此前是本文件里的
# 独立常量，2026-09-17 发现 About 显示 1.0.0 而包已 1.0.45 = 第二个数据源的漂移）。
# 读不到即失败退出，不静默回落（回落值会让 About 显示错误版本且无人察觉）。
# 用正则而非 json 解析：app.json5 是 json5（可含注释/尾逗号），单字段提取更稳。
def _read_app_version():
    with open(os.path.join(ROOT, 'AppScope', 'app.json5'), encoding='utf-8') as f:
        m = re.search(r'"versionName"\s*:\s*"([^"]+)"', f.read())
    if not m:
        raise SystemExit('AppScope/app.json5 未找到 versionName——About 版本号无来源')
    return m.group(1)


PRODUCT_VERSION = _read_app_version()
FONT_DST = os.path.join(DST, 'fonts')          # GlobalLoaders.fontFilesPath - ../fonts/
# 系统字体路径（Environment 可覆盖：OHOS_LIBERATION_FONTS；跨机不统一时保持一致性
# —— 字体版本差异会反映进 version.json 哈希，2026-09-05 审查补）
SYSTEM_FONTS_DIR = os.environ.get('OHOS_LIBERATION_FONTS', '/usr/share/fonts/truetype/liberation')
# 中文字体路径（HarmonyOS SDK previewer 自带 CJK 字库；OHOS_CJK_FONTS_DIR 可覆盖。
# —— 2026-09-05 用户目标「默认中文」：此前字体表只有拉丁字族，中文渲染全为方块）
CJK_FONTS_DIR = os.environ.get('OHOS_CJK_FONTS_DIR',
                               '/apps/harmony/sdk/default/hms/previewer/resources/fonts')
# 顺序必须 R,I,B,BI（ascshim __fonts_files 注入数组与 FONT_INFOS 的 indexI/indexB 下标一致）
# 下标 12 = HarmonyOS_Sans_SC.ttf（黑体/无衬线 CJK；无独立 Bold/Italic 文件：
# R/I/B/BI 共用 regular，加粗/倾斜由引擎模拟——与 OpenSymbol 行（全下标 16）同约定）
# 下标 13 = NotoSerifCJK-SC.ttf（宋体/衬线 CJK —— 2026-09-05 宋体修复：真宋体，
#   用户选「宋体」渲染成无衬线黑体的根因=宋体族行全映射下标 12；见 FONT_INFOS）
# 曾试用 NotoSansCJK_SC-Regular.otf（CFF）：引擎 wasm libfont 为精简 freetype，
# FT_Open_Face 对 CFF 失败（m_pFaceInfo=null → 字体系统崩溃）——弃；
# 2026-09-05 实测记录。HarmonyOS_Sans_SC.ttf = glyf + gvar（可变字体但仍为
# TrueType 轮廓，freetype 可打开）。
FONT_FILES = ['LiberationSans-Regular.ttf', 'LiberationSans-Italic.ttf',
              'LiberationSans-Bold.ttf', 'LiberationSans-BoldItalic.ttf',
              'LiberationSerif-Regular.ttf', 'LiberationSerif-Italic.ttf',
              'LiberationSerif-Bold.ttf', 'LiberationSerif-BoldItalic.ttf',
              'LiberationMono-Regular.ttf', 'LiberationMono-Italic.ttf',
              'LiberationMono-Bold.ttf', 'LiberationMono-BoldItalic.ttf',
              'HarmonyOS_Sans_SC.ttf', 'NotoSerifCJK-SC.ttf',
              # 下标 14/15 = 仿宋/楷体（2026-09-07 字体扩充：Fandol 字体集，CTAN
              # fandol v0.3，GPL + GPL font exception——随包分发合规）。来源/转换
              # 见 FONT_SUBSETS 注释（CFF→glyf 同宋体链）。
              'FandolFang.ttf', 'FandolKai.ttf',
              # 下标 16 = 符号字体（2026-09-11）。依据：引擎 libfont/map.js 的
              # ChangeGlyphsMap 把 Symbol/Wingdings 的码位**映射到 OpenSymbol 的
              # 私用区**（MapDst = 0xE12C/0xE442/0xE441/0xE25F/0xE46F/0xE330/0x2751/
              # 0xE43A/0xE439/0xE469）——即这两个符号字体须由**名为 OpenSymbol 的
              # 字体**承载；此前两行 indexR 指向 Liberation Sans（无 PUA/数学符号
              # 字形）⇒ Symbol 文本缺字形、Wingdings 文本全灭。来源见 FONT_SRC
              # 注释，MPL-2.0 可随包分发。
              'OpenSymbol.ttf']
# 字体文件来源目录：Liberation → SYSTEM_FONTS_DIR；CJK → templates_src/fonts
# （CJK 源为 HarmonyOS SDK previewer 字体经转换/子集化的**静态 glyf TTF**。
# 踩坑记录（2026-09-05，勿回退）：
#   1. VF 原文件（含 fvar/gvar）→ 引擎渲染管线崩溃（白屏/1 页空）；
#   2. Noto CFF（.otf）→ wasm libfont（精简 freetype）FT_Open_Face 失败
#      （m_pFaceInfo=null）——只支持 glyf TrueType。
# 复现（在构建机，需 fontTools + otf2ttf/pip 包 + 字体源）：
#   - 黑体：HarmonyOS_Sans_SC.ttf（SDK previewer，可变字体）实例化静态化——
#     python3 -c "
# from fontTools.ttLib import TTFont
# from fontTools.varLib.instancer import instantiateVariableFont
# f = TTFont('$CJK_FONTS_DIR/HarmonyOS_Sans_SC.ttf')
# instantiateVariableFont(f, {})
# for t in ('fvar','gvar','STAT','avar','cvar','MVAR','HVAR','VVAR'):
#     t in f and del f[t]
# f.save('scripts/onlyoffice/templates_src/fonts/HarmonyOS_Sans_SC.ttf')"
#   - 宋体：NotoSerifCJK-Regular.ttc（SDK previewer，CFF 字库）CFF→glyf（otf2ttf
#     >=0.2，pip3 install --break-system-packages otf2ttf）——取 SC 面（TTC 面序
#     JP/KR/SC/TC/HK → face_index=2）：
#     otf2ttf -o scripts/onlyoffice/templates_src/fonts/NotoSerifCJK-SC.ttf \
#       --face-index 2 --overwrite $CJK_FONTS_DIR/NotoSerifCJK-Regular.ttc
#     产物 31.5MB（全量，**不入库**——过大；子集化产物才入库，见 FONT_SUBSETS）。
FONT_SRC_BY_FILE = {fn: SYSTEM_FONTS_DIR for fn in FONT_FILES[:12]}
FONT_SRC_BY_FILE['HarmonyOS_Sans_SC.ttf'] = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts')
FONT_SRC_BY_FILE['NotoSerifCJK-SC.ttf'] = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts')
FONT_SRC_BY_FILE['FandolFang.ttf'] = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts')
FONT_SRC_BY_FILE['FandolKai.ttf'] = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts')
# OpenSymbol（LibreOffice 符号字体；许可 MPL-2.0 含部分 Apache-2.0，版权 Sun
# Microsystems/Google/LibreOffice 贡献者）——静态 glyf TTF、1066 字形、无 VF/CFF，
# 引擎可直接打开。复现（构建机）：
#   apt-get download fonts-opensymbol && dpkg-deb -x fonts-opensymbol*.deb /tmp/osym
#   cp /tmp/osym/x/usr/share/fonts/truetype/libreoffice/opens___.ttf \
#      scripts/onlyoffice/templates_src/fonts/OpenSymbol.ttf
# 改名理由：文件名/注册行名/face 内部名三者一致（渲染槽按 face 名回查注册表）。
FONT_SRC_BY_FILE['OpenSymbol.ttf'] = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts')

# —— 系统字体（2026-09-07 v2 终版：多机交集方针，设备直读 /system/fonts）——
# 用户方针：**1.4 与 1.8 都可用**（各自/交集）——实测两机清单：1.4=260 款（含
# 方正 FZ 全系/HarmonyOS 全系——仅 1.4 有），1.8=203 款（Noto 语系+HarmonyOS
# 部分）；交集=1.8 全集合（203 款）→ 系统注册表**只放交集文件**（任何一机装上
# 同一 HAP 都能渲染——列表不鬼影）。交集里中文 glyf 静态款仅 HYQiHeiL3（汉仪
# 旗黑）+ 语系静态 Regular 系（Noto*UI-Regular 等）；HarmonyOS Sans SC 原版是
# 可变字体（gvar——引擎崩，2026-09-05 VF 坑；包内已用静态化版）、Noto CJK 是
# CFF TTC（FT_Open_Face 失败）——交集机制下均不可用。仿宋/楷体（FZ 系仅 1.4
# 有，非交集）由包内 Fandol 承担——跨机一致。
# face 内部 family name 实测（构建机 fontTools 解析设备源文件，2026-09-07）：
#   HYQiHeiL3.ttf→'HYQiHei L3'；NotoSansBengaliUI-Regular.ttf→'Noto Sans Bengali UI'；
#   NotoSansDevanagariUI-Regular.ttf→'Noto Sans Devanagari UI'（全部 glyf 静态无 VF）。
# 机制：页面 09_fonts.js XHR onlyoffice/systemfonts/<name> → rawfileLoader 拦截 →
#   convertershell readSystemFontSync（native ifstream；ArkTS fileIo 系统根路径
#   一律 ENOENT——2026-09-07 实测是「目标机清单差异」而非权限——wine 普通应用
#   进程可读（wineohos freetype.c ReadFontDir 佐证）→ native 返回前 XOR
#   FONT_GUID_ODTTF 前 32B（= pre_xor_font 加密态）→ 页面 xorDecode 还原装填。
# 下标 = len(FONT_FILES) 起（现为 17 起；Fandol 占 14/15——仿宋/楷体不在交集，
#   系统桥不提供与它们同名能力，Fandol 为跨机一致来源；OpenSymbol 占 16——包内
#   符号字体，非系统行，故系统行起点由 16 顺延至 17）。新增交集字体时追加
#   SYSTEM_FONT_FILES + INFOS 行（face 名行）+ 本注释更新 face 名。
SYSTEM_FONT_FILES = ['HYQiHeiL3.ttf',
                     'NotoSansBengaliUI-Regular.ttf',
                     'NotoSansDevanagariUI-Regular.ttf']
# 注入 __fonts_files / 精灵行序列引用：rawfile + system（make_ascshim 同源导入）
FONT_FILES_ALL = FONT_FILES + SYSTEM_FONT_FILES

# 子集映射：final 名（FONT_FILES/rawfile fonts/ 里的名字）→ (全量源文件, 子集产物,
# 注册面名——渲染槽 name 匹配用；CJK 族注册行名须一致。宋体=SimSun（引擎把
# '宋体' 归一为 'SimSun'），黑体=None（内部名已=注册行名 'HarmonyOS Sans SC'）。
# 子集产物入库（git）：宋体全量 31.5MB 太大不适于库；subset 缺失时可从全量源重建
# （otf2ttf 命令见上注释；黑体全量在库、subset 为构建中间产物不入库）。
FONT_SUBSETS = {
    'HarmonyOS_Sans_SC.ttf': ('HarmonyOS_Sans_SC.ttf', 'HarmonyOS_Sans_SC.subset.ttf', None),
    'NotoSerifCJK-SC.ttf': ('NotoSerifCJK-SC.ttf', 'NotoSerifCJK-SC.subset.ttf', 'SimSun'),
    # 仿宋/楷体（2026-09-07 字体扩充，用户「支持更多字体」目标）：Fandol（CTAN
    # fandol v0.3，GPL + GPL font exception）。官方包里是 **CFF OTF**（fandol/
    # FandolFang-Regular.otf）——引擎 wasm libfont 只吃 glyf TrueType（CFF 崩，
    # 2026-09-05 实测）→ 先 otf2ttf（见 FONT_SRC_BY_FILE 注释同款命令）：
    #   otf2ttf -o templates_src/fonts/FandolFang.ttf --face-index 0 --overwrite \
    #     $CTAN_FANDOL/FandolFang-Regular.otf
    # 产物 7.6/8.8MB（**全量不入库**——可从 CTAN mirrors.ctan.org/fonts/fandol.zip
    # 复现；subset 入库，全新克隆由 make_cjk_subset 幂等复用，同宋体策略）。
    # 注册面名：FandolFang 官方内部 name='FandolFang R'（含空格+后缀，与
    # 「FandolFang」不符 → name 重写 family='FandolFang' 强制统一，Kai 同理）。
    # subset 实测 5.7/6.8MB（楷体笔画复杂大过宋体——make_cjk_subset 上限已
    # 放宽至 8MB，2026-09-07）。
    'FandolFang.ttf': ('FandolFang.ttf', 'FandolFang.subset.ttf', 'FandolFang'),
    'FandolKai.ttf': ('FandolKai.ttf', 'FandolKai.subset.ttf', 'FandolKai'),
}

# 字体注册表（引擎 Externals.js checkAllFonts 契约）
# 中文字族：文档字体名（黑体族：HarmonyOS Sans SC/微软雅黑/Noto Sans 等）→ 下标 12
# （黑体文件）；宋体族（宋体/SimSun/Songti SC/simsun.ttf）→ 下标 13（真宋体文件）——
# 引擎按名字行匹配到即可从对应文件取字形；避免「未命中名→fallback Liberation Sans
# → 中文字符无字形→方块」；宋体族不重定向黑体（2026-09-05 宋体显示乌龙实证）。
FONT_INFOS = [
    # Arial 保持 Liberation（2026-09-05 实测：把 Arial 重定向到大号 CJK 字体
    # 会拖崩 libfont 渲染管线——1 页空白回归。原因未细究但证据明确：
    # 重定向后 UHR/m_pFaceInfo null 持续、文档域空白）。真实中文文档的
    # eastAsia 字体名（宋体/微软雅黑/Noto Sans CJK SC 等行——见下）命中 CJK
    # 文件；「未指定字体且 eastAsia=Arial」的样本文档仍需文档侧声明中文
    # 字体（Word 生成的文档默认声明宋体等，属正常实况）。
    ["Arial", 0, 0, 1, 0, 2, 0, 3, 0],
    ["Liberation Sans", 0, 0, 1, 0, 2, 0, 3, 0],
    ["Times New Roman", 4, 0, 5, 0, 6, 0, 7, 0],
    ["Courier New", 8, 0, 9, 0, 10, 0, 11, 0],
    # 符号字体（2026-09-11）：**只注册 OpenSymbol 行，不要注册 Symbol/Wingdings 行**。
    # 机制（map.js 源码实证）：
    #   ① ChangeGlyphsMap[name] 的替换条目要求 entry.Name === objDst.Name，而
    #      objDst.Name = GetFontFileWeb(name).m_wsFontName = **选中行的行名**——
    #      只有"实际选中 OpenSymbol 行"时码位映射（MapSrc→MapDst）才生效；
    #   ② 官方 FD_Ascii_Font_Like_Names[1] = ["OpenSymbol"]，且 FD_Ascii_Font_Like_Main
    #      把 Symbol/Wingdings 也标为类 1 → CheckLikeFonts('OpenSymbol','Wingdings')
    #      = true（GetPenalty 记 700，优于其他任何候选）；
    #   ③ 若表里存在与请求精确同名的 Symbol/Wingdings 行，精确匹配抢先命中，
    #      行名即请求名 → 映射不生效。真机实测该形态：字符按原码位渲染，
    #      Wingdings 键位（v w Ø …）因 OpenSymbol 无拉丁字母而整体变方块。
    # 故**删两行**、让请求经相似类 1 落到 OpenSymbol 行 → GetReplaceGlyph 走
    # MapSrc/MapDst（0x76→U+E441 等 10 组）、Symbol 的 0xB7/0xA8→●/◆ 亦生效；
    # 未列入 MapSrc 的字符（如 ∀∂∑√α）原样用 OpenSymbol 渲染——该字体自带这些字形。
    ["OpenSymbol", 16, 0, 16, 0, 16, 0, 16, 0],
    # HarmonyOS Sans SC：引擎 CJK fallback 的实际请求名（字符缺字形时
    # GetFontIndex 按此名选字体）。此前本表只有文件名 HarmonyOS_Sans_SC.ttf
    # （FONT_FILES）而没有同名条目 → 候选列表此项不在 → GetFontIndex 无精确
    # 匹配短路 DefaultIndex=Arial → fallback 死循环 → 中文字形方块
    # （2026-09-05 实测：PROF_LF 反复 "HarmonyOS Sans SC -> dst=Arial"；
    # PROF_LIST n=18 恰等于旧 FONT_INFOS 行数，果无此项）。
    ["HarmonyOS Sans SC", 12, 0, 12, 0, 12, 0, 12, 0],
    ["Noto Sans CJK SC", 12, 0, 12, 0, 12, 0, 12, 0],
    ["Microsoft YaHei", 12, 0, 12, 0, 12, 0, 12, 0],
    ["微软雅黑", 12, 0, 12, 0, 12, 0, 12, 0],
    ["SimHei", 12, 0, 12, 0, 12, 0, 12, 0],
    ["黑体", 12, 0, 12, 0, 12, 0, 12, 0],
    # 下标 13 = NotoSerifCJK-SC.ttf（真宋体/衬线，2026-09-05 宋体修复：FONT_INFOS
    # 里宋体族（宋体/SimSun/Songti SC/simsun.ttf）此前全映射下标 12（黑体）——
    # 用户选「宋体」输入文字渲染成**无衬线黑体样式**，实测确认。真宋体行
    # indexR=13（与下表中黑体族行 12 区分；微软雅黑/黑体/Noto Sans 等仍 12）。
    ["SimSun", 13, 0, 13, 0, 13, 0, 13, 0],
    ["宋体", 13, 0, 13, 0, 13, 0, 13, 0],
    ["Songti SC", 13, 0, 13, 0, 13, 0, 13, 0],
    # 「字典文件记录名」（带 .ttf 后缀）行（simsun.ttf/simhei.ttf/msyh.ttf）——
    # 2026-09-05 源码复核（map.js GetPenalty/GetFaceNamePenalty/CheckLikeFonts）：
    # **不是**任何硬编码字体字典的键（旧注释“map.js FD_FontDictionary 硬编码
    # base64 归一”不准确——FD_FontDictionary 是运行时构建结构）。真实机制：
    # ① g_map_font_index[行名] 由 Externals.checkAllFonts 直接以 __fonts_infos
    #    行 0 为键构建（Externals.js:669）——即 FONT_INFOS 行名本身就是查表键；
    # ② '宋体' 请求经 GetPenalty **名字相似度匹配**（'宋体' vs 候选 'SimSun'
    #    NamePenalty=0，官方别名等价）返回 SimSun 行 —— 因此「宋体/SimSun/
    #    simsun.ttf」三行指向同一 indexR 是**别名重复**，并非三级归一链；
    # ③ simsun.ttf 行仅供带 .ttf 后缀形式的请求名（个别 API 回显 m_wsFontPath
    #    用此形式）命中，保持 indexR 一致即可（13/12/12 现正确）。
    ["simsun.ttf", 13, 0, 13, 0, 13, 0, 13, 0],
    ["simhei.ttf", 12, 0, 12, 0, 12, 0, 12, 0],
    ["msyh.ttf", 12, 0, 12, 0, 12, 0, 12, 0],
    # 仿宋/楷体族（2026-09-07 字体扩充）。约定同宋体区：行名须与 wasm face
    # family Name 一致（FONT_SUBSETS 的注册面名=FandolFang/FandolKai，name
    # 重写后匹配）；中文/英文/GB2312/.ttf 变体行指向同 indexR=文件下标 14/15。
    # 样式：仅 Regular 文件，R/I/B/BI 全部用 regular（加粗由引擎模拟，同黑体）。
    # 文档侧常见 eastAsia 声明：仿宋、仿宋_GB2312、FangSong；楷体、楷体_GB2312、
    # KaiTi（Word 中文环境默认）。「未匹配时引擎 name 相似度匹配」在此补充分
    # 显式别名行（官方 NamePenalty=0 别名集仅覆盖宋体/黑体，仿宋/楷体不在内）。
    ["FandolFang", 14, 0, 14, 0, 14, 0, 14, 0],
    ["仿宋", 14, 0, 14, 0, 14, 0, 14, 0],
    ["FangSong", 14, 0, 14, 0, 14, 0, 14, 0],
    ["仿宋_GB2312", 14, 0, 14, 0, 14, 0, 14, 0],
    ["fangsong.ttf", 14, 0, 14, 0, 14, 0, 14, 0],
    ["FandolKai", 15, 0, 15, 0, 15, 0, 15, 0],
    ["楷体", 15, 0, 15, 0, 15, 0, 15, 0],
    ["KaiTi", 15, 0, 15, 0, 15, 0, 15, 0],
    ["楷体_GB2312", 15, 0, 15, 0, 15, 0, 15, 0],
    ["kaiti.ttf", 15, 0, 15, 0, 15, 0, 15, 0],
    # 系统字体行（2026-09-07 v2 终版：多机交集）。下标 = len(FONT_FILES) 起（17 起）。
    # 约定：**face 名真身行**（= face 内部 name，见 SYSTEM_FONT_FILES 注释实测值）
    # + 中文别名行（单一族、无重名——dict 后写覆盖坑已避）。『仿宋/楷体』中文名
    # 已注册到 Fandol（14/15，跨机一致）——系统行严禁再注册同名。
    ["HYQiHei L3", 17, 0, 17, 0, 17, 0, 17, 0],
    ["汉仪旗黑", 17, 0, 17, 0, 17, 0, 17, 0],
    ["Noto Sans Bengali UI", 18, 0, 18, 0, 18, 0, 18, 0],
    ["Noto Sans Devanagari UI", 19, 0, 19, 0, 19, 0, 19, 0],
]

# —— 内部字体行（不进用户字体下拉）——
# 事实源只有这一处：行**必须**注册（候选列表 = g_fonts_selection_bin，Symbol/Wingdings
# 的码位映射依赖请求能落到「OpenSymbol」行——见上该行注释的 map.js 机制），但下拉每项
# 以**自身字体**渲染名字，而 OpenSymbol 无任何拉丁字形（cmap 实测 O/p/e/n/S/y/m/b/o/l
# 全缺）→ 该行整条显示为方块（2026-09-12 真机 1.5 截图实证）。
# 派生链：gen_allfonts 注入 window["__lso_font_hidden"] → ascshim 30_open.js 的
# sync_InitEditorFonts wrap 在归一收集时跳过这些名字（与 .ttf 文件名行剔除同一处判断）。
# 新增内部行只改本清单——**禁止在页面侧硬编码字体名**。
UI_HIDDEN_FONT_ROWS = ['OpenSymbol']

# —— 字符范围回退表（引擎 libfont/character.js CFontByCharacter.init 消费的第三张
# 注入表 window["__fonts_ranges"]，格式 [start, end, infoRowIndex, ...] 展平三元组；
# 语义：Unicode [start, end] 中字符若在文档字体中缺字形，回退到
# FONT_INFOS[infoRowIndex][0] 字族 —— 2026-09-05 中文方块最后根因：
# 此前只注入 __fonts_files/__fonts_infos，缺这张表 → Ranges 空 → 任何 CJK 字符
# 回退失败 → 全部渲染为方块（引擎源代码 libfont/character.js:74 init 直接 return）。
# infoRowIndex 一律取 FONT_INFOS 中「宋体」行（= FONT_INFOS_ROWS["宋体"]，按**行名**
# 动态取；行号是 FONT_INFOS 数组下标、与文件 indexR 无关——增删字体行会使其位移，
# 故**禁止硬编码**。回退到宋体=中文常用字回退到衬线，同官方 Windows 语义）：
FONT_INFOS_ROWS = {row[0]: i for i, row in enumerate(FONT_INFOS)}
CJK_ROW = FONT_INFOS_ROWS["宋体"]
# 段清单：CJK 部首/符号+假名（2E80-30FF）、CJK 核心表意（4E00-9FFF）、
# 中日韩扩展 A（3400-4DBF）、全角标点/形式（FF00-FFEF）、I/S 谐义标点（3000-303F）
# —— 拉丁（0000-00FF）不设回退（各字族自带）。
FONT_RANGES = []
for _s, _e in [(0x2E80, 0x30FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF),
               (0x3000, 0x303F), (0xFF00, 0xFFEF)]:
    FONT_RANGES.extend([_s, _e, CJK_ROW])
FONT_GUID_ODTTF = bytes([0xA0, 0x66, 0xD6, 0x20, 0x14, 0x96, 0x47, 0xFA, 0x95, 0x69, 0xB8, 0x50, 0xB0, 0x41, 0x49, 0x48])

# —— B：CJK 字体子集化（2026-09-05 默认中文方案 B；2026-09-05 宋体修复泛化为
#     黑体+宋体双字体，见 FONT_SUBSETS 映射）——
# 9.25MB HarmonyOS_Sans_SC.ttf 是 14 个字体中唯一大文件：A（09_fonts 装填）虽把
# 字节保供提前到文档打开前，XHR 字节体积仍是毫秒 vs 秒的观感差；子集化后 ~1.9MB
# （黑体）/5.2MB（宋体衬线——笔画弯钩多，字形数据天然大于黑体；实测装填 <2s
# 仍无首帧竞态窗口），装填几乎瞬时，且对「首帧竞态」再无任何概率窗口。
# 字符集：GB2312 全集（6763 汉字 + 符号/字母区 A1A1-F7FE）+ ASCII + Latin-1
#   + CJK 标点（3000-303F）+ 全角形式（FF00-FFEF）。
#   取舍：BMP 扩展 A 区（3400-4DBF）生僻字不在子集内——此类字符渲染 notdef
#   （与桌面版「常用字库」取舍一致；文档实际内容多为常见字）。
# 前提：fontTools（pip install fonttools；构建机 4.63.0 实测 OK）+ 全量源字体。
# 输入源必须是**静态 glyf TTF**（templates_src/fonts/ 现成产物，勿用 VF/ CFF，
# 见 FONT_SRC_BY_FILE 注释踩坑记录）——子集化不改字体名/表序，__fonts_files
# 与 ascshim 09_fonts 装填（ID=final 名）不受影响。


def _cjk_unicodes():
    """GB2312 全集（A1A1-F7FE 可解码字符）+ ASCII/Latin-1/CJK 标点/全角。"""
    ret = set()
    for b1 in range(0xA1, 0xF8):
        for b2 in range(0xA1, 0xFF):
            try:
                ret.add(ord(bytes([b1, b2]).decode('gb2312')))
            except UnicodeDecodeError:
                pass  # 空位/单字节区
    ret.update(range(0x0020, 0x007F))     # ASCII（引擎拉丁 path 同用）
    ret.update(range(0x00A0, 0x0100))     # Latin-1
    ret.update(range(0x3000, 0x3040))     # CJK 标点
    ret.update(range(0xFF00, 0xFFF0))     # 全角形式
    return ret


def make_cjk_subset(src, out, family=None):
    """pyftsubset 子集化（幂等：产物存在且不早于源 → 复用；**产物存在但全量源
    缺失（如宋体 31.5MB 不入库）→ 也复用产物**——否则全新克隆无法构建）。
    family 非 None 时**重写 name 表**（ID1/2/3/4/6/16/17 设为 family——引擎渲染槽
    按 wasm face 的 family Name 与文档请求名匹配；Noto Serif CJK SC 内部名与注册
    行名（宋体/SimSun）不符 → 槽失效 → 整 run 空白（2026-09-05 真机实测：连拉丁
    'dd' 都不绘制=run 级空，非字形级）。成功后返回产物路径。
    失败 raise SystemExit —— 构建链非零退出（缺 fontTools/CLI/尺寸越界/缺关键字形）"""
    import subprocess
    if os.path.isfile(out) and (not os.path.isfile(src)
                                or os.path.getmtime(out) >= os.path.getmtime(src)):
        if family:
            rewrite_font_name(out, family)
        return out
    unicodes = ','.join('U+%04X' % cp for cp in sorted(_cjk_unicodes()))
    cmd = ['pyftsubset', src, '--unicodes=' + unicodes,
           '--output-file=' + out, '--layout-features=*']
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        raise SystemExit('pyftsubset 失败（%s）: %s' % (src, e.stderr.decode(errors='replace')[:500]))
    size = os.path.getsize(out)
    if not (100_000 < size < 8_000_000):
        # 上限 8MB（原 6MB）：2026-09-07 楷体（FandolKai）实测 6.75MB——
        # 楷书笔画弧线多，字形数据天然大于宋体（5.5MB），放宽仍为 san 上限。
        raise SystemExit('CJK subset 尺寸越界: %d bytes' % size)
    # 关键字形断言：cmap 必须含 中(4E2D) 与 A(41) —— 防空壳子集静默进入 rawfile
    from fontTools.ttLib import TTFont
    cm = TTFont(out).getBestCmap()
    if 0x4E2D not in cm or 0x41 not in cm:
        raise SystemExit('CJK subset 缺关键字形（4E2D/41）—— 子集化失败')
    if family:
        rewrite_font_name(out, family)
    print('  CJK 子集化 %s -> %s (%d bytes, %d chars)'
          % (os.path.basename(src), os.path.basename(out), size, len(cm)))
    return out


def rewrite_font_name(path, family):
    """重写 TTF name 表（ID1 family/ID2 subfamily/ID3 unique/ID4 full/ID6 postscript/
    ID16 typoFamily/ID17 typoSubFamily = family + Regular——引擎 wasm freetype
    face.Name 取 family（ID1/ID16），必须与 FONT_INFOS 注册行名一致，否则渲染槽
    匹配失败 → 整 run 空白（2026-09-05 真机实证，见 make_cjk_subset 注释）。
    幂等：name 已等于目标 → 不动。fontTools 4.63 实测 OK——新转换器替代方案备忘：
    otf2ttf 才能 CFF→glyf；fontTools 无 otf2ttf。"""
    from fontTools.ttLib import TTFont
    g = TTFont(path)
    nm = g['name']
    if nm.getDebugName(1) == family and nm.getDebugName(16) == family:
        return
    for recid, val in [(1, family), (2, 'Regular'), (3, family + ' Regular'),
                       (4, family), (6, family), (16, family), (17, 'Regular')]:
        nm.setName(val, recid, 3, 1, 0x409)      # Windows English
        nm.setName(val, recid, 3, 1, 0x804)      # Windows zh-CN 同值
    g.save(path)
    g2 = TTFont(path)
    assert g2['name'].getDebugName(1) == family, 'name rewrite 断言失败: %s' % family
    print('  name 重写 %s -> family=%s' % (os.path.basename(path), family))


# —— 字体缩略图精灵生成（2026-09-05 字族下拉终极修复，资源侧；非工控注入）——
# 官方 web 语义 CThumbnailLoader（ComboBoxFonts.js:98-120）XHR
#   sdkjs/common/Images/fonts_thumbnail_ea@<ratio>x.png.bin（官方 RLE alpha 蒙版
#   格式：12B 大端头 width/heightOne/count + 字节流—— 0x00,len(≤255)=透明 run，
#   其它值=像素（255-tmp, tmp alpha）；解码器 ComboBoxFonts.js:131-234）。
# 前置缺陷：资源缺失 → rawfileLoader 404 响应仍触发 XHR onload → 404 页字节被
#   当 RLE 头解码 → createImageData 巨值 → OOM → 菜单渲染崩（真机日志
#   Uncaught RangeError ...ComboBoxFonts.js:243）。弃用方案（已回滚，勿回退）：
#   覆盖 Common.Controllers.Desktop 桩——① 官方 Desktop.js:786 requirejs 模块
#   晚于 ascshim eval 会覆盖桩；② window.native 语义会改引擎 AscFonts.load 走
#   native 分支（sdk-all-min.js:49957）」；③ isActive=true 窗口触发桌面语义
#   启动链 → 应用启动崩溃（实测）。
# 本生成器：官方格式的「全透明格」精灵（列表显示字体名，预览格透明——后续可由
#   PIL 渲染字形升级，头/格尺寸已与官方一致）。幂等（产物存在即跳过）。断言：
#   12B 头正确 + 非空文件（防空壳）。
FONT_SPRITES_RATIOS = [(1.0, ''), (1.25, '@1.25x'), (1.5, '@1.5x'),
                       (1.75, '@1.75x'), (2.0, '@2x')]
FONT_SPRITE_COL_W = 300     # 与 ComboBoxFonts.js:53 iconWidth 一致
FONT_SPRITE_ROW_H = 28      # 与 Asc.FONT_THUMBNAIL_HEIGHT||28 一致


def make_fonts_sprites(count):
    """生成 5×2（ea/ascii）×ratio 精灵 → rawfile/onlyoffice/sdkjs/common/Images/。
    count = 普通字族数（FONT_INFOS 行数 == UI asc_onInitEditorFonts 收到的 n）。
    每个格子以**该字族对应字体文件**渲染「字族名样例」→ 官方 RLE alpha
    蒙版编码（0x00,len=透明 run；其余字节=alpha，解码 RGB=255-bt 黑字）。
    依赖 Pillow（pip install pillow；生成器缺时透明格降级+告警不阻断——
    但正式包要求含字形：缺失时 raise。全透明格=菜单项空白（实机已见）。
    每次覆盖重写（内容随字体源变——不做缓存；构建可复现）。"""
    import struct
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        raise SystemExit('make_fonts_sprites 需要 Pillow：pip install pillow（或设'
                         ' OHOS_*FONTS 未安装？）')
    d = os.path.join(SDK_DST, 'common', 'Images')
    os.makedirs(d, exist_ok=True)
    ok = 0
    for postfix in ('_ea', ''):   # zh/ja/ko 用 _ea，其余 ascii（组件按 Locale 选）
        for ratio, suffix in FONT_SPRITES_RATIOS:
            fn = 'fonts_thumbnail%s%s.png.bin' % (postfix, suffix)
            p = os.path.join(d, fn)
            w = int(FONT_SPRITE_COL_W * ratio)
            h = int(FONT_SPRITE_ROW_H * ratio)
            # —— 画布：count 行，每行一格（字族名样例渲染）——
            img = Image.new('RGBA', (w, h * count), (0, 0, 0, 0))
            dr = ImageDraw.Draw(img)
            fsize = int(20 * ratio)
            for i in range(count):
                # 尾部空白格（count = FONT_INFOS 行数 + 1）：留给用户自导入字体。
                # CFontInfo 的 thumbnail 参数 = __fonts_infos 行号（checkAllFonts 传 i），
                # 用户字体行追加在内置行之后必然越界——真机实测 UI getImage 越界抛异常，
                # 下拉列表渲染到该项即中断（字体"消失"）。用户字体统一指向这格空白
                # （30_open wrap 重建 CFont，见其 LSO_FONT_USER_KEEP 段）。
                if i >= len(FONT_INFOS):
                    break
                row = FONT_INFOS[i]
                # CFontInfo indexR → 字体文件。**系统字体**（SYSTEM_FONT_FILES，
                # indexR >= len(FONT_FILES)）构建机无源文件（设备 /system/fonts
                # 运行时直读）→ 缩略图用包内黑体 subset 近似渲染（列表名仍正确，
                # 字形样本近似——不影响引擎真实渲染，2026-09-07 系统字体桥）。
                # 真正的渲染预览问题在 v1 实验暴露过（用户指正），系统字体的
                # 缩略图真字形待字体源进构建机后升级（P3）。
                ff = FONT_FILES[row[1]] if row[1] < len(FONT_FILES) else 'HarmonyOS_Sans_SC.ttf'
                fname = ff
                # 子集字体（FONT_SUBSETS）优先用子集产物渲染——与引擎实际拿到的
                # 字形完全一致（宋体全量不入库，subset 一定存在）
                if ff in FONT_SUBSETS:
                    _sub = os.path.join(FONT_SRC_BY_FILE[ff], FONT_SUBSETS[ff][1])
                    if os.path.isfile(_sub):
                        fname = FONT_SUBSETS[ff][1]
                src = os.path.join(FONT_SRC_BY_FILE[ff], fname)
                try:
                    f = ImageFont.truetype(src, fsize)
                except OSError:
                    f = None
                # y 基线：格中部（28*ratio 高格）
                y = i * h + int(h * 0.06)
                if f is not None:
                    dr.text((int(10 * ratio), y), str(row[0]), font=f,
                            fill=(255, 0, 0, 255))
                else:
                    dr.text((int(10 * ratio), y), '?', font=ImageFont.load_default(),
                            fill=(255, 0, 0, 255))
            # —— RLE 编码（官方协议）——
            px = img.load()
            out = bytearray(struct.pack('>III', w, h, count))
            total = w * h * count
            i = 0
            while i < total:
                ci = i // (w * h)                # 当前格
                pi = i % (w * h)
                a = px[pi % w, ci * h + pi // w][3]
                if a == 0:
                    j = i
                    while j < total and j - i < 255:
                        cj = j // (w * h)
                        pj = j % (w * h)
                        if px[pj % w, cj * h + pj // w][3] != 0:
                            break
                        j += 1
                    out += bytes([0, j - i])
                    i = j
                else:
                    out.append(a)
                    i += 1
            with open(p, 'wb') as f2:
                f2.write(bytes(out))
            if os.path.getsize(p) < 4096:
                raise SystemExit('字体精灵生成异常（过小 %d）：%s'
                                 % (os.path.getsize(p), p))
            ok += 1
    if ok < 10:
        raise SystemExit('字体精灵文件数异常：%d（预期 10）' % ok)
    print('  精灵格渲染：每格 %d×%d，%d 字族，%d 文件（RLE off' % (w, h, count, ok))
    return ok


def make_font_selection_bin(fonts):
    """最小 g_fonts_selection_bin（CFontSelect v0 序列化，little-endian）
    ——与 POC 同契约（引擎服务器字体索引，在 AllFonts.js 里注入）
    2026-09-05 修复：m_lIndex 此前硬编码 0——候选名选中（GetFontIndex 名字正确）
    但返回对象的 m_lIndex=0，引擎取字面字节按 m_lIndex 查 → 全部命中第 0 个文件
    （LiberationSans-Regular.ttf）→ CJK 字形 notdef → 方块。实测证据：PROF_CHAIN
    GetFontFileWeb('宋体') path=simsun.ttf 但对 m_lIndex=0。官方语义：m_lIndex =
    该名字对应字体文件引擎下标（见 CFontSelectList 契约），必须与 __fonts_infos
    行的 regular 文件下标一致。"""
    import struct
    buf = struct.pack('<I', len(fonts))
    for name, idx in fonts:
        n = name.encode('utf-16-le')
        p = (name.lower().replace(' ', '') + '.ttf').encode('utf-16-le')
        buf += struct.pack('<I', len(n)) + n
        buf += struct.pack('<I', len(p)) + p
        buf += struct.pack('<I', idx)              # m_lIndex（字体文件引擎下标）
        buf += struct.pack('<I', 0)                # italic
        buf += struct.pack('<I', 0)                # bold
        buf += struct.pack('<I', 0)                # fixed
        buf += struct.pack('<I', 10) + b'\x00' * 10  # panose
        # 字体支持范围位图：全 1（声明全 Unicode 支持）。
        # 2026-09-05 中文渲染根因候选之一：此串行化表的 unicode ranges 硬编码 0
        # =「声明不支持任何字符」，选字/回退路径会把 CJK 双字踢掉（官方 CFontSelect 从
        # 字体 OS/2 读真实范围）。全 1 为保守宽化（引擎渲染以实测 cmap 为准）。
        buf += struct.pack('<IIII', 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)
        buf += struct.pack('<II', 0xFFFFFFFF, 0xFFFFFFFF)  # codepage ranges
        buf += struct.pack('<HH', 400, 0)          # weight, width
        buf += struct.pack('<HHHHHHHH', 0, 1, 0, 0, 0, 0, 0, 0)  # family/format/avg/asc/desc/line/xh/cap
    import base64
    return base64.b64encode(buf).decode('ascii')


def pre_xor_font(path):
    """SDK 假设服务器字体已 guidOdttf 预加密（前 32B XOR）；明文会被 decode 破坏"""
    try:
        with open(path, 'rb') as f:
            data = bytearray(f.read())
    except OSError:
        return False
    n = min(32, len(data))
    for i in range(n):
        data[i] ^= FONT_GUID_ODTTF[i % 16]
    with open(path, 'wb') as f:
        f.write(data)
    return True


def gen_allfonts(fonts_infos):
    """生成 sdkjs/common/AllFonts.js —— 引擎 CheckAllFonts 契约（POC 同方案）。
    注意：字体名必须 JSON 引号（此前 str() 生成裸 [Liberation Sans,...] 实机 SyntaxError）"""
    import json
    sel_b64 = make_font_selection_bin([(n[0], n[1]) for n in fonts_infos])
    return ('// AllFonts.js (generated by build_editors_ohos.py)\n'
            'var g_font_files = [];\n'
            'var g_font_infos = [\n' +
            ',\n'.join(json.dumps(info) for info in fonts_infos) +
            '\n];\n'
            'window["g_fonts_selection_bin"] = "%s";\n' % sel_b64 +
            # 内部行清单的派生注入（事实源 = UI_HIDDEN_FONT_ROWS，见 FONT_INFOS 后注释）：
            # 页面侧据此过滤用户下拉，故**不能**省——清单缺省 = 页面不过滤 = 方块行回来
            'window["__lso_font_hidden"] = %s;\n'
            % json.dumps(UI_HIDDEN_FONT_ROWS, ensure_ascii=False))

DELDIRS = ['ie', 'mobile', 'embed']
APP_MAIN = ['documenteditor', 'spreadsheeteditor', 'presentationeditor']

# —— smoke 页面脚本（自动验收诊断注入源；生成产物 = rawfile/onlyoffice/smoke/）——
SMOKE_SRC = os.path.join(ROOT, 'scripts', 'onlyoffice', 'smoke')
SMOKE_DST = os.path.join(DST, 'smoke')


def install_ai_plugin():
    """安装官方 AI 插件 → rawfile/onlyoffice/plugins/（web 语义 plugins.json server 链）。

    资产源（scripts/onlyoffice/plugins/，均为官方发布件，入库跟踪）：
      ai/ai.plugin   —— ONLYOFFICE/onlyoffice.github.io sdkjs-plugins/content/ai/deploy/
                        官方构建包（3.2.2，AGPL；702 文件 zip，含 vendor/ 与相对引用
                        ./../v1/plugins.js——本地化形态，无需改 HTML）。
                        zip 根即插件目录（config.json/index.html/...）。
      v1/            —— onlyoffice.github.io/sdkjs-plugins/v1/*.js/.css 官方 web 语义
                        插件框架（插件页 SDK：parent.postMessage 协议 ⇄ sdkjs
                        common/plugins.js 运行时）。
                        ★ 9-04/9-05 旧坑（勿回退）：不可用 desktop-apps/common/plugins/v1
                        （桌面壳版，无 iframe 窗口协议/获取路径不同）——曾致「AI 选项卡
                        出现但点按钮无反应」。
    rawfile/plugins.json：web 语义装配清单 {"pluginsData": [config.json 绝对 URL]}，
    由 web-apps Plugins.js:165 '../../../../plugins.json' 相对 editor main/index.html
    四层上跳读取（webapps/apps/<editor>/main/ → rawfile/onlyoffice/plugins.json）。
    幂等：plugins/ 先清空再装（内容驱动）。
    """
    ZIP = os.path.join(PLUGIN_SRC, 'ai', 'ai.plugin')
    V1 = os.path.join(PLUGIN_SRC, 'v1')
    if not os.path.isfile(ZIP):
        raise SystemExit('AI 插件发布包缺失：%s（官方 onlyoffice.github.io sdkjs-plugins/content/ai/deploy）' % ZIP)
    if not os.path.isdir(V1):
        raise SystemExit('v1 插件框架缺失：%s' % V1)
    if os.path.isdir(PLUGIN_DST):
        shutil.rmtree(PLUGIN_DST)
    os.makedirs(os.path.join(PLUGIN_DST, 'ai'), exist_ok=True)
    with zipfile.ZipFile(ZIP) as z:
        z.extractall(os.path.join(PLUGIN_DST, 'ai'))
    copy_tree(V1, os.path.join(PLUGIN_DST, 'v1'))
    # 插件清单（web 语义 server 链；绝对 URL 最稳——fetch 同源 localhost 无 CORS）
    manifest = {'pluginsData': ['http://localhost/onlyoffice/plugins/ai/config.json']}
    with open(os.path.join(DST, 'plugins.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2)
    n_ai = sum(len(fs) for _, _, fs in os.walk(os.path.join(PLUGIN_DST, 'ai')))
    v1 = os.path.join(PLUGIN_DST, 'v1')
    print('  AI 插件 → %s/ai (%d files) + v1 (%d files) + plugins.json'
          % (PLUGIN_DST, n_ai, sum(len(fs) for _, _, fs in os.walk(v1))))


def install_smoke():
    """拷贝 scripts/onlyoffice/smoke/ → rawfile/onlyoffice/smoke/（整目录替换）：
    *.js 页面诊断脚本（EditorPage smoke 注入）+ samples/ 验收样本（sample.*、
    m7-open-test.docx、demo-cn.*——2026-09-06 用户：smoke 文件单独目录；源就是
    scripts/onlyoffice/smoke/，勿在 rawfile 内手工放置 smoke 文件——会被 rmtree 覆盖）。
    仅拷 *.js 与 samples/（2026-09-07：*.py 验证桩/日志是本机工具件，不进包）。"""
    if not os.path.isdir(SMOKE_SRC):
        raise SystemExit('scripts/onlyoffice/smoke 不存在（smoke 诊断脚本源）')
    if os.path.isdir(SMOKE_DST):
        shutil.rmtree(SMOKE_DST)
    for entry in os.listdir(SMOKE_SRC):
        src = os.path.join(SMOKE_SRC, entry)
        dst = os.path.join(SMOKE_DST, entry)
        if entry == 'samples':
            copy_tree(src, dst)
        elif entry.endswith('.js'):
            os.makedirs(SMOKE_DST, exist_ok=True)
            shutil.copy2(src, dst)
        # 其它类型（*.py/*.log 等本机工具件）不进包
    n = sum(len(fs) for _, _, fs in os.walk(SMOKE_DST))
    print('  smoke 脚本 → %s (%d files)' % (SMOKE_DST, n))
    # 格式扩展样本存在性断言：缺失 = 回归 case 必失败，构建期拦下
    # （依据：docs/superpowers/specs/2026-09-11-file-format-expansion-design.md §9.1）
    for name in ('sample.doc', 'sample.xls', 'sample.ppt',
                 'sample.rtf', 'sample.txt', 'sample.csv',
                 # 含图样本（make_img_sample.py 生成）：判定 _offline_media 媒体供给
                 # 缺失的真实影响（丢不丢图），别删
                 'sample-img.pptx',
                 # 密文样本（ECMA-376 Agile 加密，口令 1234；msoffcrypto 从 sample.* 生成）：
                 # 验证打开链对密文文档的 x2t 解密通路（m7pwd 门控，见 smoke.ets）
                 'enc.docx', 'enc.xlsx', 'enc.pptx'):
        if not os.path.isfile(os.path.join(SMOKE_DST, 'samples', name)):
            raise SystemExit('smoke 样本缺失：samples/%s（格式扩展回归依赖）' % name)


def install_licenses():
    """随包许可证与声明文本 → rawfile/onlyoffice/licenses/{LICENSE,NOTICE}.txt。

    两源均在仓库根：
      LICENSE = AGPL v3 全文 + 官方附加条款（与 third_party/core/LICENSE 正文
        逐字一致，md5 7de9925b…）+ 本工程声明段（自有代码授权 + 修改版声明与
        修改起始日期）。取根文件而非子模块文件：附加条款 2 要求修改版携带
        修改声明与日期——声明随 LICENSE 走，一份文件满足「保留原条款」与
        「声明修改」两项，避免两处文本漂移。
      NOTICE = 上游归属、修改清单、随包字体/脚本库的版权与许可、对应源码获取
        方式（附加条款 1/3 的归属声明与源码可得性）。
    About 面板许可行链接 http://localhost/onlyoffice/licenses/LICENSE.txt →
    EditorPage 本地 serve（rawfile 根）；NOTICE 同源可访问（55_lic.js 弹层）。
    合规依据：官方附加条款 3(iii) 用户界面须能访问适用许可信息——文本随包+
    可访问链，作为本地资源不依赖外网。
    """
    dst_dir = os.path.join(DST, 'licenses')
    os.makedirs(dst_dir, exist_ok=True)
    for src_name, dst_name in (('LICENSE', 'LICENSE.txt'), ('NOTICE', 'NOTICE.txt')):
        src = os.path.join(ROOT, src_name)
        if not os.path.isfile(src):
            raise SystemExit('随包许可源缺失：%s' % src)
        shutil.copy2(src, os.path.join(dst_dir, dst_name))
        print('  %s → %s/%s (%d bytes)'
              % (src_name, dst_dir, dst_name,
                 os.path.getsize(os.path.join(dst_dir, dst_name))))


def write_font_rows():
    """内置字体行名清单 → rawfile/onlyoffice/fontrows.json。

    为什么单独出这份数据：引擎注册行名（FONT_INFOS 第 0 列）只在构建期知道，而
    ArkTS 导入侧要在用户选完文件的当下判断「这个家族名已被内置占用」——不导出
    就只能硬编码或漏检。含随包字体行与系统字体行。
    """
    out = os.path.join(DST, 'fontrows.json')
    names = [row[0] for row in FONT_INFOS]
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(names, f, ensure_ascii=False)
    print('fontrows.json: %d 行 → %s' % (len(names), out))


def patch_about_brand():
    """关于面板双品牌（2026-09-07 用户决策：**Pure Office 为主，ONLYOFFICE 为辅**）。

    用户具体指示（真机截图后）：官方大 logo（.asc-about-office :before 的
    logo_s.svg——图示內含超大「ONLYOFFICE」字样）**移除**——「上面放大的那行字才
    应该使用 Pure Office；大张旗鼓用 ONLYOFFICE 也不好」——顶部主视觉 = appName
    行「Pure Office」；「基于 ONLYOFFICE DesktopEditors（AGPL-3.0）为辅行文字
    保留（归属声明低调存在）。

    合规说明（写在此处供后续核对）：官方未商业授权时严格按 7(b) 保留 logo 可以，
    但用户明确选主品牌 = Pure Office、ONLYOFFICE 仅作 AGPL 归属声明——AGPL §11
    （trademark）不禁止改名/自品牌，前提是不得暗示 ONLYOFFICE 认可本产品；归属行
    + 保留的公司信息（名/地址/邮箱/官网）+ 官方 AGPL 条款文本满足源码许可声明的
    要求。Logo 替换/删除附带品牌商标使用判断，与本产品的开源许可义务分开。

    品牌化（patch 对象 = grunt 产物，可再生成；upstream 重建后本脚本自动
    重新生效——与 inject_ascshim 同模式）：
      1) 五个编辑器 LeftMenu.js About 构造 appName「文档编辑器」→「Pure Office」；
      2) About.js licensor 模板版本行下加归属行「基于 ONLYOFFICE
         DesktopEditors（AGPL-3.0）」，其中「AGPL-3.0」即许可全文链接（用户
         2026-09-10：删独占「许可信息：…」行，链接并入本行；修改版日期经用户
         决策不展示——官方附加条款 2 的日期声明由随包 LICENSE 中的说明文本承接；
         .asc-about-lic 12px 灰字，满足官方附加条款 3(i/ii/iii)）；其下再一行
         源码/声明入口（NOTICE，见 §「源码可用性行」）——同时满足 AGPL §6 的
         对应源码可得性在应用内可达；
      3) 五编辑器 app.css `.asc-about-office:before{content:url(logo_s.svg)}`
         → `content:''`（亮/暗主题两变体）——官方 logo 图示清除；
      4) licensor 公司信息表（公司名/地址/邮箱/电话/网址）→ class hidden
         （用户决策 2026-09-07「暂时先不放公司信息」）。
    附：模板 appName.toUpperCase() 去上转（否则显示「PURE OFFICE」——用户期望保形）。
    幂等：已替换（目标串不再存在）即跳过；应替换却没替换（0 命中）→ 非零退出
    （grunt 产物结构变化立即暴露，防静默空 patch）。
    """
    # 归属确认行 + 许可入口：满足官方附加条款 2（修改版显式声明+日期）与 3(i)(ii)（识别
    # ONLYOFFICE 为原始开发者 + 本版为修改版）；「原始开发者 Ascensio System SIA」由本行
    # 完成识别——官方附加条款原文另行随包（install_licenses）。
    # 2026-09-10 用户：删「许可信息：GNU AGPL v3.0」独占行，链接改挂本行「AGPL-3.0」
    # 文字（点击=55_lic.js 弹层渲染全文；纯文本仍是完整归属句，不点也能读懂）。
    # class="link" 供欢迎页复用其内置 `.link{color:var(--text-link)}`——版权行是
    # `--text-tertiary` 灰字，链接嵌在句中须显链接色；编辑器 About 侧由 BRAND_CSS
    # 的 `.about-dlg .asc-about-note a` 规则承担（官方 `.about-dlg a` 同染正文色）。
    LIC_URL = 'http://localhost/onlyoffice/licenses/LICENSE.txt'
    CREDIT = ('基于 ONLYOFFICE DesktopEditors（<a class="link" href="' + LIC_URL
              + '" target="_blank">AGPL-3.0</a>）')
    # 源码可用性行（AGPL §6：以客体形式分发须提供对应源码）：随包 NOTICE 写明
    # 完整源码获取地址与重建步骤。链接走与许可同一本地通道（55_lic.js 弹层），
    # 不依赖外网可达——审核/用户离线也能读到源码去向。
    NOTE_URL = 'http://localhost/onlyoffice/licenses/NOTICE.txt'
    # 「见」与链接之间用 &nbsp;：中文与拉丁词之间的普通空格在 HTML 渲染中会被
    # 压缩到近乎不可见（2026-09-12 真机截图呈「见NOTICE」紧贴）
    SOURCE_LINE = ('完整源码与第三方声明见&nbsp;<a class="link" href="' + NOTE_URL
                   + '" target="_blank">NOTICE</a>')
    APP_BRAND = "appName: 'Pure Office'"
    patched = 0

    # （1）appName → Pure Office（de/ss/pe/pdf/visio 五份 LeftMenu.js 均有 About 构造）
    for app in ('documenteditor', 'spreadsheeteditor', 'presentationeditor',
                'pdfeditor', 'visioeditor'):
        p = os.path.join(W3D, 'apps', app, 'main', 'app', 'view', 'LeftMenu.js')
        if not os.path.isfile(p):
            continue  # 官方可单独 grunt 某 app；缺失即该编辑器不在发行内，属正常
        with open(p, 'r', encoding='utf-8') as f:
            s = f.read()
        if APP_BRAND in s:
            continue  # 幂等重跑
        old = 'appName: this.txtEditor'
        if old not in s:
            raise SystemExit('About 品牌 patch 失败：%s 未找到 %r（grunt 产物结构变化？）' % (p, old))
        s = s.replace(old, APP_BRAND)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(s)
        patched += 1
        print('  about品牌: %s appName → Pure Office' % app)

    # （2）About.js 模板（licensor 版本行 + 辅行；appName 去上转）
    about_p = os.path.join(W3D, 'apps', 'common', 'main', 'lib', 'view', 'About.js')
    with open(about_p, 'r', encoding='utf-8') as f:
        s = f.read()
    n_upper = s.count('options.appName.toUpperCase()')
    if n_upper:
        if n_upper != 2:
            raise SystemExit('About 模板 toUpperCase 命中 %d != 2（licensor+licensee），结构变化?' % n_upper)
        s = s.replace('options.appName.toUpperCase()', 'options.appName')
        print('  about品牌: appName 去上转 ×%d' % n_upper)
    # appName 行 class → asc-about-brand（主视觉大字；样式规则由 (3) 统一 append）。
    # licensor（单空格）/licensee（双空格）行串不同，分别替换并计数。
    n_brand = 0
    for row in ("+ options.appName + '</label></td>',",
                "+ options.appName  + '</label></td>',"):
        old_row = ("'<td align=\"center\"><label class=\"asc-about-version\">' " + row)
        cnt = s.count(old_row)
        if cnt:
            s = s.replace(old_row,
                          "'<td align=\"center\"><label class=\"asc-about-brand\">' " + row)
            n_brand += cnt
    if n_brand:
        print('  about品牌: appName 行 → asc-about-brand ×%d' % n_brand)
    tag = 'id-about-licensor-version-name'
    new_line = ('\'<tr><td align="center"><label class="asc-about-lic asc-about-note">'
                + CREDIT + '</label></td></tr>\',')
    if new_line not in s:
        old_line = ('\'<td align="center"><label class="asc-about-version" id="' + tag + '">\''
                    ' + this.txtVersion + this.txtVersionNum + \'</label></td>\',')
        n = s.count(old_line)
        if n != 1:
            raise SystemExit('About 模板 licensor 版本行命中 %d != 1，结构变化?' % n)
        s = s.replace(old_line, old_line + '\n                ' + new_line)
        print('  about品牌: licensor 模板 + 归属/许可行')
    # 源码/声明行：紧随归属行（同款样式）；幂等与插入点断言同归属行策略
    src_line = ('\'<tr><td align="center"><label class="asc-about-lic asc-about-note">'
                + SOURCE_LINE + '</label></td></tr>\',')
    if src_line not in s:
        n = s.count(new_line)
        if n != 1:
            raise SystemExit('About 模板归属行命中 %d != 1，无法定位源码行插入点' % n)
        s = s.replace(new_line, new_line + '\n                ' + src_line)
        print('  about品牌: licensor 模板 + 源码/声明行')
    # （b2）licensor 公司信息表整体隐藏（用户决策 2026-09-07「暂时先不放公司信息」——
    #     官方公司名/地址/邮箱/电话/网址不再展示，仅保留主品牌/版本/归属/许可；
    #     官方附加条款未要求 UI 展示公司联系方式，版权声明保留在源码头与随包 LICENSE）。
    #     class 加 hidden（licensee 表同款，common css 内置 .hidden）
    info_old = ('\'<table id="id-about-licensor-info" cols="3" style="width: 100%;"'
                ' class="margin-bottom">\',')
    info_new = ('\'<table id="id-about-licensor-info" cols="3" style="width: 100%;"'
                ' class="hidden margin-bottom">\',')
    if info_old in s:
        s = s.replace(info_old, info_new)
        print('  about品牌: licensor 公司信息表 → hidden')
    elif info_new not in s:
        raise SystemExit('About 模板 licensor 信息表未找到（结构变化？）')
    # 幂等判定的权威信号在 About.js 上下文里（new_line in s）——(3) 段 app.css 循环
    # 会复用并覆写 s，底部判定不能再用裸 s（会拿最后一个 app.css 误判）
    about_has_new = new_line in s
    with open(about_p, 'w', encoding='utf-8') as f:
        f.write(s)

    # （3）五编辑器 app.css：官方 logo 图示（.asc-about-office:before content:url）
    #     清除——Logo 图示内含超大「ONLYOFFICE」字样（用户：「大张旗鼓用
    #     ONLYOFFICE 也不好；上面放大的那行字才应该显示 Pure Office」）；
    #     content:none 使伪元素不生成。亮/暗主题两变体各一张。
    #     同文件 append `.asc-about-brand`（(2) 指派的 appName 主视觉大字规则——
    #     官方产品 logo 撤下后它就是面板顶部唯一主视觉）。
    OLD_LOGO = "content:url('../../../../common/main/resources/img/about/logo_s.svg')"
    OLD_LOGO_D = "content:url('../../../../common/main/resources/img/about/logo-white_s.svg')"
    # 排版（2026-09-07 用户「排列太紧，之前 ONLYOFFICE 的多美观」）：主名顶部留白
    # margin 40px + 与版本行间距 10px；辅行/许可行 note 类块级行距——零 logo 后重排
    # 面板重心下移、行间通透（官方原版行间疏朗感来自 logo(45px)+20px 表距，已无 logo）
    # 逐条判存补写（各条在 css 里出现即视为已生效）——升级路径与幂等由它统一承担
    BRAND_CSS = [
        '.asc-about-brand{font:bold 24px Tahoma;letter-spacing:.02em;'
        'color:#444;color:var(--text-normal);user-select:text;'
        'margin:40px 0 10px}',
        '.asc-about-note{display:block;padding:4px 0;line-height:1.7}',
        # 归属行里的「AGPL-3.0」是许可全文入口（2026-09-10）——官方 `.about-dlg a`
        # 把面板内链接染成正文色（--text-normal），链接嵌在句子中间会完全看不出
        # 可点；这里恢复链接色（选择器比 `.about-dlg a` 更具体，不依赖书写顺序）
        '.about-dlg .asc-about-note a{color:var(--text-link)}',
    ]
    logos = 0
    for app in ('documenteditor', 'spreadsheeteditor', 'presentationeditor',
                'pdfeditor', 'visioeditor'):
        p = os.path.join(W3D, 'apps', app, 'main', 'resources', 'css', 'app.css')
        if not os.path.isfile(p):
            continue
        with open(p, 'r', encoding='utf-8') as f:
            s = f.read()
        n1 = s.count(OLD_LOGO)
        n2 = s.count(OLD_LOGO_D)
        rules = [r for r in BRAND_CSS if r not in s]
        if n1 == 0 and n2 == 0 and not rules:
            continue  # 幂等重跑：logo 与全部规则均已处理
        if n1 or n2:
            s = s.replace(OLD_LOGO, 'content:none').replace(OLD_LOGO_D, 'content:none')
        if rules:
            s = s.rstrip('\n') + '\n' + '\n'.join(rules) + '\n'
        with open(p, 'w', encoding='utf-8') as f:
            f.write(s)
        logos += n1 + n2
        print('  about品牌: %s css logo 图示清除 ×%d + about 样式规则%s'
              % (app, n1 + n2, '追加×%d' % len(rules) if rules else '已存在'))

    if patched == 0 and n_upper == 0 and n_brand == 0 and logos == 0:
        if about_has_new:
            print('  about品牌: 已全部生效（幂等重跑，跳过）')
        else:
            raise SystemExit('About 品牌 patch 无任何命中——请检查 grunt 产物完整性')

    # —— 欢迎页 AboutDialog 品牌化（2026-09-10 用户拍板方案 A：入口放欢迎页侧栏
    #    「关于」）——
    # 官方欢迎页自带整套 About：侧栏项 `<li class="menu-item hidden"><a action="about">`
    # （官方默认 hidden）+ AboutDialog（dlg-about，570 宽）+ 事件通路
    #   window.sdk.on("on_native_message", …, () => /app\:version/.test(e) &&
    #     $(".tool-menu a[action=about]").parent().removeClass("hidden"))
    # 官方壳（CEF/Electron）发 app:version 才显示；本壳未发 → 项恒 hidden（这是
    # 「关于入口不见」的根因——2026-09-10 调查，多 tab 与 ascshim 均未动过它）。
    # 补发 = ascshim 57_about.js（页面侧模拟壳事件）；本段只品牌化对话框产物：
    #   1) appname 行写死 Pure Office（事件 opts.appname 同值双保险）；
    #   2) 官方 logo 块（#idx-about-cut-logo 内 idx-logo-light/dark use 图示——
    #      同「官方 logo 图示內含超大 ONLYOFFICE 字样」）→ 内联 style display:none；
    #   3) 版本行去「商业版/社区版」前缀 label（strVersionCommunity 语义属官方
    #      订阅版；本壳 = AGPL 社区构建，label 不成立——版本值=version.json.ver
    #      （=AppScope/app.json5 的 versionName），由 57_about.js 发 app:version 注入）；
    #   4) 官网/站点行（ver-site，target=popup 无新标签页语义）→ 删除（用户
    #      2026-09-10：面板不留两处 AGPL 文案；承接合规入口见下条）；
    #   5) 版权行（ver-copyright ${t.rights}）→ CREDIT 归属行硬编码（事件不发
    #      rights，单一来源——同编辑器 About 的 CREDIT 常量；「AGPL-3.0」即许可
    #      全文链接，target=_blank + localhost LICENSE.txt → 55_lic.js 弹层拦截
    #      渲染，满足官方附加条款 3(iii)）。
    WELCOME = os.path.join(DST, 'index.html')
    wsteps = [
        ('<p id="idx-about-appname">${t.appname}</p>',
         '<p id="idx-about-appname">Pure Office</p>', 'appname'),
        ('<div id="idx-about-cut-logo" class="${t.logocls}">',
         '<div id="idx-about-cut-logo" class="${t.logocls}" style="display:none">', 'logo'),
        ('<p id="idx-about-version"><span l10n>${i}</span> ${t.version}</p>',
         '<p id="idx-about-version">${t.version}</p>', '版本行 label'),
        ('<div class="ver-copyright about-field">${t.rights}</div>',
         '<div class="ver-copyright about-field">' + CREDIT + '</div>', '版权行'),
    ]
    # 整行删除步（无「新串」，幂等/探测看下方判定）
    del_line = '<a class="ver-site link about-field" target="popup" href="${t.link}">${t.site}</a>'
    wpatched = 0
    if os.path.isfile(WELCOME):
        with open(WELCOME, 'r', encoding='utf-8') as f:
            s = f.read()
        for old, new, desc in wsteps:
            if old in s:  # 幂等：已替换（old 不在）即跳过
                n = s.count(old)
                s = s.replace(old, new)
                wpatched += n
                print('  about品牌: 欢迎页 %s ×%d' % (desc, n))
        # 版权行（CREDIT）之后补源码/声明行：必须独立判存——归属行替换是一次性的
        # （替换后官方源串不复存在），新加行若挂在上面那步里，已 patch 过的老产物
        # 重跑永远补不上（2026-09-12 真机踩到：编辑器 About 有源码行、欢迎页没有）。
        credit_div = '<div class="ver-copyright about-field">' + CREDIT + '</div>'
        src_div = '<div class="ver-copyright about-field">' + SOURCE_LINE + '</div>'
        if credit_div in s and src_div not in s:
            n = s.count(credit_div)
            s = s.replace(credit_div, credit_div + src_div)
            wpatched += n
            print('  about品牌: 欢迎页 源码/声明行 ×%d' % n)
        if del_line in s:
            n = s.count(del_line)
            s = s.replace(del_line, '')
            wpatched += n
            print('  about品牌: 欢迎页 删官网行 ×%d' % n)
        # viewport meta 注入：loginpage 是桌面起始页，官方 HTML 无 viewport meta——
        # 手机等移动形态的 WebView 按 980px 默认虚拟视口渲染再整体缩到组件宽度，
        # 欢迎页（桌面排版）被缩小显示（手机上约为编辑器页的一半——编辑器页有官方
        # viewport meta 按 device-width 1:1 渲染，2026-09-19 phone 真机实证；PC/2in1
        # 不解析 meta 故无此问题）。meta 写法对齐编辑器 main/index.html 官方行。
        VP_META = ('<meta name="viewport" content="width=device-width, '
                   'initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, '
                   'user-scalable=no">')
        if 'name="viewport"' not in s:
            anchor = '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">'
            if anchor not in s:
                raise SystemExit('欢迎页 viewport 注入未命中锚点（Content-Type meta）'
                                 '——请检查 loginpage 结构')
            s = s.replace(anchor, anchor + VP_META, 1)
            wpatched += 1
            print('  welcome: viewport meta 注入')
        if wpatched:
            with open(WELCOME, 'w', encoding='utf-8') as f:
                f.write(s)
        # 结构性探测：各步应全部「已替换 or 已生效」，否则 loginpage 结构变了
        missing = ([d for (o, nw, d) in wsteps if o not in s and nw not in s]
                   + ([] if del_line not in s else ['官网行(删)']))
        if missing:
            raise SystemExit('欢迎页 About 品牌 patch 未命中: %s ——请检查 loginpage 结构' % ','.join(missing))
    else:
        print('  !! 欢迎页 index.html 不存在——跳过 welcome About 品牌化（loginpage 未部署）')

    # —— 新建文档入口裁为 docx/xlsx/pptx（2026-09-10 用户：「主页入口中，只保留
    #    docx/xlsx/pptx，PDF 入口去掉」）——
    # 官方 DocumentCreationGrid 的 documentTypes 数组含第 4 项 PDF 表单卡（id:"form"），
    # 点击 create:new id=form——本壳 EditorPage.onTabCommand 无 form 分支（会落到 docx
    # 默认），入口本身就是错的，直接删卡。删整项（连同相邻逗号，保持数组语法）。
    PDF_CARD = ('{id:"form",title:utils.Lang.newForm,langKey:"newForm",'
                'formatLabel:{value:"PDF",gradientColorStart:"#F36653",'
                'gradientColorEnd:"#D2402D",bgColorWinXP:"#e54d39"},icon:"#pdf-big"}')
    if os.path.isfile(WELCOME):
        with open(WELCOME, 'r', encoding='utf-8') as f:
            s = f.read()
        if PDF_CARD in s:
            # 官方把 PDF 卡放数组末项 → 前导逗号必在；若哪天它不在末项，下面的探测
            # 会报错（不静默留下语法错的数组）
            dead = ',' + PDF_CARD if ',' + PDF_CARD in s else PDF_CARD
            s = s.replace(dead, '')
            with open(WELCOME, 'w', encoding='utf-8') as f:
                f.write(s)
            print('  welcome: 删除 PDF 新建入口卡')
        if PDF_CARD in s:
            raise SystemExit('欢迎页 PDF 入口卡未删除——新建入口结构可能已变，'
                             '请检查 loginpage 的 documentTypes 数组')


def gen_version_json():
    """生成 rawfile/onlyoffice/version.json —— 资源内容哈希（构建期 cache-bust 版本号）。

    哈希范围：rawfile/onlyoffice/ 下全部文件（排除自身；含 ascshim 与 webapps 内容）。
    EditorPage 启动读取，编辑页/欢迎页 URL ?v=N 引用它替代原 VERSION_BUMP 手工递增
    （阶段3，2026-09-05）。
    """
    h = hashlib.sha1()
    root = DST
    entries = sorted(
        os.path.relpath(os.path.join(r, f), root)
        for r, _, fs in os.walk(root) for f in fs
        if os.path.join(r, f) != os.path.join(DST, 'version.json')
    )
    for rel in entries:
        h.update(rel.encode('utf-8'))
        with open(os.path.join(root, rel), 'rb') as f:
            h.update(f.read())
    v = h.hexdigest()[:12]
    with open(os.path.join(DST, 'version.json'), 'w', encoding='utf-8') as f:
        # ver=产品版本（About 面板展示，PRODUCT_VERSION 常量）；v=资源哈希（URL 指纹）
        json.dump({'v': v, 'ver': PRODUCT_VERSION}, f)
    return v


def copy_tree(src, dst):
    shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True)


def inject_ascshim(html_path):
    """在 <head> 注入 ascshim.js（相对路径：apps/<app>/main/ → ../../../../ascshim.js）"""
    return inject_script_src(html_path, '../../../../ascshim.js')


def inject_ohos_boot(html_path):
    """在 <head> 注入 ohos/boot.js（宿主装配域启动链）。与 ascshim 无加载顺序
    耦合（boot 的启动调度是 setTimeout 轮询，等的是编辑器 app 对象而非 ascshim
    产物）；注入行位置在 ascshim 之前（两者都插在 <head> 首位，后插者在前）"""
    return inject_script_src(html_path, '../../../../ohos/boot.js')


def inject_script_src(html_path, src_rel):
    """在 <head> 后注入 <script src=...>（幂等；判据=目标 src 自身，多目标共存）"""
    with open(html_path, encoding='utf-8') as f:
        content = f.read()
    if src_rel in content:
        return False
    marker = '<head>'
    inject = '<script src="%s"></script>\n' % src_rel
    content = content.replace(marker, marker + '\n' + inject, 1)
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(content)
    return True


def main():
    # 注：原 --no-copy-src 假旗标已删除（2026-09-05 审查：解析后从未被引用，行为与默认
    # 完全相同）——"跳过上游重建、只装配"的合法入口是 desktop/grunt-build.sh --no-upstream。
    if not os.path.isdir(SRC):
        raise SystemExit('web-apps deploy 不存在：先运行 grunt（scripts/onlyoffice/desktop/grunt-build.sh）')

    # 1. 先清理 rawfile 旧 webapps（POC 版）
    if os.path.isdir(W3D):
        shutil.rmtree(W3D)
    os.makedirs(W3D, exist_ok=True)

    print('复制 web-apps 官方产物 → %s ...' % W3D)
    copy_tree(SRC, W3D)

    # 1.5 sdkjs deploy（--desktop 构建，含 Local/*.js 保存链）→ rawfile/onlyoffice/sdkjs
    if os.path.isdir(SDK_DST):
        shutil.rmtree(SDK_DST)
    copy_tree(SDK_SRC, SDK_DST)
    print('复制 sdkjs deploy → %s' % SDK_DST)

    # 2. 删除非桌面子变体（官方同）
    for root, dirs, _ in os.walk(W3D):
        for d in dirs:
            if d in DELDIRS:
                p = os.path.join(root, d)
                shutil.rmtree(p, ignore_errors=True)
                print('  删除 ' + os.path.relpath(p, W3D))

    # —— 2.5 裁剪：内置帮助手册（2026-09-09 用户决策：HAP 1GB 首因）——
    #    apps 五编辑器 + common 的 main/resources/help/ 合计 596M（HAP 1016M 的
    #    最大单体；每语言一份 HTML+截图手册，语言 = de/en/es/fr/it/pt/ru/sr-Latn/tr）。
    #    ① 无中文手册——官方从未输出 zh 版（五编辑器 help 目录均无 zh），「只留
    #       中文」不可行；② UI 无任何帮助入口——2026-09-05 已按官方开关关闭：
    #       customization.help:false（Main.js:1759 canHelp=help!==false → 文件菜单
    #       「帮助」隐藏）、feedback:false/suggestFeature:false（LeftMenu.js:117
    #       feedback.url 非空才渲染；文件菜单同类）；③ 官方桌面的帮助按钮可用性
    #       检查（Desktop.js:337 _checkHelpAvailable）靠 fetch
    #       resources/help/<lang>/Contents.json——目录不存在 → 404 → helpUrl 空 →
    #       按钮天然不显示，**不会出现「入口在、内容空」的坏态**。
    #    裁剪=装配时删除（本链可重放；勿手删 rawfile——生成产物，下轮装配覆盖还原）。
    #    未来若要恢复：官方无 zh 手册，须自产 zh 目录放回 SRC 同路径并从本段排除。
    for root, dirs, _ in os.walk(W3D):
        for d in dirs:
            if d == 'help' and root.endswith(os.path.join('main', 'resources')):
                p = os.path.join(root, d)
                shutil.rmtree(p, ignore_errors=True)
                print('  裁剪 help ' + os.path.relpath(p, W3D))

    # 3. api/documents index.html.desktop → index.html（官方 build_js.py:68）
    #    grunt 构建产物不含 .desktop——从源码树取
    doct_orig_src = os.path.join(ROOT, 'third_party', 'web-apps', 'apps', 'api', 'documents', 'index.html.desktop')
    doct_orig = os.path.join(W3D, 'apps', 'api', 'documents', 'index.html.desktop')
    doct_dst = os.path.join(W3D, 'apps', 'api', 'documents', 'index.html')
    if not os.path.isfile(doct_orig) and os.path.isfile(doct_orig_src):
        shutil.copy2(doct_orig_src, doct_orig)
    if os.path.isfile(doct_orig) and not os.path.isfile(doct_dst):
        shutil.copy2(doct_orig, doct_dst)
        print('  api/documents/index.html.desktop → index.html')

    # 4. 各 app main/index.html 注入 ascshim（若还没注入）
    injected = 0
    for app in APP_MAIN:
        p = os.path.join(W3D, 'apps', app, 'main', 'index.html')
        if os.path.isfile(p) and inject_ascshim(p):
            injected += 1
            print('  注入 ascshim.js → apps/%s/main/index.html' % app)
    # 4.1 ohos 模块（宿主装配域定制 JS，源=scripts/onlyoffice/ohos/）→
    #     rawfile/onlyoffice/ohos/；编辑器 main/index.html 注入 boot.js
    #    （与 ascshim 无顺序耦合：boot 等的是编辑器 app 对象，轮询调度）
    OHOS_SRC = os.path.join(ROOT, 'scripts', 'onlyoffice', 'ohos')
    OHOS_DST = os.path.join(DST, 'ohos')
    if os.path.isdir(OHOS_SRC):
        if os.path.isdir(OHOS_DST):
            shutil.rmtree(OHOS_DST)
        copy_tree(OHOS_SRC, OHOS_DST)
        boots = [f for f in os.listdir(OHOS_DST) if f.endswith('.js')]
        assert 'boot.js' in boots, 'ohos 模块缺 boot.js（scripts/onlyoffice/ohos/）'
        for app in APP_MAIN:
            p = os.path.join(W3D, 'apps', app, 'main', 'index.html')
            if os.path.isfile(p) and inject_ohos_boot(p):
                print('  注入 ohos/boot.js → apps/%s/main/index.html' % app)
        print('  ohos 模块 %d 个 js → %s' % (len(boots), OHOS_DST))
    # 4.5 编辑器页 viewport meta 补注入（幂等）：官方三个 main/index.html 源码均带
    #     viewport meta，但 deploy 产物部分页面缺失（实测 presentationeditor 被剥）——
    #     缺失时手机 WebView 按 980px 默认虚拟视口渲染，与触摸输入按 devicePixelRatio
    #     的坐标换算不一致，滚动条等窄目标的触摸命中系统性错位。meta 写法同欢迎页注入。
    VP_META = ('<meta name="viewport" content="width=device-width, '
               'initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, '
               'user-scalable=no">')
    VP_ANCHOR = re.compile(r'<meta http-equiv="Content-Type"[^>]*/?>')
    for app in APP_MAIN:
        p = os.path.join(W3D, 'apps', app, 'main', 'index.html')
        if not os.path.isfile(p):
            continue
        with open(p, encoding='utf-8') as f:
            s = f.read()
        if 'name="viewport"' in s:
            continue
        m = VP_ANCHOR.search(s)
        if not m:
            raise SystemExit('apps/%s/main/index.html viewport 补注入未命中锚点'
                             '（Content-Type meta）——请检查页面结构' % app)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(s[:m.end()] + VP_META + s[m.end():])
        print('  viewport meta 补注入 → apps/%s/main/index.html' % app)
    # api/documents 外壳页（编辑 iframe 宿主）
    p = os.path.join(W3D, 'apps', 'api', 'documents', 'index.html')
    if os.path.isfile(p) and inject_ascshim(p):
        injected += 1
        print('  注入 ascshim.js → apps/api/documents/index.html')
    print('  injected %d pages' % injected)
    # 断言：3 编辑器 + api 壳共 4 页（deploy 产物残缺/过旧时立即失败，不产坏包 ——
    # 2026-09-05 审查补）
    if injected != 4:
        raise SystemExit('ascshim 注入页数 %d != 4：web-apps deploy 产物不完整或已注入过旧版本'
                         % injected)
    # ascshim.js 本体必须存在（build 链引用它但由 make_ascshim.py 生成——缺失即链脱节）
    if not os.path.isfile(os.path.join(DST, 'ascshim.js')):
        raise SystemExit('rawfile/onlyoffice/ascshim.js 缺失：先运行 scripts/onlyoffice/desktop/make_ascshim.py')

    # 5. 字体（AllFonts.js + fonts/ 预加密）→ rawfile/onlyoffice/
    #    AllFonts.js 每次重生成（与 FONT_INFOS 契约（make_ascshim import 同源）——
    #    以前"已存在即跳过"会静默采用官方 deploy 自带版本，内容不确定 —— 2026-09-05 审查修）
    allfonts_dst = os.path.join(SDK_DST, 'common', 'AllFonts.js')
    os.makedirs(os.path.dirname(allfonts_dst), exist_ok=True)
    with open(allfonts_dst, 'w', encoding='utf-8') as f:
        f.write(gen_allfonts(FONT_INFOS))
    print('  生成 sdkjs/common/AllFonts.js (%d bytes)' % os.path.getsize(allfonts_dst))

    # 字体拷贝：FONT_FILES 全部就位才成功（缺失/预加密失败即非零退出 —— 2026-09-05 审查补）
    # 源目录按文件取（Liberation→系统目录；CJK→templates_src/fonts，其中
    # FONT_SUBSETS 登记的两族额外过子集化——方案 B，见函数块注释）
    # 先清空再装：复用 dest 时陈旧文件（旧版本残留/手放非 ttf）会进 version.json
    # 哈希导致 **产物 hash 随历史残留漂移**（2026-09-05 演练实证：rm 前后构建
    # version hash 不一致——当前差异源为历史残留，清空后消除）。幂等依据=内容，
    # 不依赖 dest 初始状态。
    if os.path.isdir(FONT_DST):
        shutil.rmtree(FONT_DST)
    os.makedirs(FONT_DST, exist_ok=True)
    fonts_ok = 0
    for fn in FONT_FILES:
        if fn in FONT_SUBSETS:
            _full, _sub, _fam = FONT_SUBSETS[fn]
            src_font = make_cjk_subset(os.path.join(FONT_SRC_BY_FILE[fn], _full),
                                       os.path.join(FONT_SRC_BY_FILE[fn], _sub),
                                       family=_fam)
        else:
            src_font = os.path.join(FONT_SRC_BY_FILE[fn], fn)
        dst_font = os.path.join(FONT_DST, fn)
        if not os.path.isfile(src_font):
            raise SystemExit('字体缺失：%s（FONT_SRC_BY_FILE 未覆盖或路径失效）'
                             % src_font)
        shutil.copy2(src_font, dst_font)
        if not pre_xor_font(dst_font):
            raise SystemExit('字体预加密失败：%s' % fn)
        fonts_ok += 1
    print('  字体 → %s (%d/%d files)' % (FONT_DST, fonts_ok, len(FONT_FILES)))

    # 5.5 字体缩略图精灵（官方 web 语义 CThumbnailLoader 消费——字族下拉真源，
    #     详见 make_fonts_sprites 注释；缺失=404 字节当 RLE 头→createImageData
    #     OOM→菜单渲染崩，真机 ComboBoxFonts.js:243 实证）
    # +1 = 尾部空白格（用户自导入字体的缩略图槽位，见 make_fonts_sprites 内注释）
    n_spr = make_fonts_sprites(len(FONT_INFOS) + 1)
    print('  字体精灵 → sdkjs/common/Images (%d files)' % n_spr)

    # 6. 欢迎页 loginpage → rawfile/onlyoffice/index.html
    if os.path.isfile(LOGIN):
        dst = os.path.join(DST, 'index.html')
        shutil.copy2(LOGIN, dst)
        inject_script_src(dst, 'ascshim.js')
        print('  loginpage → %s (%d bytes)' % (dst, os.path.getsize(dst)))
    else:
        print('  !! loginpage 不存在：先运行 desktop-apps 的 grunt build')
        raise SystemExit('loginpage 未构建')

    # 7. smoke 诊断脚本（scripts/onlyoffice/smoke → rawfile/onlyoffice/smoke/）
    install_smoke()

    # 7.5 官方 AI 插件（web 语义 plugins.json server 链；资产入库 scripts/onlyoffice/plugins/）
    install_ai_plugin()

    # 7.55 随包许可证（AGPL 全文+官方附款 → licenses/；About「许可信息」链接指向）
    install_licenses()

    # 7.56 内置字体行名清单（用户导入字体的重名检查数据源；common/userFonts.ets 读）
    write_font_rows()

    # 7.6 【已源码化，2026-09-21 fork 化阶段 1】关于面板双品牌 + 欢迎页品牌/viewport/
    #     PDF 卡——全部迁入 web-apps fork（About.js/LeftMenu×5/about.less）与
    #     desktop-apps fork（panelabout 模板/panelrecent PDF 卡/index.html viewport），
    #     patch_about_brand() 不再调用（函数体留档，阶段 4 清理后处理段时统一删除）

    # 8. 版本号 version.json（资源内容哈希 → 编辑页 ?v=）
    v = gen_version_json()
    print('  version.json v=%s' % v)

    print('完成。')


if __name__ == '__main__':
    main()
