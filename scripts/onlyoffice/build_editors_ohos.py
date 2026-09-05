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

== 注 ==
  AI 插件功能已按期撤回（2026-09-05 用户决策：专注基础功能）——plugins.json 接线、
  ai-mock、AI provider 预配置、AI 探针均撤除；基础构建不含任何插件资产。
  后续若要启用 AI：本次改动的 git 历史 + AI 插件来源说明（ONLYOFFICE/onlyoffice.github.io
  → sdkjs-plugins/content/ai，版本 3.2.2 AGPL；插件框架 sdkjs-plugins/v1/）可恢复。
"""
import os
import hashlib
import json
import shutil
import argparse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'third_party', 'web-apps', 'deploy', 'web-apps')
SDK_SRC = os.path.join(ROOT, 'third_party', 'sdkjs', 'deploy', 'sdkjs')
DST = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice')
W3D = os.path.join(DST, 'webapps')
SDK_DST = os.path.join(DST, 'sdkjs')
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
# 下标 12 = HarmonyOS_Sans_SC.ttf（无独立 Bold/Italic 文件：R/I/B/BI 共用 regular，
# 加粗/倾斜由引擎模拟——与 Symbol/Wingdings 全下标 0 同约定）
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
              'HarmonyOS_Sans_SC.ttf']
# 字体文件来源目录：Liberation → SYSTEM_FONTS_DIR；CJK → templates_src/fonts
# （CJK 源为 HarmonyOS SDK previewer 的 HarmonyOS_Sans_SC.ttf（可变字体），
# 本产物为 varLib.instancer 实例化的**静态 glyf TTF**（templates_src/fonts/）。
# 踩坑记录（2026-09-05，勿回退）：
#   1. VF 原文件（含 fvar/gvar）→ 引擎渲染管线崩溃（白屏/1 页空）；
#   2. Noto CFF（.otf）→ wasm libfont（精简 freetype）FT_Open_Face 失败
#      （m_pFaceInfo=null）——只支持 glyf TrueType。
# 复现（在构建机，需 fontTools + 字体源）：
#   python3 -c "
# from fontTools.ttLib import TTFont
# from fontTools.varLib.instancer import instantiateVariableFont
# f = TTFont('$CJK_FONTS_DIR/HarmonyOS_Sans_SC.ttf')
# instantiateVariableFont(f, {})
# for t in ('fvar','gvar','STAT','avar','cvar','MVAR','HVAR','VVAR'):
#     t in f and del f[t]
# f.save('scripts/onlyoffice/templates_src/fonts/HarmonyOS_Sans_SC.ttf')"
FONT_SRC_BY_FILE = {fn: SYSTEM_FONTS_DIR for fn in FONT_FILES[:12]}
FONT_SRC_BY_FILE['HarmonyOS_Sans_SC.ttf'] = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts')

# 字体注册表（引擎 Externals.js checkAllFonts 契约）
# 中文字族：文档字体名（微软雅黑/宋体等）与 HarmonyOS Sans SC 同下标 12——
# 引擎按名字行匹配到即可从同一文件取字形；避免「未命中名→fallback Liberation Sans
# → 中文字符无字形→方块」。
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
    ["SimSun", 12, 0, 12, 0, 12, 0, 12, 0],
    ["宋体", 12, 0, 12, 0, 12, 0, 12, 0],
    ["Songti SC", 12, 0, 12, 0, 12, 0, 12, 0],
    # 引擎内建字体字典（map.js FD_FontDictionary 硬编码 base64）会把请求名归一为
    # 「字典文件记录名」（带 .ttf 后缀，如 宋体→simsun.ttf）；渲染随后用
    # g_map_font_index[该记录名] 查本表——键必须含 .ttf 后缀，否则 undefined →
    # 无字体 → 控制符方块（2026-09-05 最后根因，实测 GetFontFileWeb('宋体')
    # 返回 path=simsun.ttf）。
    ["simsun.ttf", 12, 0, 12, 0, 12, 0, 12, 0],
    ["simhei.ttf", 12, 0, 12, 0, 12, 0, 12, 0],
    ["msyh.ttf", 12, 0, 12, 0, 12, 0, 12, 0],
]

# —— 字符范围回退表（引擎 libfont/character.js CFontByCharacter.init 消费的第三张
# 注入表 window["__fonts_ranges"]，格式 [start, end, infoRowIndex, ...] 展平三元组；
# 语义：Unicode [start, end] 中字符若在文档字体中缺字形，回退到
# FONT_INFOS[infoRowIndex][0] 字族 —— 2026-09-05 中文方块最后根因：
# 此前只注入 __fonts_files/__fonts_infos，缺这张表 → Ranges 空 → 任何 CJK 字符
# 回退失败 → 全部渲染为方块（引擎源代码 libfont/character.js:74 init 直接 return）。
# infoRowIndex 一律取 FONT_INFOS 中「宋体」行（=12，与 CJK 文件同下标）：
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

# —— B：CJK 字体子集化（2026-09-05 默认中文方案 B）——
# 9.25MB HarmonyOS_Sans_SC.ttf 是 13 个字体中唯一大文件：A（09_fonts 装填）虽把
# 字节保供提前到文档打开前，XHR 字节体积仍是毫秒 vs 秒的观感差；子集化后 ~1.3MB，
# 装填几乎瞬时，且对「首帧竞态」再无任何概率窗口。
# 字符集：GB2312 全集（6763 汉字 + 符号/字母区 A1A1-F7FE）+ ASCII + Latin-1
#   + CJK 标点（3000-303F）+ 全角形式（FF00-FFEF）。
#   取舍：BMP 扩展 A 区（3400-4DBF）生僻字不在子集内——此类字符渲染 notdef
#   （与桌面版「常用字库」取舍一致；文档实际内容多为常见字）。
# 前提：fontTools（pip install fonttools；构建机 4.63.0 实测 OK）。
# 输入源必须是**静态 glyf TTF**（templates_src/fonts/ 现成产物，勿用 VF/ CFF，
# 见 FONT_SRC_BY_FILE 注释踩坑记录）——子集化不改字体名/表序，__fonts_files
# 与 ascshim 09_fonts 装填（ID=HarmonyOS_Sans_SC.ttf）不受影响。
CJK_SUBSET_FONT = 'HarmonyOS_Sans_SC.ttf'
CJK_SUBSET_OUT = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src', 'fonts',
                              'HarmonyOS_Sans_SC.subset.ttf')


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


def make_cjk_subset(src):
    """pyftsubset 子集化（幂等：产物存在且不早于源 → 复用）。成功后返回产物路径。
    失败 raise SystemExit —— 构建链非零退出（缺 fontTools/CLI/尺寸越界/缺关键字形）"""
    import subprocess
    if os.path.isfile(CJK_SUBSET_OUT) and os.path.getmtime(CJK_SUBSET_OUT) >= os.path.getmtime(src):
        return CJK_SUBSET_OUT
    unicodes = ','.join('U+%04X' % cp for cp in sorted(_cjk_unicodes()))
    cmd = ['pyftsubset', src, '--unicodes=' + unicodes,
           '--output-file=' + CJK_SUBSET_OUT, '--layout-features=*']
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        raise SystemExit('pyftsubset 失败（%s）: %s' % (src, e.stderr.decode(errors='replace')[:500]))
    size = os.path.getsize(CJK_SUBSET_OUT)
    if not (100_000 < size < 5_000_000):
        raise SystemExit('CJK subset 尺寸越界: %d bytes' % size)
    # 关键字形断言：cmap 必须含 中(4E2D) 与 A(41) —— 防空壳子集静默进入 rawfile
    from fontTools.ttLib import TTFont
    cm = TTFont(CJK_SUBSET_OUT).getBestCmap()
    if 0x4E2D not in cm or 0x41 not in cm:
        raise SystemExit('CJK subset 缺关键字形（4E2D/41）—— 子集化失败')
    print('  CJK 子集化 %s -> %s (%d bytes, %d chars)'
          % (os.path.basename(src), os.path.basename(CJK_SUBSET_OUT), size, len(cm)))
    return CJK_SUBSET_OUT


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
                src = os.path.join(FONT_SRC_BY_FILE[ff], ff)
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


def install_smoke():
    """拷贝 scripts/onlyoffice/smoke/*.js → rawfile/onlyoffice/smoke/（多行可读的页面
    JS——EditorPage smoke 注入用；原来是 TS 字符串单行"缩成一坨"，此处外置为文件）。"""
    if not os.path.isdir(SMOKE_SRC):
        raise SystemExit('scripts/onlyoffice/smoke 不存在（smoke 诊断脚本源）')
    if os.path.isdir(SMOKE_DST):
        shutil.rmtree(SMOKE_DST)
    copy_tree(SMOKE_SRC, SMOKE_DST)
    n = sum(len(fs) for _, _, fs in os.walk(SMOKE_DST))
    print('  smoke 脚本 → %s (%d files)' % (SMOKE_DST, n))


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
    # 源目录按文件取（Liberation→系统目录；CJK→HarmonyOS SDK previewer 字库；
    # CJK_SUBSET_FONT 额外过子集化——方案 B，见函数块注释）
    os.makedirs(FONT_DST, exist_ok=True)
    fonts_ok = 0
    for fn in FONT_FILES:
        if fn == CJK_SUBSET_FONT:
            src_font = make_cjk_subset(os.path.join(FONT_SRC_BY_FILE[fn], fn))
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

    # 8. 版本号 version.json（资源内容哈希 → 编辑页 ?v=）
    v = gen_version_json()
    print('  version.json v=%s' % v)

    print('完成。')


if __name__ == '__main__':
    main()
