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
# R/I/B/BI 共用 regular，加粗/倾斜由引擎模拟——与 Symbol/Wingdings 全下标 0 同约定）
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
              'HarmonyOS_Sans_SC.ttf', 'NotoSerifCJK-SC.ttf']
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

# 子集映射：final 名（FONT_FILES/rawfile fonts/ 里的名字）→ (全量源文件, 子集产物,
# 注册面名——渲染槽 name 匹配用；CJK 族注册行名须一致。宋体=SimSun（引擎把
# '宋体' 归一为 'SimSun'），黑体=None（内部名已=注册行名 'HarmonyOS Sans SC'）。
# 子集产物入库（git）：宋体全量 31.5MB 太大不适于库；subset 缺失时可从全量源重建
# （otf2ttf 命令见上注释；黑体全量在库、subset 为构建中间产物不入库）。
FONT_SUBSETS = {
    'HarmonyOS_Sans_SC.ttf': ('HarmonyOS_Sans_SC.ttf', 'HarmonyOS_Sans_SC.subset.ttf', None),
    'NotoSerifCJK-SC.ttf': ('NotoSerifCJK-SC.ttf', 'NotoSerifCJK-SC.subset.ttf', 'SimSun'),
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
    ["Symbol", 0, 0, 0, 0, 0, 0, 0, 0],
    ["Wingdings", 0, 0, 0, 0, 0, 0, 0, 0],
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
]

# —— 字符范围回退表（引擎 libfont/character.js CFontByCharacter.init 消费的第三张
# 注入表 window["__fonts_ranges"]，格式 [start, end, infoRowIndex, ...] 展平三元组；
# 语义：Unicode [start, end] 中字符若在文档字体中缺字形，回退到
# FONT_INFOS[infoRowIndex][0] 字族 —— 2026-09-05 中文方块最后根因：
# 此前只注入 __fonts_files/__fonts_infos，缺这张表 → Ranges 空 → 任何 CJK 字符
# 回退失败 → 全部渲染为方块（引擎源代码 libfont/character.js:74 init 直接 return）。
# infoRowIndex 一律取 FONT_INFOS 中「宋体」行（=13 行号；行号是 FONT_INFOS 数组
# 下标，恰与真宋体文件下标 13 一致——回退到宋体=中文常用字回退到衬线，同官方
# Windows 语义；勿把行号与 indexR 混为一谈）：
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
    if not (100_000 < size < 6_000_000):
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
                row = FONT_INFOS[i]
                ff = FONT_FILES[row[1]]          # CFontInfo indexR → 字体文件
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
            'window["g_fonts_selection_bin"] = "%s";\n' % sel_b64)

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
    scripts/onlyoffice/smoke/，勿在 rawfile 内手工放置 smoke 文件——会被 rmtree 覆盖）。"""
    if not os.path.isdir(SMOKE_SRC):
        raise SystemExit('scripts/onlyoffice/smoke 不存在（smoke 诊断脚本源）')
    if os.path.isdir(SMOKE_DST):
        shutil.rmtree(SMOKE_DST)
    copy_tree(SMOKE_SRC, SMOKE_DST)
    n = sum(len(fs) for _, _, fs in os.walk(SMOKE_DST))
    print('  smoke 脚本 → %s (%d files)' % (SMOKE_DST, n))


def install_licenses():
    """随包许可证文本 → rawfile/onlyoffice/licenses/LICENSE.txt。

    内容 = third_party/core/LICENSE（AGPL v3 全文 + 官方附加条款——四个 submodule
    LICENSE 内容相同，md5 均为 7de9925b…（2026-09-07 校验））。
    About 面板「许可信息」链接 http://localhost/onlyoffice/licenses/LICENSE.txt →
    EditorPage 本地 serve（rawfile 根）。
    合规依据：官方附加条款 3(iii) 用户界面须能访问适用许可信息——AGPL 全文随包+
    可访问链;若某天打开的不是本地 URL 而是外部域名，许可证文本作为本地资源不依赖外网。
    """
    src = os.path.join(ROOT, 'third_party', 'core', 'LICENSE')
    if not os.path.isfile(src):
        raise SystemExit('随包许可证源缺失：%s' % src)
    dst_dir = os.path.join(DST, 'licenses')
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copy2(src, os.path.join(dst_dir, 'LICENSE.txt'))
    print('  许可证文本 → %s/LICENSE.txt (%d bytes)'
          % (dst_dir, os.path.getsize(os.path.join(dst_dir, 'LICENSE.txt'))))


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
      2) About.js licensor 模板版本行下加兼容/归属行「基于 ONLYOFFICE
         DesktopEditors（AGPL-3.0）」（用户定稿；修改版日期经用户决策不展示——
         官方附加条款 2 的日期声明由随包 LICENSE 中的说明文本承接）+ 许可链接行
         （.asc-about-lic 12px 灰字；满足官方附加条款 3(i/ii/iii)）；
      3) 五编辑器 app.css `.asc-about-office:before{content:url(logo_s.svg)}`
         → `content:''`（亮/暗主题两变体）——官方 logo 图示清除；
      4) licensor 公司信息表（公司名/地址/邮箱/电话/网址）→ class hidden
         （用户决策 2026-09-07「暂时先不放公司信息」）。
    附：模板 appName.toUpperCase() 去上转（否则显示「PURE OFFICE」——用户期望保形）。
    幂等：已替换（目标串不再存在）即跳过；应替换却没替换（0 命中）→ 非零退出
    （grunt 产物结构变化立即暴露，防静默空 patch）。
    """
    # 归属确认行：满足官方附加条款 2（修改版显式声明+日期）与 3(i)(ii)（识别 ONLYOFFICE
    # 为原始开发者 + 本版为修改版）；「原始开发者 Ascensio System SIA」由同一行
    # 「基于 ONLYOFFICE DesktopEditors（AGPL-3.0）」完成识别——官方附加条款原文另行
    # 随包（install_licenses）
    CREDIT = '基于 ONLYOFFICE DesktopEditors（AGPL-3.0）'
    LIC_URL = 'http://localhost/onlyoffice/licenses/LICENSE.txt'
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
    lic_line = ('\'<tr><td align="center"><label class="asc-about-lic asc-about-note">'
                '<a href="' + LIC_URL + '" target="_blank">许可信息：GNU AGPL v3.0'
                '（点击查看全文）</a></label></td></tr>\',')
    if new_line not in s:
        old_line = ('\'<td align="center"><label class="asc-about-version" id="' + tag + '">\''
                    ' + this.txtVersion + this.txtVersionNum + \'</label></td>\',')
        n = s.count(old_line)
        if n != 1:
            raise SystemExit('About 模板 licensor 版本行命中 %d != 1，结构变化?' % n)
        s = s.replace(old_line, old_line + '\n                ' + new_line + '\n                ' + lic_line)
        print('  about品牌: licensor 模板 + 辅行（%s） + 许可链接' % CREDIT)
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
    BRAND_CSS = ('.asc-about-brand{font:bold 24px Tahoma;letter-spacing:.02em;'
                 'color:#444;color:var(--text-normal);user-select:text;'
                 'margin:40px 0 10px}'
                 '.asc-about-note{display:block;padding:4px 0;line-height:1.7}')
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
        if n1 == 0 and n2 == 0 and '.asc-about-brand{' in s:
            continue  # 幂等重跑：logo 与规则均已处理
        if n1 or n2:
            s = s.replace(OLD_LOGO, 'content:none').replace(OLD_LOGO_D, 'content:none')
        if '.asc-about-brand{' not in s:
            s = s.rstrip('\n') + '\n' + BRAND_CSS + '\n'
        with open(p, 'w', encoding='utf-8') as f:
            f.write(s)
        logos += n1 + n2
        print('  about品牌: %s css logo 图示清除 ×%d + asc-about-brand 规则%s'
              % (app, n1 + n2, '追加' if n1 or n2 else '已存在'))

    if patched == 0 and n_upper == 0 and n_brand == 0 and logos == 0 and new_line in s:
        print('  about品牌: 已全部生效（幂等重跑，跳过）')
    elif patched == 0 and n_upper == 0 and n_brand == 0 and logos == 0 and new_line not in s:
        raise SystemExit('About 品牌 patch 无任何命中——请检查 grunt 产物完整性')


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
        json.dump({'v': v}, f)
    return v


def copy_tree(src, dst):
    shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True)


def inject_ascshim(html_path):
    """在 <head> 注入 ascshim.js（相对路径：apps/<app>/main/ → ../../../../ascshim.js）"""
    return inject_script_src(html_path, '../../../../ascshim.js')


def inject_script_src(html_path, src_rel):
    """在 <head> 后注入 <script src=...>（幂等）"""
    with open(html_path, encoding='utf-8') as f:
        content = f.read()
    if 'ascshim.js' in content:
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
    n_spr = make_fonts_sprites(len(FONT_INFOS))
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

    # 7.6 关于面板双品牌（Pure Office 主 + ONLYOFFICE 辅行 + 公司信息隐藏 + 许可入口；
    #     须在 gen_version_json 前——patch 内容算进资源哈希，编排内无自愈版本号漂移）
    patch_about_brand()

    # 8. 版本号 version.json（资源内容哈希 → 编辑页 ?v=）
    v = gen_version_json()
    print('  version.json v=%s' % v)

    print('完成。')


if __name__ == '__main__':
    main()
