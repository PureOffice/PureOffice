#!/usr/bin/env python3
"""Pack ONLYOFFICE web-apps(sdkjs) dev 树子集到 HAP rawfile。

目标结构（与 web-apps 源码相对路径一致，index.html 原样生效）：
  rawfile/onlyoffice/
    sdkjs/                (来自 sdkjs/deploy/sdkjs，word + common)
    webapps/              (web-apps 选择性子集，index.html 定制为 dev+desktopinit)

用法：python3 scripts/onlyoffice/pack_web.py [--dry]
"""
import base64
import os
import re
import shutil
import subprocess
import sys
import argparse
import json

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC_SDK = os.path.join(ROOT, 'third_party', 'sdkjs', 'deploy', 'sdkjs')
SRC_WEB = os.path.join(ROOT, 'third_party', 'web-apps')
# POC 演示文档：官方测试 docx
DOC_SRC = os.path.join(ROOT, 'third_party', 'sdkjs', 'word', 'Documents',
                       'Изменение настроек таблиц по умолчанию.docx')
RAW = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice')

DST_SDK = os.path.join(RAW, 'sdkjs')
DST_WEB = os.path.join(RAW, 'webapps')

# ---------- 选择集 ----------
# 注意：deploy/sdkjs/word/sdk-all-min.js 是 Native(desktop) 版 sdk（含 native.js 设置
# NATIVE_EDITOR_ENJINE），web 前端必须用源码树分文件（develop/sdkjs/<arch>/scripts.js 清单）。
SDK_SRC = os.path.join(ROOT, 'third_party', 'sdkjs')
# 迭代2：三套编辑器架构（word/docx、cell/xlsx、slide/pptx 各 scripts.js 清单 + sdk-all 部署包）
ARCHS = [
    # (arch目录, scripts.js 相对 sdkjs 根, deploy/sdkjs 下的 sdk-all, editor.js 补丁 rel 或 None)
    ('word',  'develop/sdkjs/word/scripts.js',  'word/sdk-all.js',  'word/document/editor.js'),
    ('cell',  'develop/sdkjs/cell/scripts.js',  'cell/sdk-all.js',  None),  # cell getEmpty 在 document/empty.js（清单已有）
    ('slide', 'develop/sdkjs/slide/scripts.js', 'slide/sdk-all.js', 'slide/document/editor.js'),  # slide getEmpty 仅在此文件
]
# editor.js 追加进 scripts.js 的锚点（scripts.js 清单内字符串 → 追加行文本）
EDITOR_JS_ANCHOR = {
    'word': ('"../../../../sdkjs/word/document/empty.js",',
             '"../../../../sdkjs/word/document/empty.js",\n\t"../../../../sdkjs/word/document/editor.js",'),
    'slide': ('"../../../../sdkjs/slide/fromToJSON.js"',
              '"../../../../sdkjs/slide/fromToJSON.js",\n\t"../../../../sdkjs/slide/document/editor.js"'),
}

WEB_COPY = [  # (src, dst) 相对 web-apps 根的目录或文件
    # 运行时前端（js）
    ('apps/common/main/lib', 'apps/common/main/lib'),
    ('apps/common/main/locale', 'apps/common/main/locale'),
    ('apps/common/main/resources', 'apps/common/main/resources'),
    ('apps/common/Analytics.js', 'apps/common/Analytics.js'),
    ('apps/common/Gateway.js', 'apps/common/Gateway.js'),
    ('apps/common/IrregularStack.js', 'apps/common/IrregularStack.js'),
    ('apps/common/checkExtendedPDF.js', 'apps/common/checkExtendedPDF.js'),
    # require path 'common/locale' -> apps/common/locale.js
    ('apps/common/locale.js', 'apps/common/locale.js'),
    ('apps/documenteditor/main/app', 'apps/documenteditor/main/app'),
    ('apps/documenteditor/main/app_dev.js', 'apps/documenteditor/main/app_dev.js'),
    ('apps/documenteditor/main/app.js', 'apps/documenteditor/main/app.js'),
    ('apps/documenteditor/main/locale', 'apps/documenteditor/main/locale'),
    ('apps/documenteditor/main/resources', 'apps/documenteditor/main/resources'),
    # 迭代2：xlsx / pptx 编辑器页面（与 documenteditor 同构：app/app_dev/app.js/locale/resources）
    ('apps/spreadsheeteditor/main/app', 'apps/spreadsheeteditor/main/app'),
    ('apps/spreadsheeteditor/main/app_dev.js', 'apps/spreadsheeteditor/main/app_dev.js'),
    ('apps/spreadsheeteditor/main/app.js', 'apps/spreadsheeteditor/main/app.js'),
    ('apps/spreadsheeteditor/main/locale', 'apps/spreadsheeteditor/main/locale'),
    ('apps/spreadsheeteditor/main/resources', 'apps/spreadsheeteditor/main/resources'),
    ('apps/presentationeditor/main/app', 'apps/presentationeditor/main/app'),
    ('apps/presentationeditor/main/app_dev.js', 'apps/presentationeditor/main/app_dev.js'),
    ('apps/presentationeditor/main/app.js', 'apps/presentationeditor/main/app.js'),
    ('apps/presentationeditor/main/locale', 'apps/presentationeditor/main/locale'),
    ('apps/presentationeditor/main/resources', 'apps/presentationeditor/main/resources'),
    # vendor: 只复制 requirejs 的 path 所需文件（require path 无扩展名，解析到 .js 全名；
    # app_dev.js paths 为 '../vendor/jquery/jquery' 等，故必须提供非 min 全名）
    ('vendor/jquery/jquery.min.js', 'vendor/jquery/jquery.min.js'),
    ('vendor/jquery/jquery.js', 'vendor/jquery/jquery.js'),
    ('vendor/underscore/underscore-min.js', 'vendor/underscore/underscore-min.js'),
    ('vendor/underscore/underscore.js', 'vendor/underscore/underscore.js'),
    ('vendor/backbone/backbone-min.js', 'vendor/backbone/backbone-min.js'),
    ('vendor/backbone/backbone.js', 'vendor/backbone/backbone.js'),
    ('vendor/requirejs/require.js', 'vendor/requirejs/require.js'),
    ('vendor/requirejs-text/text.js', 'vendor/requirejs-text/text.js'),
    ('vendor/xregexp/xregexp-all-min.js', 'vendor/xregexp/xregexp-all-min.js'),
    ('vendor/socketio/socket.io.min.js', 'vendor/socketio/socket.io.min.js'),
    ('vendor/perfect-scrollbar/src', 'vendor/perfect-scrollbar/src'),
    ('vendor/svg-injector/svg-injector.min.js', 'vendor/svg-injector/svg-injector.min.js'),
    ('vendor/es6-promise/es6-promise.min.js', 'vendor/es6-promise/es6-promise.min.js'),
    ('vendor/jquery.browser/dist', 'vendor/jquery.browser/dist'),
    ('vendor/fetch/fetch.js', 'vendor/fetch/fetch.js'),
]

# webapps 树内明确剔除的大目录（帮助/测试/移动端……）
WEB_EXCLUDE_DIR = {'help', 'test', 'tests', 'mobile', 'embed', 'forms', 'node_modules', 'jsdoc'}
# locale 是 *.json 文件（en.json 聚合 DE+Common 全部键；POC 保中英，节约体积）
LOCALE_KEEP = ('en.json', 'zh-cn.json')


def _copy_tree(s: str, d: str):
    """复制目录，跳过 WEB_EXCLUDE_DIR 命名的子路径"""
    for root, dirs, files in os.walk(s):
        rel = os.path.relpath(root, s)
        keep_dirs = [x for x in dirs if x not in WEB_EXCLUDE_DIR]
        dirs[:] = keep_dirs
        for x in keep_dirs:
            os.makedirs(os.path.join(d, rel, x), exist_ok=True)
        for x in files:
            dst = os.path.join(d, rel, x)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(root, x), dst)


def copy_webapps():
    for src_rel, dst_rel in WEB_COPY:
        s = os.path.join(SRC_WEB, src_rel)
        d = os.path.join(DST_WEB, dst_rel)
        if not os.path.exists(s):
            print('!! missing src: %s' % src_rel)
            continue
        if os.path.isdir(s):
            if os.path.basename(s) == 'locale':
                # locale 是 *.json（en/zh-cn…）；兼容历史目录式（en-US/）
                os.makedirs(d, exist_ok=True)
                for lang in sorted(os.listdir(s)):
                    langpath = os.path.join(s, lang)
                    if os.path.isfile(langpath) and langpath.endswith('.json'):
                        if lang in LOCALE_KEEP:
                            shutil.copy2(langpath, os.path.join(d, lang))
                    elif os.path.isdir(langpath) and lang in LOCALE_KEEP:
                        shutil.copytree(langpath, os.path.join(d, lang), dirs_exist_ok=True)
            else:
                _copy_tree(s, d)
        else:
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d)


# POC-1 占位字体表：与 hook 注入的 __fonts_infos 同名同序。
# 真实字体数据（系统字体扫描 + 二进制流）由 B 架构 native 经
# __fonts_files/__fonts_infos 注入；此处 web 占位（系统 Liberation 字体，
# Arial/Times/Courier 的度量兼容替代，webapps 惯例）保证打开链不崩。
FAKE_FONTS = ["Arial", "Times New Roman", "Courier New"]

# __fonts_files 文件名（rawfile/onlyoffice/fonts/ 下），index 顺序与 __fonts_infos 对应。
# LiberationSans=Arial 兼容 / LiberationSerif=Times New Roman 兼容 / LiberationMono=Courier New 兼容
FONT_FILES = [
    'LiberationSans-Regular.ttf', 'LiberationSans-Italic.ttf',
    'LiberationSans-Bold.ttf', 'LiberationSans-BoldItalic.ttf',
    'LiberationSerif-Regular.ttf', 'LiberationSerif-Italic.ttf',
    'LiberationSerif-Bold.ttf', 'LiberationSerif-BoldItalic.ttf',
    'LiberationMono-Regular.ttf', 'LiberationMono-Italic.ttf',
    'LiberationMono-Bold.ttf', 'LiberationMono-BoldItalic.ttf',
]
# __fonts_infos 条目: [name, idxR, faceR, idxI, faceI, idxB, faceB, idxBI, faceBI]（9 元素）
# 契约来源 Externals.js checkAllFonts():
#   new CFontInfo(info[0], i, info[1], info[2], info[3], info[4], info[5], info[6], info[7], info[8])
#   CFontInfo(sName, thumbnail, indexR, faceIndexR, indexI, faceIndexI, indexB, faceIndexB, indexBI, faceIndexBI)
# 教训(v35)：曾注入 10 元素 [name, thumb, idxR, ...]，导致所有 indexX 被解析到 info[1]=0，
#   即全部字体 indexR/I/B/BI==0 -> 只有 fonts[0](LiberationSans-Regular) 真发 XHR；
#   其余字体 CFS=true 但 LoadFontAsync 因 Status!= -1 直接 return（v35 冻结根因）。
FONT_INFOS = [
    ["Arial", 0, 0, 1, 0, 2, 0, 3, 0],
    ["Liberation Sans", 0, 0, 1, 0, 2, 0, 3, 0],
    ["Times New Roman", 4, 0, 5, 0, 6, 0, 7, 0],
    ["Courier New", 8, 0, 9, 0, 10, 0, 11, 0],
    ["Symbol", 0, 0, 0, 0, 0, 0, 0, 0],
    ["Wingdings", 0, 0, 0, 0, 0, 0, 0, 0],
]
SYSTEM_FONTS_DIR = '/usr/share/fonts/truetype/liberation'
DEST_FONTS_DIR = os.path.join(RAW, 'fonts')


def make_font_selection_bin(fonts):
    """编码最小 g_fonts_selection_bin（CFontSelect v0 序列化，little-endian）：
    map.js FD_FontDictionary.Init -> FileStream 协议（SerializeCommonWordExcel.js）：
      每条记录: [name_len u32][name utf16le][path_len u32][path utf16le]
        [m_lIndex u32][italic u32][bold u32][fixed u32][panose_len u32][panose 10 x u8]
        [unirange1-4 u32 x4][codepage1-2 u32 x2][weight u16][width u16]
        [familyClass u16][fontFormat u16][avgWidth u16][ascent u16][descent u16]
        [lineGap u16][xHeight u16][capHeight u16]
    """
    import struct
    buf = struct.pack('<I', len(fonts))
    for name in fonts:
        n = name.encode('utf-16-le')
        p = (name.lower().replace(' ', '') + '.ttf').encode('utf-16-le')
        buf += struct.pack('<I', len(n)) + n
        buf += struct.pack('<I', len(p)) + p
        buf += struct.pack('<I', 0)                # m_lIndex
        buf += struct.pack('<I', 0)                # italic
        buf += struct.pack('<I', 0)                # bold
        buf += struct.pack('<I', 0)                # fixed
        buf += struct.pack('<I', 10) + b'\x00' * 10  # panose
        buf += struct.pack('<IIII', 0, 0, 0, 0)    # unicode ranges
        buf += struct.pack('<II', 0, 0)            # codepage ranges
        buf += struct.pack('<HH', 400, 0)          # weight, width
        buf += struct.pack('<HHHHHHHH', 0, 1, 0, 0, 0, 0, 0, 0)  # family/format/avg/asc/desc/line/xh/cap
    return base64.b64encode(buf).decode('ascii')


# ONLYOFFICE server 字体预加密密钥（web SDK LoadFontArrayBuffer onload 无条件 XOR 解码前 32B）
FONT_GUID_ODTTF = bytes([0xA0, 0x66, 0xD6, 0x20, 0x14, 0x96, 0x47, 0xFA, 0x95, 0x69, 0xB8, 0x50, 0xB0, 0x41, 0x49, 0x48])


def pre_xor_font(path):
    """v49 根因修复：SDK 假设服务器字体已用 guidOdttf 预加密（前 32B）。
    我们的 rawfile 是明文 ttf，onload decode 后反而变成损坏字节 ->
    FT_Open_Face 返回 null -> m_pFont null -> textshaper m_pFaceInfo 崩溃。
    pack 对拷贝后的每个字体前 32B XOR 一次（copy_fonts 每次从系统源重新拷贝，故幂等）。"""
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


def copy_fonts():
    """拷贝系统 Liberation 字体到 rawfile/onlyoffice/fonts/：
    GlobalLoaders.fontFilesPath = '../../../../fonts/'（相对 index.html -> onlyoffice/fonts/），
    web 版 XHR 按 fontFilesPath + CFontFileLoader.Id 加载字体流。
    副本按 server 惯例预加密（pre_xor_font），SDK onload 解码后还原明文。"""
    os.makedirs(DEST_FONTS_DIR, exist_ok=True)
    n = 0
    for name in FONT_FILES:
        s = os.path.join(SYSTEM_FONTS_DIR, name)
        if os.path.exists(s):
            dst = os.path.join(DEST_FONTS_DIR, name)
            shutil.copy2(s, dst)
            if not pre_xor_font(dst):
                print('!! xor failed: %s' % name)
            n += 1
        else:
            print('!! fonts missing: %s' % s)
    print('fonts copied: %d (guidOdttf pre-xor applied)' % n)


def copy_sdk_arch(arch, scripts_rel, sdkall_rel, editor_rel):
    """按 develop/sdkjs/<arch>/scripts.js 清单拷贝源码树分文件（web 版 sdk + scripts.js 自身）
    叠加油漆：AllFonts.js 占位（见下方注释）、editor.js 补丁（word 特有）、sdk-all.js 部署包。"""
    import re as _re
    SCRIPTS_JS = os.path.join(SDK_SRC, scripts_rel)
    with open(SCRIPTS_JS, 'r', encoding='utf-8') as f:
        t = f.read()
    items = _re.findall(r'"([^"]+)"', t)
    # 路径形如 ../../../../sdkjs/vendor/polyfill.js（相对 index.html 所在层），
    # 去掉前缀得到相对 onlyoffice/ 的 sdkjs/ 路径
    n = 0
    for item in items:
        m = _re.match(r'^\.\./\.\./\.\./\.\./sdkjs/(.*)$', item)
        if not m:
            continue
        rel = m.group(1)
        s = os.path.join(SDK_SRC, rel)
        d = os.path.join(DST_SDK, rel)
        if not os.path.exists(s):
            # AllFonts.js 是构建产物（web 端字体选择表 g_fonts_selection_bin）。
            # g_fonts_selection_bin 缺省为 undefined 时 map.js Init 的
            # `"" != undefined` 为 true -> CreateFontData2(undefined) 抛
            # "Cannot read properties of undefined (reading 'length')"，asc_docs_api 构造失败；
            # 且为空字符串则 FD_FontDictionary 字体表为空 -> GetFontIndex 返回 undefined
            # （v29 实证 odERR "Cannot set properties of undefined (setting 'NeedStyles')"）。
            # 故为占位字体集（与 hook 注入的 __fonts_infos 同名）编码最小选择表。
            if rel == 'common/AllFonts.js':
                os.makedirs(os.path.dirname(d), exist_ok=True)
                with open(d, 'w', encoding='utf-8') as f:
                    # 空注册表兜底：GlobalLoaders.LoadDocumentFonts 里
                    # `this.fontInfos.length` 在 g_font_infos undefined 时崩（v28 实证）。
                    # 真实的 g_font_files/g_font_infos 由 Externals.js checkAllFonts()
                    # 从 hook 注入的 __fonts_files/__fonts_infos 构建。
                    f.write('// AllFonts placeholder (web fake font registry)\n'
                            'window["AscFonts"] = window["AscFonts"] || {};\n'
                            'window["AscFonts"].g_font_infos = [];\n'
                            'window["AscFonts"].g_map_font_index = {};\n'
                            'window["AscFonts"].g_font_files = [];\n'
                            'window["AscFonts"].g_map_font_index_embed = {};\n'
                            'window["AscFonts"].g_font_infos_embed = [];\n'
                            'window["g_fonts_selection_bin"] = "%s";\n'
                            % make_font_selection_bin(FAKE_FONTS))
                n += 1
                continue
            print('[%s] scripts.js 引用缺失: %s' % (arch, rel))
            continue
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(s, d)
        n += 1
    # scripts.js 自身
    scr_dst = os.path.join(DST_SDK, 'develop', 'sdkjs', arch, 'scripts.js')
    os.makedirs(os.path.dirname(scr_dst), exist_ok=True)
    shutil.copy2(SCRIPTS_JS, scr_dst)
    n += 1
    # word/document/editor.js：AscCommon.getEmpty() 的唯一实现（9.4.0 新增的空文档
    # v2 构造器）。上游 configs/word.json -> develop/sdkjs/word/scripts.js 清单漏收它，
    # 而 common/apiBase.js 的 _openEmptyDocument（离线/空文档打开必走）依赖
    # AscCommon.getEmpty()。word 补拷文件并把清单项插入 rawfile 版 scripts.js；
    # cell/slide 无对应实现（它们的 _openEmptyDocument 走 base 链仍缺 getEmpty，
    # 迭代2 打开链不经过该路径时先不处理，真机证明缺再补）。
    if editor_rel:
        editor_src = os.path.join(SDK_SRC, editor_rel)
        if os.path.exists(editor_src):
            editor_dst = os.path.join(DST_SDK, editor_rel)
            os.makedirs(os.path.dirname(editor_dst), exist_ok=True)
            shutil.copy2(editor_src, editor_dst)
            n += 1
            scripts_dst = os.path.join(DST_SDK, 'develop', 'sdkjs', arch, 'scripts.js')
            with open(scripts_dst, 'r', encoding='utf-8') as f:
                t = f.read()
            anc = EDITOR_JS_ANCHOR.get(arch)
            if anc is not None:
                old_item, new_item = anc
                if old_item in t and new_item not in t:
                    t = t.replace(old_item, new_item)
                    with open(scripts_dst, 'w', encoding='utf-8') as f:
                        f.write(t)
                    print('scripts.js += %s' % editor_rel)
                elif new_item not in t:
                    print('!! scripts.js 锚点未找到: %s' % old_item)
            else:
                print('scripts.js editor.js append: no anchor for %s' % arch)
        else:
            print('!! %s missing in sdkjs tree' % editor_rel)
    # loadSdk（asc_docs_api 构造后异步加载编辑器核心，apiBase.js loadSdk ->
    # loadScript('./../../../../sdkjs/<arch>/sdk-all.js')）需要 sdk-all.js。
    # deploy 包为 web/desktop 双模式：仅当 native.js 加载才设 NATIVE_EDITOR_ENJINE，
    # 我们不提供 native.js 即纯 web 模式。
    sdkall_src = os.path.join(SDK_SRC, 'deploy', 'sdkjs', sdkall_rel)
    if os.path.exists(sdkall_src):
        os.makedirs(os.path.join(DST_SDK, os.path.dirname(sdkall_rel)), exist_ok=True)
        shutil.copy2(sdkall_src, os.path.join(DST_SDK, sdkall_rel))
        n += 1
    else:
        print('!! [%s] sdk-all.js missing in deploy tree' % arch)
    return n


def copy_sdkjs():
    """三套编辑器架构（word/cell/slide）源码树分文件拷贝"""
    n = 0
    for arch, scripts_rel, sdkall_rel, editor_rel in ARCHS:
        n += copy_sdk_arch(arch, scripts_rel, sdkall_rel, editor_rel)
    # 运行时按需加载（不在 scripts.js 清单，但开发模式会 loadScript/xhr）：
    #   - libfont/engine/fonts.js：AscFonts.load -> loadScript('.../engine/fonts.js')
    #     （WebAssembly 可用时；fonts_ie.js 为 fallback）。
    #     fonts.js 是 Emscripten loader：wasmBinaryFile="fonts.wasm"，执行时
    #     fetch('./fonts.wasm')（相对 URL 同目录）。若 fonts.wasm 缺失，原始
    #     fetch 命中 rawfile 404 -> WebAssembly.instantiate 失败 -> abort()，
    #     __ATPOSTRUN__（AscFonts.onLoadModule）永不执行 -> AscFonts.onSuccess
    #     永不回调 -> modulesLoaded 卡 0 -> onEndLoadFile 死锁（曾以 dl/dr 不
    #     触发为表现）。故 fonts.wasm 必须随拷。
    #   - Charts/ChartStyles.js：AscCommon.loadChartStyles（apiBase 构造时加载）
    #   - Drawings/Format/path-boolean-min.js：AscCommon.loadPathBoolean（合并形状时）
    #   - Images/cursors/svg.json：editorscommon.js xhr 读取（光标准备）
    #   - common/spell/spell/spell.js：拼写检查引擎按需 loadScript（server 部署才存在该路径；
    #     源码树在 sdkjs/common/spell/spell/ 下，运行时 URL 为 sdkjs/common/spell/spell/spell.js）
    EXTRA_SDK = [
        'common/libfont/engine/fonts.js',
        'common/libfont/engine/fonts.wasm',
        'common/libfont/engine/fonts_ie.js',
        'common/Charts/ChartStyles.js',
        'common/Drawings/Format/path-boolean-min.js',
        'common/Images/cursors/svg.json',
        'common/spell/spell/spell.js',
        'common/spell/spell/spell_ie.js',
    ]
    # sdkjs 运行时按需的整目录：编辑器占位图/锚点/内容控件图标等
    # （placeholders/*、icons/*、content_controls/*、reporter/* 均为源码树原始文件）
    EXTRA_SDK_DIRS = [
        'common/Images',
    ]
    for rel in EXTRA_SDK:
        s = os.path.join(SDK_SRC, rel)
        if not os.path.exists(s):
            print('!! extra sdk missing: %s' % rel)
            continue
        d = os.path.join(DST_SDK, rel)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(s, d)
        n += 1
    for rel in EXTRA_SDK_DIRS:
        s = os.path.join(SDK_SRC, rel)
        if not os.path.isdir(s):
            print('!! extra sdk dir missing: %s' % rel)
            continue
        d = os.path.join(DST_SDK, rel)
        os.makedirs(d, exist_ok=True)
        _copy_tree(s, d)
        n += 1
    print('sdk web copies: %d' % n)


def precompile_css(app_dir: str) -> bool:
    """宿主 lessc 预编译 <app>/main/resources/less/app.less -> 同 resources/css/app.css。
    返回是否成功（成功才切 index.html 到静态 css 链接）。"""
    less_src = os.path.join(app_dir, 'resources', 'less', 'app.less')
    css_dst = os.path.join(app_dir, 'resources', 'css', 'app.css')
    if not os.path.isfile(less_src):
        print('css: skip (no less source) %s' % less_src)
        return False
    os.makedirs(os.path.dirname(css_dst), exist_ok=True)
    try:
        r = subprocess.run(['lessc', less_src, css_dst], cwd=os.path.dirname(less_src),
                           capture_output=True, text=True, timeout=300)
    except Exception as e:
        print('css: lessc failed (%s) -> keep runtime less' % e)
        return False
    if r.returncode != 0 or not os.path.isfile(css_dst):
        print('css: lessc rc=%(rc)d %(err)s -> keep runtime less' %
              {'rc': r.returncode, 'err': r.stderr.strip()[:300]})
        return False
    print('css: %s -> %s (%d B)' % (os.path.relpath(less_src), os.path.relpath(css_dst), os.path.getsize(css_dst)))
    return True


def make_index_html(page: str, dst_index: str, doc_type: str = 'word', use_css: bool = False):
    """基于 <page>/main/index.html（word/spreadsheet/presentation）定制：
    1) 引 desktopinit.js（桌面桥契约脚本）
    2) sdk 加载从 develop/scripts.js 改为 deploy 的 sdk-all-min.js
    page: 'documenteditor'|'spreadsheeteditor'|'presentationeditor'; doc_type 驱动 launch/编辑器类型
    use_css: True 时用预编译 resources/css/app.css（附在 precompile_css 调用后）
    """
    src = os.path.join(SRC_WEB, 'apps', page, 'main', 'index.html')
    with open(src, 'r', encoding='utf-8') as f:
        html = f.read()

    # 打开链监视：在 editorscommon.js 导出 Asc/AscCommon/AscFonts 前拦截赋值，
    # 提前 hook。PROBE 的 setInterval tick 太晚——436 清单 document.write 同步阻塞，
    # fonts.js postRun -> onLoadModule -> openDocument 的错误发生在第一个 tick 之前。
    hook = '''
    <script>
    (function () {
      window.__pf = ['mon'];
      var _pf = window.__pf;
      var PFLIM = 15000;
      // ---- B 架构桥：模拟 native 字体注册表注入（POC-1 占位；native 阶段
      // 由 cpp 在页面加载后经 window.__fonts_files/__fonts_infos 注入真字体）。
      // 必须在 Externals.js（scripts.js 清单 125 项）模块级 checkAllFonts() 之前就位 --
      // 本 script 位于 jquery 之前，早于所有 sdk 清单文件。 ----
      try {
        window["__fonts_files"] = __FONT_FILES_JSON__;
        window["__fonts_infos"] = __FONT_INFOS_JSON__;
        _pf.push('fontinj:' + window["__fonts_files"].length + 'f' + window["__fonts_infos"].length + 'i');
      } catch (e) { _pf.push('fontinjERR:' + e.message); }
      // ---- XHR 监视：只关心字体/wasm/sdk-all 请求（模板等无关请求不再刷屏）----
      try {
        var _OX = window.XMLHttpRequest;
        window.XMLHttpRequest = function () {
          var _x = new _OX();
          try {
            var _open = _x.open, _send = _x.send;
            _x.open = function (m, u) {
              _x.__u = String(u);
              if ((_x.__u.indexOf('fonts') >= 0 || _x.__u.indexOf('.wasm') >= 0 || _x.__u.indexOf('sdk-all') >= 0) && _pf.length < PFLIM)
                _pf.push('xr:' + _x.__u.slice(-40));
              return _open.apply(this, arguments);
            };
            _x.send = function () {
              var ol = _x.onload, oe = _x.onerror;
              if (_x.__u && (_x.__u.indexOf('fonts') >= 0 || _x.__u.indexOf('.wasm') >= 0 || _x.__u.indexOf('sdk-all') >= 0)) {
                _x.onload = function () {
                  if (_pf.length < PFLIM) _pf.push('xrOK:' + _x.status + ':' + _x.__u.slice(-32));
                  return ol ? ol.apply(this, arguments) : undefined;
                };
                _x.onerror = function () {
                  if (_pf.length < PFLIM) _pf.push('xrERR:' + _x.__u.slice(-32));
                  return oe ? oe.apply(this, arguments) : undefined;
                };
              }
              return _send.apply(this, arguments);
            };
          } catch (e) { _pf.push('xrHERR:' + e.message); }
          return _x;
        };
        window.XMLHttpRequest.prototype = _OX.prototype;
      } catch (e) { _pf.push('xrHERR2:' + e.message); }
      var _afPrev = '';
      function hookAFDbg() {
        var AF = window.AscFonts;
        if (!AF || !AF.g_fontApplication) return;
        var n0 = 0, n1 = 0, n2 = 0, nn = 0;
        if (AF.g_font_files) for (var i = 0; i < AF.g_font_files.length; ++i) {
          var f = AF.g_font_files[i];
          if (!f) continue;
          if (f.Status === 0) n0++; else if (f.Status === 2) n2++; else if (f.Status === 1) n1++; else nn++;
        }
        var _s = (AF.g_font_infos ? AF.g_font_infos.length : -1) + '/' + (AF.g_font_files ? AF.g_font_files.length : -1)
          + '/' + Object.keys(AF.g_map_font_index || {}).length
          + '/' + (window.g_fonts_selection_bin ? String(window.g_fonts_selection_bin).slice(0, 4) : 'none')
          + '/L:' + n0 + '+' + n2 + 'r' + n1 + 'n' + nn;
        if (_s !== _afPrev) { _afPrev = _s; if (_pf.length < PFLIM) _pf.push('af:' + _s); }
      }
      // ---- 全局 JS 错误捕获：check_loaded_list 等 timer 回调内的异常被浏览器吞掉 ----
      window.addEventListener('error', function (e) {
        var _loc = '?';
        try { _loc = String(e.filename || '?').slice(-46) + ':' + (e.lineno || 0) + ':' + (e.colno || 0); } catch (e2) { _loc = '?'; }
        var _m = String(e && (e.message || (e.error && e.error.message)) || e);
        if (_pf.length < PFLIM) _pf.push('JSE:' + _loc + '|' + _m.slice(0, 140));
        if (_m.indexOf('m_pFaceInfo') >= 0 && _pf.length < PFLIM) {
          try {
            var _AF2 = window.AscFonts || {};
            var _TM2 = window.AscCommon && window.AscCommon.g_oTextMeasurer;
            var _M2 = _TM2 && _TM2.m_oManager;
            var _MF = _M2 && _M2.m_pFont;
            var _GFA = _AF2.g_fontApplication;
            var _sts = [];
            if (_AF2.g_font_files) for (var i5 = 0; i5 < _AF2.g_font_files.length; ++i5) {
              var _g5 = _AF2.g_font_files[i5];
              if (_g5) _sts.push(String(_g5.Id || '?').slice(-14) + '#' + _g5.Status);
            }
            _pf.push('JSC:' + JSON.stringify({
              er: !!(window.AscFonts && _AF2.isEngineReady),
              fi: (_AF2.g_font_infos ? _AF2.g_font_infos.length : -1),
              ff: (_AF2.g_font_files ? _AF2.g_font_files.length : -1),
              gfd: (_AF2.g_font_files ? _AF2.g_font_files.length : -1),
              fp: !!(window.AscFonts && _AF2.FontPickerByCharacter),
              sel: (window.g_fonts_selection_bin ? String(window.g_fonts_selection_bin).slice(0, 4) : 'none'),
              mf: _MF ? 'Y' : 'N',
              mfname: _MF ? String(_MF.GetFamilyName ? _MF.GetFamilyName() : '?') : '-',
              mfi: String((_MF && _MF.m_pFaceInfo) ? 'y' : 'n'),
              gfa: !!_GFA, gfaDI: (_GFA && _GFA.DefaultIndex !== undefined) ? _GFA.DefaultIndex : '-',
              lib: String((_M2 && _M2._engine && _M2._engine.library !== undefined) ? _M2._engine.library : '-'),
              sts: _sts.join(',')
            }));
          } catch (e3) { }
        }
      });
      window.addEventListener('unhandledrejection', function (e) {
        var _rs = String(e && e.reason && (e.reason.message || e.reason));
        var _st = '';
        try { _st = String((e && e.reason && e.reason.stack) || '').split(String.fromCharCode(10)).slice(0, 6).join('|').slice(0, 400); } catch (__x) {}
        if ((_pf.length < PFLIM)) _pf.push('REJ:' + _rs.slice(0, 160) + ';&' + _st);
      });
      // ---- 原型级 hook（sdk 清单 document.write 完成后才存在，经 400ms 轮询就位）----
      var _protoHooksDone = 0;
      function hookProto() {
        try {
          var _BA = window.AscCommon && window.AscCommon.baseEditorsApi;
          if (_BA && _BA.prototype && !_BA.prototype.__bhd) {
            _BA.prototype.__bhd = 1;
            var _h = function (nm) {
              var _f = _BA.prototype[nm];
              if (typeof _f !== 'function') return;
              _BA.prototype[nm] = function () {
                if (_pf.length < PFLIM) _pf.push('BA:' + nm);
                return _f.apply(this, arguments);
              };
            };
            ['onEndLoadDocInfo', 'onEndLoadFile', '_openChartOrLocalDocument', '_openEmptyDocument',
             'onDocumentContentReady', '_onEndLoadSdk', 'openDocument', 'asc_LoadDocument',
             'asyncServerIdEndLoaded', 'asc_getEditorPermissions', '_coAuthoringInit', '_onEndPermissions'].forEach(_h);
            // CDocsCoApi（coauthoring 底层）：init/auth 分支（在线 vs dummy）判别
            var _CCA = window.AscCommon && window.AscCommon.CDocsCoApi;
            if (_CCA && _CCA.prototype && !_CCA.prototype.__ccah) {
              _CCA.prototype.__ccah = 1;
              var _cc = function (nm) {
                var _f = _CCA.prototype[nm];
                if (typeof _f !== 'function') return;
                _CCA.prototype[nm] = function () {
                  var _off = null;
                  try { _off = (this._CoAuthoringApi && this._CoAuthoringApi.isRightURL) ? this._CoAuthoringApi.isRightURL() : null; } catch (e) { _off = 'e'; }
                  if (_pf.length < PFLIM) _pf.push('CC:' + nm + ':in:' + _off);
                  try { var r = _f.apply(this, arguments); if (_pf.length < PFLIM) _pf.push('CC:' + nm + ':ret'); return r; }
                  catch (e) { if (_pf.length < PFLIM) _pf.push('CC:' + nm + ':ERR:' + String(e && e.message).slice(0, 100)); throw e; }
                };
              };
              ['init', 'auth'].forEach(_cc);
            }
          }
          var _AP = window["asc_docs_api"];
          if (_AP && _AP.prototype && _AP.prototype.sendEvent && !_AP.prototype.__evh) {
            _AP.prototype.__evh = 1;
            var _s2 = _AP.prototype.sendEvent;
            _AP.prototype.sendEvent = function () {
              var n = arguments[0];
              if (String(n).slice(0, 7) === 'asc_on' && _pf.length < PFLIM) _pf.push('ev:' + n);
              return _s2.apply(this, arguments);
            };
          }
          var _CF = window.AscFonts && window.AscFonts.CFontFileLoader;
          if (_CF && _CF.prototype && !_CF.prototype.__cfh) {
            _CF.prototype.__cfh = 1;
            var _cl = _CF.prototype.CheckLoaded;
            _CF.prototype.CheckLoaded = function () {
              var st = this.Status;
              if (st !== this.__pst) {
                this.__pst = st;
                var _cth = '';
                if (st === 0 && this.stream_index !== undefined && this.stream_index >= 0) {
                  try {
                    var _stm = window.AscFonts && window.AscFonts.g_fonts_streams[this.stream_index];
                    var _dt = _stm && _stm.data;
                    var _chx = [];
                    if (_dt && _dt.length !== undefined) { for (var i3 = 0; i3 < Math.min(8, _dt.length); ++i3) _chx.push(('0' + _dt[i3].toString(16)).slice(-2)); }
                    _cth = ':s' + String(_stm ? ((_stm.size !== undefined) ? _stm.size : (_stm.len !== undefined ? _stm.len : '?')) : 'X')
                      + ':h' + _chx.join('') + ':a' + ((_stm && _stm.asc_marker) ? 'Y' : 'N');
                  } catch (e4) { _cth = ':E' + String(e4.message || e4).slice(0, 20); }
                }
                if (_pf.length < PFLIM) _pf.push('cl:' + String(this.Id || '').slice(-18) + ':' + st + _cth);
              }
              return _cl.apply(this, arguments);
            };
            var _lf = _CF.prototype.LoadFontFromData;
            _CF.prototype.LoadFontFromData = function (d) {
              if (_pf.length < PFLIM) {
                var _fb = [];
                try { for (var i7 = 0; i7 < 8 && d && i7 < d.length; ++i7) _fb.push(('0' + d[i7].toString(16)).slice(-2)); } catch (e7) { }
                _pf.push('fd:' + String(this.Id || '').slice(-18) + ':' + (d && d.length || 0) + ':h' + _fb.join(''));
              }
              return _lf.apply(this, arguments);
            };
          }
          // GlobalLoaders 的方法均为构造函数体内 this.xxx = function（每实例一份），
          // 必须 hook 单例实例（g_font_loader），prototype 无效。
          var _FGL = window.AscCommon && window.AscCommon.g_font_loader;
          if (_FGL && !_FGL.__glh && typeof _FGL._LoadFonts === 'function') {
            _FGL.__glh = 1;
            var _lk = function (nm) {
              var _f = _FGL[nm];
              if (typeof _f !== 'function') return;
              _FGL[nm] = function () {
                var f0 = this.fonts_loading && this.fonts_loading[0];
                if (_pf.length < PFLIM) _pf.push('GL:' + nm + ':' + (this.fonts_loading ? this.fonts_loading.length : '?') + (f0 && f0.Name ? ':' + f0.Name.slice(0, 12) : ''));
                return _f.apply(this, arguments);
              };
            };
            ['_LoadFonts', 'check_loaded_list', 'LoadDocumentFonts', 'CheckFontsNeedLoadingLoad'].forEach(_lk);
          }
          // CFontInfo.CheckFontLoadStyles：结果变化时才记录（每 50ms tick 高频调用）
          // 另加 CF0: 首次记录该实例 indexR/faceR/indexI/indexB/indexBI —— 验证 __fonts_infos 解析
          var _CI = window.AscFonts && window.AscFonts.CFontInfo;
          if (_CI && _CI.prototype && !_CI.prototype.__cih) {
            _CI.prototype.__cih = 1;
            var _ccl = _CI.prototype.CheckFontLoadStyles;
            _CI.prototype.CheckFontLoadStyles = function (gl) {
              var r = _ccl.apply(this, arguments);
              var k = (this.Name || '?') + '=' + r;
              if (this.__lrr !== k) { this.__lrr = k; if (_pf.length < PFLIM) _pf.push('CFS:' + k); }
              if (!this.__lrr0) {
                this.__lrr0 = 1;
                if (_pf.length < PFLIM) _pf.push('CF0:' + (this.Name || '?') + ':' + this.indexR + '/' + this.faceIndexR + '/' + this.indexI + '/' + this.indexB + '/' + this.indexBI);
              }
              return r;
            };
          }
          // asc_docs_api.prototype 方法（asyncFontsDocumentEndLoaded 等不在 baseEditorsApi 上）
          var _DA = window["asc_docs_api"];
          if (_DA && _DA.prototype && !_DA.prototype.__dah) {
            _DA.prototype.__dah = 1;
            var _dh = function (nm) {
              var _f = _DA.prototype[nm];
              if (typeof _f !== 'function') return;
              _DA.prototype[nm] = function () {
                if (_pf.length < PFLIM) _pf.push('DA:' + nm);
                return _f.apply(this, arguments);
              };
            };
            ['asyncFontsDocumentEndLoaded', 'asyncImagesDocumentEndLoaded', 'asyncImageEndLoaded',
             'asyncImageEndLoadedBackground', 'asyncImageStartLoaded', 'asyncImagesStartLoaded',
             'onDocumentContentReady', 'InitControl', 'asyncImagesDocumentStartLoaded'].forEach(_dh);
            // _openDocumentEndCallback 特化：入口 guard 五条件判别（卡在哪个值）
            var _deoc = _DA.prototype._openDocumentEndCallback;
            if (typeof _deoc === 'function' && !_deoc.__deoch) {
              var _deocOrig = _deoc;
              _DA.prototype._openDocumentEndCallback = function () {
                var _w = this.WordControl, _miss = [];
                if (this.isDocumentLoadComplete) _miss.push('iDocLoad');
                if (!this.ServerImagesWaitComplete) _miss.push('SImgW');
                if (!this.ServerIdWaitComplete) _miss.push('SIdW');
                if (!_w) _miss.push('WC');
                else if (!_w.m_oLogicDocument) _miss.push('LogicDoc');
                if (_pf.length < PFLIM) _pf.push('DEOC:' + (_miss.join(',') || 'PASS'));
                return _deocOrig.apply(this, arguments);
              };
            }
            // asyncImagesDocumentEndLoaded 专用深入打点：m_oDrawingDocument.OpenDocument 与状态
            var _de = _DA.prototype.asyncImagesDocumentEndLoaded;
            if (typeof _de === 'function' && !_de.__deh) {
              var _deOrig = _de;
              _DA.prototype.asyncImagesDocumentEndLoaded = function () {
                var r;
                try {
                  var _wc = this.WordControl;
                  var _dd = _wc && _wc.m_oDrawingDocument;
                  if (_pf.length < PFLIM) _pf.push('DEI:' + (_dd ? (_dd.m_oDocumentRenderer ? 'R' : 'noR') : 'noDD') + ':' + this.bInit_word_control + ':' + this.isPasteFonts_Images + ':' + this.isSaveFonts_Images + ':' + this.isLoadImagesCustom + ':' + this.EndActionLoadImages);
                  if (_dd && _dd.OpenDocument && !_dd.__oddh) {
                    _dd.__oddh = 1;
                    var _o = _dd.OpenDocument;
                    _dd.OpenDocument = function () {
                      if (_pf.length < PFLIM) _pf.push('DA:OpenDocument:enter');
                      try { var _r = _o.apply(this, arguments); if (_pf.length < PFLIM) _pf.push('DA:OpenDocument:done'); return _r; }
                      catch (e) { if (_pf.length < PFLIM) _pf.push('ODdERR:' + String(e && e.message).slice(0, 120)); throw e; }
                    };
                  }
                } catch (e) { if (_pf.length < PFLIM) _pf.push('DEIhERR:' + String(e && e.message).slice(0, 100)); }
                r = _deOrig.apply(this, arguments);
                if (_pf.length < PFLIM) _pf.push('DEI:ret:' + this.bInit_word_control);
                return r;
              };
            }
          }
          // ImageLoader 单例实例（图片加载链）
          var _IGL = window.AscCommon && window.AscCommon.g_image_loader;
          if (_IGL && !_IGL.__ilh && typeof _IGL.LoadDocumentImages === 'function') {
            _IGL.__ilh = 1;
            var _ih = function (nm) {
              var _f = _IGL[nm];
              if (typeof _f !== 'function') return;
              _IGL[nm] = function () {
                var a0 = arguments[0];
                var _n = 'null';
                if (a0) _n = (typeof a0.length === 'number') ? a0.length : Object.keys(a0).length;
                if (_pf.length < PFLIM) _pf.push('IGL:' + nm + ':' + _n);
                return _f.apply(this, arguments);
              };
            };
            ['LoadDocumentImages', '_LoadImages', '_LoadImagesAsync', 'LoadImagesWithCallback', 'LoadImageAsync', 'LoadImage'].forEach(_ih);
          }
          // 图片 URL 解析（getFullImageSrc2）：data: URI（纹理）只记计数，防刷爆 PFLIM
          var _gfs = window.AscCommon && window.AscCommon.getFullImageSrc2;
          if (_gfs && typeof _gfs === 'function' && !_gfs.__gfh) {
            _gfs.__gfh = 1;
            var __gfsDn = 0;
            window.AscCommon.getFullImageSrc2 = function (s) {
              var r = _gfs.call(this, s);
              var ss = String(r);
              if (ss.indexOf('data:') === 0) {
                if (++__gfsDn <= 3 && _pf.length < PFLIM) _pf.push('gfsD:' + __gfsDn + ':' + ss.slice(-24));
              } else if (_pf.length < PFLIM) _pf.push('gfs:' + ss.slice(-40));
              return r;
            };
          }
        } catch (e) { if (_pf.length < PFLIM) _pf.push('prhERR:' + e.message); }
      }
      // ---- 打开链四件套（迭代1 定稿，模板内嵌，勿在 rawfile 手工改）----
      // docType（docx/xlsx/pptx）由壳层 loadUrl 的 ?docType= 传入，驱动转换桥的目标后缀
      try { window.__docType = new URLSearchParams(location.search).get('docType') || 'docx'; } catch (e) {}
      function hookSendEvent() {
        var ed = window.Asc && window.Asc.editor;
        if (!ed || ed._hse || typeof ed.sendEvent !== 'function') return;
        ed._hse = 1;
        var _se = ed.sendEvent;
        ed.sendEvent = function (id, lv, dt) {
          try { if (String(id) !== 'asc_onPaintTimer') _pf.push('seE:' + String(id) + '|' + String(lv) + '|' + String(dt || '').slice(0, 90)); }
          catch (e2) { }
          return _se.apply(this, arguments);
        };
      }
      function ascAbToB64(u8) {
        var s8 = '';
        for (var i9 = 0; i9 < u8.length; ++i9) s8 += String.fromCharCode(u8[i9]);
        try { return window.btoa(s8); }
        catch (e4) { if (_pf.length < PFLIM) _pf.push('ootb64ERR:' + String(e4.message || e4).slice(0, 60)); return ''; }
      }
      // 打开桥回调：ArkTS x2t 产物 base64 信封 → atob 还原 → Uint8Array 直投 openDocument
      //（v10 必须 Uint8Array；binary string 路径实测空模型/卡死——迭代1 核心坑）
      window.__oobDocy = function (b64in) {
        try {
          if (!b64in || b64in.length === 0) { _pf.push('ood:null'); return; }
          var docy = '';
          try { docy = window.atob(b64in); }
          catch (ba) { _pf.push('ood:atobERR:' + String(ba || '').slice(0, 80)); return; }
          _pf.push('ood:got len=' + docy.length + ' head=' + String(docy).slice(0, 18));
          var h9 = 2166136261;
          try { for (var i9 = 0; i9 < docy.length; ++i9) { h9 ^= docy.charCodeAt(i9); h9 = (h9 * 16777619) >>> 0; } _pf.push('f3:' + h9); } catch (he) { _pf.push('f3:ERR'); }
          var e8 = window.Asc && (window.Asc.editor || window.editor);
          if (!e8) { _pf.push('ood:noeditor'); return; }
          try {
            var arr = new Uint8Array(docy.length);
            for (var iQ = 0; iQ < docy.length; ++iQ) { arr[iQ] = docy.charCodeAt(iQ); }
            _pf.push('p5:arr=' + arr.length + ':t=' + (window.__docType || '?'));
            e8.openDocument({ bSerFormat: true, url: '', data: arr });
            _pf.push('ood:called');
            // cell/slide 内容就绪守卫（asc_onDocumentContentReady 唯一单机路径在
            // _openDocumentEndCallback，guard 三重 isDocumentLoadComplete/
            // ServerIdWaitComplete/FontLoadWaitComplete；直连 openDocument 不经 Gateway
            // dummy-coauth 链与 FontLoader 完成链 → 后两闸恒 false → 空白网格）。
            // asyncServerIdEndLoaded 幂等（置 SIdW + 重入回调，等价 dummy 语义，无网络）；
            // _loadFonts([]) 空队列走 FontLoader 完成回调置 FontLoadWaitComplete（字体已缓存）。
            if (e8) {
              try {
                if (!e8.ServerIdWaitComplete && typeof e8.asyncServerIdEndLoaded === 'function') {
                  e8.asyncServerIdEndLoaded(); if (_pf.length < PFLIM) _pf.push('sIdW:kick');
                }
                if (!e8.FontLoadWaitComplete && typeof e8._loadFonts === 'function') {
                  e8._loadFonts([], function () { if (_pf.length < PFLIM) _pf.push('flw:ok'); });
                }
                // cell 视图重绘（打开末端）：DEOC 已建 WorkbookView（ws=3），wb.resize() 触发
                // drawWorksheet（_canResize 分支 + drawWorksheet else 兜底）；zoom 异常
                // 100000%（localStorage sse-last-zoom 被污染）强制回 100%。
                // 注意 webapps contentReady 还会再读 localStorage（污染值 100000→zf=1000），
                // 故删键 + 3s 后再强制 zoom/resize 一次（contentReady 之后）。
                try { ['sse-last-zoom', 'sse-settings-zoom'].forEach(function (k) { try { localStorage.removeItem(k); } catch (zz) { } }); } catch (zz2) {}
                if (e8.wb && typeof e8.wb.resize === 'function') { try { e8.wb.resize(null); if (_pf.length < PFLIM) _pf.push('wb:resize'); } catch (_wr) {} }
                try { if (typeof e8.asc_setZoom === 'function') e8.asc_setZoom(1); } catch (_zz) {}
                try { if (typeof e8.asc_Resize === 'function') e8.asc_Resize(); } catch (_rz) {}
                setTimeout(function () {
                  try { if (typeof e8.asc_setZoom === 'function') e8.asc_setZoom(1); } catch (_z1) {}
                  if (e8.wb && typeof e8.wb.resize === 'function') { try { e8.wb.resize(null); if (_pf.length < PFLIM) _pf.push('wb2:resize'); } catch (_w2) {} }
                  try { if (typeof e8.asc_Resize === 'function') e8.asc_Resize(); } catch (_r2) {}
                }, 3000);
              } catch (_se) { if (_pf.length < PFLIM) _pf.push('sIdW:ERR:' + String(_se && _se.message)); }
            }
          } catch (x5) { _pf.push('p5:ERR:' + String(x5 && (x5.message || x5) || x5).slice(0, 120)); }
        } catch (x2) { _pf.push('ood:ERR:' + String(x2 && (x2.message || x2) || x2).slice(0, 200)); }
      };
      function __isPK(d) {
        try {
          var u = (d && d.buffer) ? new Uint8Array(d.buffer, d.byteOffset || 0, d.byteLength) : null;
          if (!u || u.length < 4) return false;
          return u[0] === 0x50 && u[1] === 0x4B && u[2] === 0x03 && u[3] === 0x04;
        } catch (e) { return false; }
      }
      function hookEditor(ed) {
        if (!ed || ed.__podd2 || !ed.openDocument) return;
        ed.__podd2 = 1;
        if (_pf.length < PFLIM) _pf.push('edT:' + (ed.constructor ? ed.constructor.name : '?') + ';od=' + (ed.openDocument && ed.openDocument.name ? ed.openDocument.name : '?') + '|' + String(ed.openDocument).slice(0, 30));
        var _od = ed.openDocument;
        try {
          var _A3 = window.AscCommon;
          if (_A3 && _A3.PDFEditorApi)
            if (_pf.length < PFLIM) _pf.push('edF:odIsPdfW=' + (_od === _A3.PDFEditorApi.prototype.openDocument) + ';pdfF=' + String(_A3.PDFEditorApi.prototype.openDocument).slice(0, 36) + ';odF=' + String(_od).slice(0, 36));
        } catch (e9) {}
        ed.openDocument = function(f) {
          try {
            var r = hookOpenDoc(this, f);
            if (r !== undefined) return r;
          } catch (e) { _pf.push('odERR:' + (e && e.message) + '|STK:' + String((e && e.stack) || '').slice(0, 600)); throw e; }
          return _od.apply(this, arguments);
        };
      }
      // 公共拦截：PK 字节 + 桥就绪 → 转内部格式（undefined=放行原实现）
      function hookOpenDoc(_this, f) {
        _pf.push('od:' + (f && f.bSerFormat) + '|' + (typeof f.data) + '|' + String(f.data || '').slice(0, 6) + '|' + (f && f.url));
        _pf.push('odWC:' + (_this && _this.WordControl ? 'obj' : (typeof _this === 'object' ? 'oth' : 'nul')));
        try { console.error('ODX bser=' + (f && f.bSerFormat) + ' dt=' + (typeof (f && f.data)) + ' head=' + String(f && f.data && f.data.slice ? f.data.slice(0, 6) : String((f && f.data) || '').slice(0, 6)).replace(/[,/]/g, '-')); } catch (_oe) {}
        // 实例/Api 身份诊断：谁在跑 openDocument、Asc.asc_docs_api 是否被 PDFEditorApi 覆盖
        try {
          var _pi = _this && _this.constructor ? _this.constructor.name : 'na';
          var _pp = Object.getPrototypeOf(_this);
          var _pnn = _pp && _pp.constructor ? _pp.constructor.name : 'na';
          var _A2 = window.Asc, _AC2 = window.AscCommon;
          var _an = _A2 && _A2.asc_docs_api ? _A2.asc_docs_api.name : 'na';
          var _de = _AC2 && _AC2.DocumentEditorApi ? _AC2.DocumentEditorApi.name : 'na';
          var _pdf = _AC2 && _AC2.PDFEditorApi ? _AC2.PDFEditorApi.name : 'na';
          var _eq1 = _A2 && _AC2 ? (_A2.asc_docs_api === _AC2.PDFEditorApi) : 'na';
          var _eq2 = _A2 && _AC2 ? (_A2.asc_docs_api === _AC2.DocumentEditorApi) : 'na';
          var _ip = _this && _AC2 && _AC2.PDFEditorApi ? (_this instanceof _AC2.PDFEditorApi) : 'na';
          var _p1 = Object.getPrototypeOf(_pp) || null;
          var _p2 = _p1 ? Object.getPrototypeOf(_p1) : null;
          var _n1 = _p1 && _p1.constructor ? _p1.constructor.name : '?-';
          var _n2 = _p2 && _p2.constructor ? _p2.constructor.name : '?-';
          if (_pf.length < PFLIM) _pf.push('odT:ctor=' + _pi + ';pp=' + _pnn + ';L1=' + _n1 + ';L2=' + _n2 + ';ada=' + _an + ';DEA=' + _de + ';PDEA=' + _pdf + ';adaEqP=' + _eq1 + ';adaEqD=' + _eq2 + ';isPdf=' + _ip);
          try {
            var _stk = String(new Error().stack || '').split(String.fromCharCode(10)).slice(0, 7).join('~').replace(/[|,]/g, '_');
            if (_pf.length < PFLIM) _pf.push('odS:' + _stk.slice(0, 560));
          } catch (e8) {}
        } catch (_te) { if (_pf.length < PFLIM) _pf.push('odT:ERR:' + String((_te && _te.message) || _te).slice(0, 80)); }

        // docx/xlsx/pptx 的 PK 字节且转换桥就绪：转内部二进制（docx->DOCY / xlsx->XLSY /
        // pptx->PPTY 由 ext 决定 x2t 转换器），交回 __oobDocy 走 OpenDocumentFromBin。
        // 注意 PK 检测自实现：AscCommon.checkOOXMLSignature 仅 word 侧存在（cell/slide
        // 无 AscCommon.checkOOXMLSignature → 拦截屏障恒 false → zip 直喂 sdk）。
        if (f && !f.bSerFormat && f.data && typeof f.data === 'object'
            && __isPK(f.data)
            && window.AscConvertBridge && window.AscConvertBridge.convert) {
          var _d = f.data;
          var _u8 = new Uint8Array(_d.byteLength !== undefined ? _d : _d.buffer);
          _pf.push('ood:docx len=' + _u8.length + ' ext=' + (window.__docType || '?'));
          window.AscConvertBridge.convert(ascAbToB64(_u8), window.__docType || 'docx');
          return null;
        }
        return undefined;
      }
      // 原型级 hook：Webapps Viewport.getApi() 的实例与 window.Asc.editor 可能不是同一
      // 对象（cell/slide 实测 onEndLoadFile→openDocument 未过实例 hook），挂在
      // AscCommon.*EditorApi.prototype.openDocument 上通吃（遍历 AscCommon 全部原型）。
      function hookProtoOpen() {
        var AC = window.AscCommon;
        if (!AC) return;
        var targets = [];
        if (AC.baseEditorsApi && AC.baseEditorsApi.prototype) targets.push(AC.baseEditorsApi.prototype);
        var _seen = {};
        var _k;
        for (_k in AC) {
          try {
            if (!_seen[_k] && AC[_k] && AC[_k].prototype
                && typeof AC[_k].prototype.openDocument === 'function') {
              _seen[_k] = 1; targets.push(AC[_k].prototype);
            }
          } catch (e) {}
        }
        for (var i = 0; i < targets.length; ++i) {
          var P = targets[i];
          if (!P.openDocument || P.openDocument.__pd2H) continue;
          // 修复候选：PDFEditorApi 属 pdfviewer 专用，绝不参与 docx/xlsx/pptx 打开链；
          // ed（asc_docs_api 实例）曾命中 PDF 包装（hpC:PDFEditorApi 实测）——跳过之
          if (P.constructor && P.constructor.name === 'PDFEditorApi') continue;
          var _od2 = P.openDocument;
          var _pname = P.constructor ? P.constructor.name : '?';
          if (_pf.length < PFLIM) _pf.push('hpX:' + _pname + ';od2=' + String(_od2).slice(0, 30));
          P.openDocument = function (f) {
            if (_pf.length < PFLIM) _pf.push('hpC:' + _pname + ';od2=' + String(_od2).slice(0, 26));
            try {
              var r = hookOpenDoc(this, f);
              if (r !== undefined) return r;
            } catch (e) { _pf.push('odP_ERR:' + String((e && e.message) || e).slice(0, 300)); }
            return _od2.apply(this, arguments);
          };
          P.openDocument.__pd2H = 1;
          if (_pf.length < PFLIM) _pf.push('hp:' + i + ';' + (P.constructor ? P.constructor.name : '?') + ';f=' + (_od2.name || '?') + '|' + String(_od2).slice(0, 220).replace(/[|,\)]/g, '~'));
        }
      }
      function hookOnLoadModule() {
        var AF = window.AscFonts;
        if (!AF || AF.__hooked || typeof AF.onLoadModule !== 'function') return;
        AF.__hooked = 1;
        var _olm = AF.onLoadModule;
        AF.onLoadModule = function () {
          _pf.push('olm');
          // Asc.editor 与 window.editor 可能指向不同实例（cell/slide 实测直连 open 未走
          // 拦截=挂在错误引用上），两侧全挂（hookEditor 带 _podd2 幂等防重）
          hookEditor(window.Asc && window.Asc.editor);
          hookEditor(window.editor);
          hookSendEvent();
          return _olm.apply(this, arguments);
        };
        // 轮询兜底：AscFonts.onLoadModule 触发时刻两个全局可能尚未绑定（cell/slide 时序不同），
        // 800ms 持续将后出现的 editor 实例 hook（幂等，_podd2 标志防重）
        try { setInterval(function () { hookEditor(window.Asc && window.Asc.editor); hookEditor(window.editor); }, 800); } catch (e) {}
      }
      function hookCheckSig() {
        var AC = window.AscCommon;
        if (!AC || AC.__csP || typeof AC.checkStreamSignature !== 'function') return;
        AC.__csP = 1;
        var _f = AC.checkStreamSignature;
        AC.checkStreamSignature = function(st, sg) {
          var r = _f.call(this, st, sg);
          _pf.push('sig:' + String(st || '').slice(0, 6) + '=' + r);
          return r;
        };
      }
      // v47: 字体加载链 hook —— SFI/AF/MLF/FTO/FBS 五打点定位 m_pFont=null 断环。
      // 链: SetFontInternal(SFI) -> g_fontApplication.LoadFont(AF) -> CFontInfo.LoadFont
      //      -> CFontManager.LoadFont(MLF, LockFont) -> CFontFilesCache.LoadFontFile
      //      -> FT_Open_Face(FTO) -> CFontFile(m_pFaceInfo)
      function hookFontChain() {
        var AF = window.AscFonts, AC = window.AscCommon;
        if (!AC || !AF || !AF.CFontManager || !AF.g_fontApplication) return;
        if (AF.CFontManager.prototype.LoadFont && !AF.CFontManager.prototype.LoadFont.__h) {
          var _old1 = AF.CFontManager.prototype.LoadFont;
          AF.CFontManager.prototype.LoadFont = function(fontFile, faceIndex, size, isBold, isItalic, needB, needI, isNoSetupToManager) {
            var _si = fontFile ? (fontFile.stream_index !== undefined ? fontFile.stream_index : 'undef') : 'NF';
            if (_pf.length < PFLIM) _pf.push('MLF:in:' + String(fontFile ? String(fontFile.Id || '').slice(-16) : 'NF') + '#' + _si + '#' + faceIndex + '#' + size);
            var _r = _old1.apply(this, arguments);
            var _has = (AF.g_fonts_streams && AF.g_fonts_streams[_si]) ? 'Y' : 'N';
            if (_pf.length < PFLIM) _pf.push('MLF:out:' + (!!_r ? 'Y' : 'N') + '#sx' + _has);
            return _r;
          };
          AF.CFontManager.prototype.LoadFont.__h = 1;
        }
        if (AF.FT_CreateLibrary && !AF.FT_CreateLibrary.__h) {
          var _fc = AF.FT_CreateLibrary;
          AF.FT_CreateLibrary = function() {
            var _r = _fc.apply(null, arguments);
            if (_pf.length < PFLIM) _pf.push('FCL:' + String(_r));
            return _r;
          };
          AF.FT_CreateLibrary.__h = 1;
        }
        if (AF.FT_Open_Face && !AF.FT_Open_Face.__h) {
          // v47 实证：FT_Open_Face 返回 null 且 stream 存在。v48 增强：区分 FCL(library)
          // /FTOe(engine 包装层 args: lib, stream, face) /FTO2(wasm 导出真参 lib,data,len,face)。
          var _f2 = AF.FT_Open_Face;
          AF.FT_Open_Face = function(lib, st, faceIndex) {
            var _r = _f2.apply(null, arguments);
            var _d = '?';
            try { _d = (st && st.asc_marker) ? 'M' : (st && st.data && st.data.length !== undefined ? 'A' : (st && st.data ? 'P' : '?')); } catch (e2) {}
            var _h = '';
            if (!_r) {
              try {
                if (st && st.asc_marker && st.data) {
                  var _u8 = AscFonts.GetUint8ArrayFromPointer(st.data, Math.min(8, st.len));
                  var _hb = [];
                  for (var i6 = 0; i6 < _u8.length; ++i6) _hb.push(('0' + _u8[i6].toString(16)).slice(-2));
                  _h = _hb.join('');
                } else if (st && st.data && st.data.length !== undefined) {
                  var _hb2 = [];
                  for (var i8 = 0; i8 < Math.min(8, st.data.length); ++i8) _hb2.push(('0' + st.data[i8].toString(16)).slice(-2));
                  _h = _hb2.join('');
                } else { _h = 'p0'; }
              } catch (e3) { _h = 'E:' + String(e3.message || e3).slice(0, 20); }
            }
            if (_pf.length < PFLIM) _pf.push('FTOe:' + (!!_r ? 'Y' : 'N') + '#' + faceIndex + '#' + (st && st.len !== undefined ? st.len : '?') + '#' + _d + '#L' + String(lib === undefined ? '' : lib) + '#h' + _h);
            return _r;
          };
          AF.FT_Open_Face.__h = 1;
        }
        if (AF.FT_Open_Face2 && !AF.FT_Open_Face2.__h) {
          var _f2b = AF.FT_Open_Face2;
          AF.FT_Open_Face2 = function(lib, data, len, faceIndex) {
            var _r = _f2b.apply(null, arguments);
            if (_pf.length < PFLIM) _pf.push('FTO2:' + (!!_r ? 'Y' : 'N') + '#' + len + '#' + faceIndex + '#L' + String(lib));
            return _r;
          };
          AF.FT_Open_Face2.__h = 1;
        }
        if (AF.g_fontApplication.LoadFont && !AF.g_fontApplication.LoadFont.__h) {
          var _f3 = AF.g_fontApplication.LoadFont;
          AF.g_fontApplication.LoadFont = function() {
            var _n = String(arguments[0]);
            if (_pf.length < PFLIM) _pf.push('AF:in:' + _n.slice(0, 24));
            var _r = _f3.apply(this, arguments);
            if (_pf.length < PFLIM) _pf.push('AF:out:' + (!!_r ? 'Y' : 'N') + ':' + _n.slice(0, 24));
            return _r;
          };
          AF.g_fontApplication.LoadFont.__h = 1;
        }
        var _tm = AC.g_oTextMeasurer;
        if (_tm && _tm.SetFontInternal && !_tm.SetFontInternal.__h) {
          var _f4 = _tm.SetFontInternal;
          _tm.SetFontInternal = function() {
            var _n = String(arguments[0]);
            var _had = this.m_oManager && this.m_oManager.m_pFont ? 'Y' : 'N';
            if (_pf.length < PFLIM) _pf.push('SFI:' + _n.slice(0, 20) + '#' + String(arguments[1]) + '#' + String(arguments[2]) + '>m' + _had);
            var _r = _f4.apply(this, arguments);
            if (_pf.length < PFLIM) _pf.push('SFI:out:' + (!!_r ? 'Y' : 'N') + '>m' + (this.m_oManager && this.m_oManager.m_pFont ? 'Y' : 'N'));
            return _r;
          };
          _tm.SetFontInternal.__h = 1;
        }
        if (_tm && _tm.GetFontBySymbol && !_tm.GetFontBySymbol.__h) {
          var _f5 = _tm.GetFontBySymbol;
          _tm.GetFontBySymbol = function() {
            var _r = _f5.apply(this, arguments);
            var _mf = this.m_oManager && this.m_oManager.m_pFont;
            if (!_mf && _pf.length < PFLIM) {
              var _st = '?';
              try { _st = String(new Error().stack || '').split(String.fromCharCode(10)).slice(1, 6).join('|').slice(0, 340); } catch (e) {}
              _pf.push('FBS:np#' + String(arguments[0]) + '#' + _st);
            }
            return _r;
          };
          _tm.GetFontBySymbol.__h = 1;
        }
      }
      // 轮询：loader.js 在 window.AscFonts 赋值后才定义 onLoadModule，
      // 且 fonts.js 是 appendChild 异步加载——400ms 内 hook 远早于 wasm fetch 完成
      setInterval(function () { hookProto(); hookOnLoadModule(); hookCheckSig(); hookAFDbg(); hookFontChain(); hookProtoOpen(); }, 400);
    })();
    </script>'''
    # 诊断探针：每 3s console.log 页面状态（POC 调试用，onConsole 转发到 hilog）
    probe = '''
    <script>
    window.__probe = window.setInterval(function() {
      try {
        var reqs = [];
        if (window.requirejs) {
          try {
            var ctx = (window.require && window.require.s && window.require.s.contexts) ? window.require.s.contexts["_"] : null;
            if (ctx && ctx.defined) { reqs = Object.keys(ctx.defined); }
          } catch (e) { reqs = ["ERR:" + e]; }
        }
        var vp = document.getElementById("viewport");
        var de = (window.DE && window.DE) || null;
        var gEl = document.documentElement;
        var out = { v: +(new URLSearchParams(location.search).get('v') || 0), t: document.title, rs: document.readyState,
          lb: gEl.getAttribute('data-lb') || '-',
          lc: gEl.getAttribute('data-lc') || '-',
          lm: gEl.getAttribute('data-lm') || '-',
          gi: gEl.getAttribute('data-gi') || '-',
          go: gEl.getAttribute('data-go') || '-',
          ls: gEl.getAttribute('data-ls') || '-',
          le: gEl.getAttribute('data-le') || '-',
          rc: gEl.getAttribute('data-rc') || '-',
          dl: gEl.getAttribute('data-dl') || '-',
          dr: gEl.getAttribute('data-dr') || '-',
          dcl: gEl.getAttribute('data-dcl') || '-',
          fet: gEl.getAttribute('data-fet') || '-',
          // Main/Viewport 打桩（data-m* / data-mv* 标记由 rawfile 副本 stub 写入）
          minit: gEl.getAttribute('data-minit') || '-',
          mlon: gEl.getAttribute('data-mlon') || '-',
          mapi0: gEl.getAttribute('data-mapi0') || '-',
          mapi1: gEl.getAttribute('data-mapi1') || '-',
          mlas0: gEl.getAttribute('data-mlas0') || '-',
          mlas1: gEl.getAttribute('data-mlas1') || '-',
          mlgw: gEl.getAttribute('data-mlgw') || '-',
          mappready: gEl.getAttribute('data-mappready') || '-',
          mcfg: gEl.getAttribute('data-mcfg') || '-',
          mload: gEl.getAttribute('data-mload') || '-',
          msdi: gEl.getAttribute('data-msdi') || '-',
          msdiOK: gEl.getAttribute('data-msdiOK') || '-',
          msdierr: gEl.getAttribute('data-msdierr') || '-',
          msgep: gEl.getAttribute('data-msgep') || '-',
          msgepOK: gEl.getAttribute('data-msgepOK') || '-',
          msgeprr: gEl.getAttribute('data-msgeprr') || '-',
          // v41：onEditorPermissions 链（license 关卡 / onServerVersion / asc_LoadDocument 到达）
          moep: gEl.getAttribute('data-moep') || '-',
          moepLic: gEl.getAttribute('data-moepLic') || '-',
          moepLicERR: gEl.getAttribute('data-moepLicERR') || '-',
          molgT: gEl.getAttribute('data-molgT') || '-',
          mosv: gEl.getAttribute('data-mosv') || '-',
          moll: gEl.getAttribute('data-moll') || '-',
          mld2: gEl.getAttribute('data-mld2') || '-',
          mld2OK: gEl.getAttribute('data-mld2OK') || '-',
          mld2ERR: gEl.getAttribute('data-mld2ERR') || '-',
          mshp: gEl.getAttribute('data-mshp') || '-',
          mvlaunch: gEl.getAttribute('data-mvlaunch') || '-',
          mvas0: gEl.getAttribute('data-mvas0') || '-',
          mvas1: gEl.getAttribute('data-mvas1') || '-',
          mvaserr: gEl.getAttribute('data-mvaserr') || '-',
          // offline 链运行时值
          off: (window.AscCommon ? JSON.stringify(window.AscCommon.offlineMode) : '-'),
          diof: (window.Asc && window.Asc.editor && window.Asc.editor.DocInfo) ? String(window.Asc.editor.DocInfo.get_OfflineApp()) : '-',
          surl: (window.Asc && window.Asc.editor && window.Asc.editor.CoAuthoringApi && window.Asc.editor.CoAuthoringApi._CoAuthoringApi) ? JSON.stringify(window.Asc.editor.CoAuthoringApi._CoAuthoringApi._url) : '-',
          de: (typeof window.DE), deEd: de ? (window.DE.editor ? 1 : 0) : -1,
          cm: (typeof window.Common),
          asc: (typeof window.Asc), ed: (window.Asc && window.Asc.editor) ? 1 : 0,
          vk: vp ? vp.childElementCount : -1,
          vt: (vp && vp.children.length) ? vp.children[0].className : "",
          toolbar: !!document.querySelector(".toolbar"),
          mask: !!document.querySelector("#loading-mask"),
          reqn: reqs.length,
          // pf 单条超 hilog console 上限（4000）会被截断（v42 实测 pf=4635 尾部丢失），
          // 故 pf 独立拆成多段行 PFO_P1/P2/P3 输出，每段 <=2000 字符。
          pfL: (window.__pf || []).length,
          pfH: (function() { var _t = (window.__pf || []).join('|'); return _t.length > 2000 ? 'TR:' + _t.length + ':' + _t.slice(0, 2000) : _t; })() };
        var _pft = (window.__pf || []).join('|');
        var _pfp = function (s, a, b) { return a >= s.length ? '' : s.slice(a, Math.min(b, s.length)); };
        var _i;
        for (_i = 1; _i <= 7; ++_i) {
          console.log("PFO_P" + _i + " " + JSON.stringify({ pfM: _pfp(_pft, 2000 * _i, 2000 * (_i + 1)) }));
        }
        console.log("PROBE " + JSON.stringify(out));
      } catch (e) { console.log("PROBE_ERR " + String(e && e.message)); }
    }, 3000);
    </script>'''
    # 翻译核心：apps/common/locale.js 定义 Common.Locale 并立即
    # fetch('locale/'+lang+'.json')（相对页面目录 documenteditor/main/，
    # validate 键 DE.Controllers.Main.txtHyperlink 等写入全局树）。
    # 必须在 <script data-main="app_dev">（require 异步加载）之前同步加载，
    # 否则 app_dev.js 调 Common.Locale.apply 时报 TypeError。
    # locale 目录此前只拷 'en-US' 子目录而源树是 en.json 文件，导致翻译表为空 ->
    # txtHyperlink=undefined -> getValue("Hyperlink")=undefined -> toLowerCase 崩溃。
    locale_js = '<script src="../../common/locale.js"></script>'
    html = html.replace(
        '<script type="text/javascript" src="../../../vendor/jquery/jquery.min.js"></script>',
        locale_js + '\n    <script type="text/javascript" src="../../../vendor/jquery/jquery.min.js"></script>\n    '
        + hook.replace('__FONT_FILES_JSON__', json.dumps(FONT_FILES))
               .replace('__FONT_INFOS_JSON__', json.dumps(FONT_INFOS))
        + '\n    ' + probe)

    # 预编译 CSS（precompile_css 成功时）：less link -> 静态 app.css，去掉 less.js（运行时编译在
    # 真机 WebView 上不可靠——截图证明裸 DOM 无样式）。失败时保留 less 链接（运行时兜底）。
    if use_css:
        html = html.replace(
            '<link rel="stylesheet/less" type="text/css" href="resources/less/app.less" />',
            '<link rel="stylesheet" type="text/css" href="resources/css/app.css" />')
        html = html.replace(
            '<script type="text/javascript">var less=less||{};less.env=\'development\';less.async=true;</script>',
            '<!-- css precompiled to resources/css/app.css -->')
        html = html.replace(
            '<script src="../../../vendor/less/dist/less.js" type="text/javascript"></script>',
            '')

    html = make_gateway_launch(html, doc_type)

    os.makedirs(os.path.dirname(dst_index), exist_ok=True)
    with open(dst_index, 'w', encoding='utf-8') as f:
        f.write(html)


def make_gateway_launch(html: str, doc_type: str = 'word') -> str:
    """本地静态页面没有 document server 驱动 Gateway，故在 app 启动后自行
    触达 Common.Gateway.init/openDocument。这是 B 架构中 native 侧要点：
    打开文档 = 页面就绪后调用这两个事件（后续由原生桥注入调用）。
    doc_type: word->documentType 'word'/fileType 'docx'；spreadsheet/presentation 同构。"""
    doc_type_map = {
        'word': ('word', 'docx'),
        'spreadsheet': ('spreadsheet', 'xlsx'),
        'presentation': ('presentation', 'pptx'),
    }
    dt, ft = doc_type_map.get(doc_type, ('word', 'docx'))
    launch = '''
    <script>
    (function() {
      var cfg = {
        mode: 'edit', lang: 'en-US', type: 'desktop',
        user: { id: 'uid-poc-1', name: 'POC User', email: 'poc@localhost' },
        coEditing: false, documentType: '__DOC_TYPE__',
        customization: { close: false, feedback: false },
        canRequestOpen: false, canRequestSaveAs: false,
        canRequestCreateNew: false
      };
      // url='_offline_'（AscCommon.offlineMode）：无服务器离线打开（dummy coauthoring+license）。
      // 真文件打开由页面 autotest/打开按钮调用 OOHost.open(sample.<type>) 走 PK→x2t→Uint8Array 打开弧；
      // 在线真文件 url 打开会卡无文档服务器（surl=null，实测）。
      var doc = {
        key: 'poc-hi-harmony',
        title: 'Hello HarmonyOS',
        url: '_offline_',
        fileType: '__FILE_TYPE__',
        permissions: { edit: true, review: true, comment: true },
        options: {}
      };
      document.documentElement.setAttribute('data-lb', '1'); // launch boot marker
      // 消息管线探查：postMessage 事件是否到达 & Gateway 命令是否 trigger
      window.addEventListener('message', function(e) {
        var g = document.documentElement;
        try {
          var d = JSON.parse(e.data);
          if (d && d.command) g.setAttribute('data-lm', (g.getAttribute('data-lm') || '') + ',' + d.command);
        } catch (x) {}
      });
      var __lct = 0;
      function launch() {
        if (window.__gateway_launched) return;
        document.documentElement.setAttribute('data-lc', String(++__lct));
        if (__lct % 10 === 1) {
          console.log('LAUNCH_TICK ' + JSON.stringify({
            gw: !!(window.Common && Common.Gateway), de: !!window.DE,
            asc: !!window.Asc, ed: !!(window.Asc && window.Asc.editor)
          }));
        }
        // 注意：等待条件勿含 window.DE——DE 仅 DesktopEditors 原生渲染进程注入，
        // WebView 环境永远不存在（LAUNCH_TICK de:false），会导致 init 永不发出、
        // loadConfig 不执行、toolbar/UI 永不构建（实测：模型可直连加载但页面无 UI）。
        if (!(window.Common && Common.Gateway && window.Asc && window.Asc.editor)) {
          window.setTimeout(launch, 500);
          return;
        }
        window.__gateway_launched = true;
        try {
          // sdk 文档加载回调探针（必须在 asc_setDocInfo 前注册）
          var ed = window.Asc.editor;
          if (ed && ed.asc_registerCallback && !document.documentElement.getAttribute('data-rc')) {
            document.documentElement.setAttribute('data-rc', '1');
            ed.asc_registerCallback('asc_onDocumentContentReady', function() { document.documentElement.setAttribute('data-dl', '1'); }); // dl=contentReady
            ed.asc_registerCallback('asc_onDocumentModifiedChanged', function() { document.documentElement.setAttribute('data-dm', '1'); });
            ed.asc_registerCallback('asc_onDocumentClose', function() { document.documentElement.setAttribute('data-dcl', '1'); });
          }
          // 页面内 fetch 探针：验证 rawfileLoader 对 docx 的响应
          if (!document.documentElement.getAttribute('data-fet')) {
            document.documentElement.setAttribute('data-fet', 'pending');
            fetch('http://localhost/onlyoffice/document.docx', { method: 'GET' })
              .then(function(r) { document.documentElement.setAttribute('data-fet', 'st:' + r.status); })
              .catch(function() { document.documentElement.setAttribute('data-fet', 'err'); });
          }
          // 先挂命令钩子再发消息（消息为异步事件，钩子必先就位）
          if (window.Common && Common.Gateway && Common.Gateway.on) {
            Common.Gateway.on('init', function() { document.documentElement.setAttribute('data-gi', '1'); });
            Common.Gateway.on('opendocument', function() { document.documentElement.setAttribute('data-go', '1'); });
          }
          // Gateway 由 window.postMessage 事件协议驱动（Gateway.js _onMessage）。
          // init + opendocument 都发：loadDocument 是 webapps UI 链（toolbar/Viewport）的
          // 构建入口——只直连 openDocument（旁路）模型可载但 UI 永不构建（实测 toolbar:false 全程）。
          // 文档用 _offline_（offlineMode，无服务器 dummy coauth）；真实 http url 会走
          // 在线 coauthenticating（surl=null）→ CoAuthoringDisconnect 循环（实测）。
          window.postMessage(window.JSON.stringify({ command: 'init', data: { config: cfg } }), '*');
          // 必须发空文档 openDocument（_offline_）：Gateway loadDocument 是 webapps UI 链
          // （toolbar/状态栏/画布容器）的构建入口；只 init 会 toolbar:false + view 不建
          // （实测三按钮同类问题：UI 不全、数据不画）。真实文件由 autotest/OOHost.open
          // 走 loadBinary（openDocumentFromBinary）随后替换（word 已验证全渲染）。
          window.postMessage(window.JSON.stringify({ command: 'openDocument', data: { doc: doc } }), '*');
          document.documentElement.setAttribute('data-ls', '1'); // gateway sent
        } catch (e) { document.documentElement.setAttribute('data-le', '1'); }
      }
      launch();
    })();
    </script>'''
    return html.replace('</body>', launch.replace('__DOC_TYPE__', dt).replace('__FILE_TYPE__', ft) + '</body>')


def stub_loadbinary():
    """三个编辑器 Main.js 的 loadBinary 打执行标记（诊断：openDocumentFromBinary→loadBinary
    是否真正分发；POC 用，正式化删除）。"""
    for page in ('documenteditor', 'spreadsheeteditor', 'presentationeditor'):
        p = os.path.join(DST_WEB, 'apps', page, 'main', 'app', 'controller', 'Main.js')
        if not os.path.isfile(p):
            continue
        with open(p, 'r', encoding='utf-8') as f:
            t = f.read()
        old = 'loadBinary: function(data) {'
        if old not in t:
            print('stub_loadbinary: %s (loadBinary not found)' % p)
            continue
        # 修 loadBinary 数据形态 + 诊断：Gateway trigger 数组展开 → 发 {bytes:arr} 包装对象。
        # PK 拦截：cell/slide 实例有 own openDocument（原型 hook 拦不到，OELF2 hooked=NO 实测），
        # PK 直进 OpenDocumentFromZip 空模型 → 统一在 loadBinary 层把 PK 交给 x2t 转换
        # （与 openDocument hook 同逻辑：PK → *_bin → __oobDocy Uint8Array 回投）；
        # 转换桥缺失（降级）时保持原 asc_openDocumentFromBytes 行为。
        new = ('loadBinary: function(data) {'
               ' var _bytes = (data && data.bytes !== undefined) ? data.bytes : data;'
               ' try { console.error("LBIN called len=" + (_bytes && _bytes.length) + " type=" + Object.prototype.toString.call(_bytes) + " head=" + ((_bytes ? Array.prototype.slice.call(_bytes, 0, 8) : []).join(","))); } catch(__e) {}'
               ' document.documentElement.setAttribute("data-lbin","1");'
               ' try {'
               '   if (_bytes && _bytes.length >= 6 && _bytes[0] === 0x50 && _bytes[1] === 0x4B && _bytes[2] === 0x03 && _bytes[3] === 0x04'
               '       && window.AscConvertBridge && window.AscConvertBridge.convert) {'
               '     var _u8 = new Uint8Array(_bytes);'
               '     var _s8 = ""; for (var _i8 = 0; _i8 < _u8.length; ++_i8) _s8 += String.fromCharCode(_u8[_i8]);'
               '     window.AscConvertBridge.convert(window.btoa(_s8), window.__docType || "xlsx"); return;'
               '   }'
               ' } catch (__p) { try { console.error("LBIN_CONV_ERR " + String(__p)); } catch (__z) {} }'
               ' _bytes && this.api.asc_openDocumentFromBytes(new Uint8Array(_bytes)); return;')
        t = t.replace(old, new, 1)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(t)
    print('stub_loadbinary: done')


def stub_cell_api():
    """cell/slide api.js 的 _openDocumentEndCallback 打点（xlsx 打开链诊断）：
    三重 guard 实际值 + wbModel worksheet 计数 + WorkbookView 创建。POC 用删除。"""
    for page, marker in (('spreadsheeteditor', 'cell'), ('presentationeditor', 'slide')):
        p = os.path.join(DST_WEB, 'apps', page, 'main', 'app', 'controller', 'Main.js')
        _ = p  # 占位说明：cell api.js 在 sdkjs 树
        for cand in (os.path.join(DST_SDK, 'cell', 'api.js'),):
            if not os.path.isfile(cand):
                continue
            with open(cand, 'r', encoding='utf-8') as f:
                t = f.read()
            if t.count('_openDocumentEndCallback = function ()') < 1:
                continue
            if t.count('spreadsheet_api.prototype._applyFirstLoadChanges = function()') >= 1:
                old_a = "spreadsheet_api.prototype._applyFirstLoadChanges = function() {\n    if (this.isDocumentLoadComplete) {"
                new_a = ("spreadsheet_api.prototype._applyFirstLoadChanges = function() {\n"
                         "    try { console.error('AFC enter doc=' + this.isDocumentLoadComplete + ' ce=' + (this.collaborativeEditing ? 'obj' : 'nul') + ' ws=' + (this.wbModel && this.wbModel.getWorksheetCount ? this.wbModel.getWorksheetCount() : '?')); } catch (__e1) {}\n"
                         "    if (this.isDocumentLoadComplete) {")
                if old_a in t:
                    t = t.replace(old_a, new_a, 1)
            # 二次打开修复：openDocument 入口重置完成标志（让 _openDocumentEndCallback 可重入，
            # loadBinary 加载真实文件后重建 WorkbookView —— cell 单机二次打开语义补全）
            old_od = "spreadsheet_api.prototype.openDocument = function(file) {\n\t//todo native.js -> openDocument"
            new_od = ("spreadsheet_api.prototype.openDocument = function(file) {\n"
                      "\tthis.isDocumentLoadComplete = false;\n"
                      "\tthis.isLoadFileFailed = false;\n"
                      "\tthis._reopen = true;\n"
                      "\t//todo native.js -> openDocument")
            if old_od in t:
                t = t.replace(old_od, new_od, 1)
                print('stub_cell_api: reopen-reset patched in cell api.js')
            old = "\tspreadsheet_api.prototype._openDocumentEndCallback = function () {\n\t\t// Don't initialize twice\n\t\tif (this.isDocumentLoadComplete || !this.ServerIdWaitComplete || !this.FontLoadWaitComplete) {"
            new = ("\tspreadsheet_api.prototype._openDocumentEndCallback = function () {\n\t\t"
                   "try { console.error('DEOC enter doc=' + this.isDocumentLoadComplete + ' sIdW=' + this.ServerIdWaitComplete + ' flw=' + this.FontLoadWaitComplete + ' ws=' + (this.wbModel && this.wbModel.getWorksheetCount ? String(this.wbModel.getWorksheetCount()) : '?')); } catch (__e0) {}\n"
                   "\t\t// Don't initialize twice\n\t\t"
                   "if (!this.ServerIdWaitComplete || !this.FontLoadWaitComplete) {")
            if old in t:
                t = t.replace(old, new, 1)
                with open(cand, 'w', encoding='utf-8') as f:
                    f.write(t)
                print('stub_cell_api: %s patched' % cand)
                break
    print('stub_cell_api: done')


def stub_mainjs():
    """对 rawfile 副本 Main.js 打关卡标记（POC 诊断用，源树 third_party 不动）：
    data-minit/mcfg/mload/msdi/msgep/mshp 分别标记：
    Backbone controller initialize 执行 -> Gateway.on 绑定
    loadConfig/loadDocument 执行 -> asc_setDocInfo/asc_getEditorPermissions 调用 -> hidePreloader"""
    p = os.path.join(DST_WEB, 'apps', 'documenteditor', 'main', 'app', 'controller', 'Main.js')
    with open(p, 'r', encoding='utf-8') as f:
        t = f.read()
    STUBS = [
        ('initialize: function() {',
         'initialize: function() { document.documentElement.setAttribute("data-minit","1");'),
        ('onLaunch: function() {',
         'onLaunch: function() { document.documentElement.setAttribute("data-mlon","1");'),
        ('this.api = this.getApplication().getController(\'Viewport\').getApi();',
         'document.documentElement.setAttribute("data-mapi0","1"); this.api = this.getApplication().getController(\'Viewport\').getApi(); document.documentElement.setAttribute("data-mapi1","1");'),
        ('Common.Controllers.LaunchController.init(this.api);',
         'document.documentElement.setAttribute("data-mlas0","1"); Common.Controllers.LaunchController.init(this.api); document.documentElement.setAttribute("data-mlas1","1");'),
        ('Common.Gateway.on(\'init\',',
         'document.documentElement.setAttribute("data-mlgw","1"); Common.Gateway.on(\'init\','),
        ('Common.Gateway.appReady();',
         'document.documentElement.setAttribute("data-mappready","1"); Common.Gateway.appReady();'),
        ('loadConfig: function(data) {',
         'loadConfig: function(data) { document.documentElement.setAttribute("data-mcfg","1");'),
        ('loadDocument: function(data) {',
         'loadDocument: function(data) { document.documentElement.setAttribute("data-mload","1");'),
        ('this.api.asc_setDocInfo(docInfo);',
         'document.documentElement.setAttribute("data-msdi","1"); try { this.api.asc_setDocInfo(docInfo); document.documentElement.setAttribute("data-msdiOK","1"); } catch(__e) { document.documentElement.setAttribute("data-msdierr", String((__e && (__e.stack || __e.message)) || __e).slice(0, 400)); }'),
        ('this.api.asc_getEditorPermissions();',
         'document.documentElement.setAttribute("data-msgep","1"); try { this.api.asc_getEditorPermissions(); document.documentElement.setAttribute("data-msgepOK","1"); } catch(__e) { document.documentElement.setAttribute("data-msgeprr", String((__e && (__e.stack || __e.message)) || __e).slice(0, 400)); }'),
        # v41：onEditorPermissions 链路 —— licType / license 拦截 / onServerVersion / 到达 asc_LoadDocument
        ('onEditorPermissions: function(params) {',
         'onEditorPermissions: function(params) { document.documentElement.setAttribute("data-moep","1"); try { document.documentElement.setAttribute("data-moepLic", String(params && params.asc_getLicenseType ? params.asc_getLicenseType() : "?")); } catch(__e) { document.documentElement.setAttribute("data-moepLicERR", String((__e && (__e.stack || __e.message)) || __e).slice(0, 200)); }'),
        ('                if ( this.onServerVersion(params.asc_getBuildVersion()) || !this.onLanguageLoaded() ) return;',
         '                var _sv = this.onServerVersion(params.asc_getBuildVersion()); document.documentElement.setAttribute("data-mosv", String(_sv)); var _ll = this.onLanguageLoaded(); document.documentElement.setAttribute("data-moll", String(_ll)); if ( _sv || !_ll ) return;'),
        ('                if (Asc.c_oLicenseResult.Expired === licType || Asc.c_oLicenseResult.Error === licType || Asc.c_oLicenseResult.ExpiredTrial === licType ||',
         '                document.documentElement.setAttribute("data-molgT","1"); if (Asc.c_oLicenseResult.Expired === licType || Asc.c_oLicenseResult.Error === licType || Asc.c_oLicenseResult.ExpiredTrial === licType ||'),
        ('                if ( this._isDocReady || this._isPermissionsInited ) {\n                    this.api.asc_LoadDocument();',
         '                if ( this._isDocReady || this._isPermissionsInited ) {\n                    document.documentElement.setAttribute("data-mld2","1"); try { this.api.asc_LoadDocument(); document.documentElement.setAttribute("data-mld2OK","1"); } catch(__e) { document.documentElement.setAttribute("data-mld2ERR", String((__e && (__e.stack || __e.message)) || __e).slice(0, 300)); }'),
        ('                this.api.asc_LoadDocument();\n            },\n\n            loadCoAuthSettings: function() {',
         '                document.documentElement.setAttribute("data-mld2","1"); try { this.api.asc_LoadDocument(); document.documentElement.setAttribute("data-mld2OK","1"); } catch(__e) { document.documentElement.setAttribute("data-mld2ERR", String((__e && (__e.stack || __e.message)) || __e).slice(0, 300)); }\n            },\n\n            loadCoAuthSettings: function() {'),
        ('hidePreloader: function() {',
         'hidePreloader: function() { document.documentElement.setAttribute("data-mshp","1");'),
    ]
    n = 0
    for old, new in STUBS:
        if t.count(old) != 1:
            print('!! stub anchor not unique (%d): %s' % (t.count(old), old[:50]))
        else:
            t = t.replace(old, new)
            n += 1
    # 标题模板占位符替换：DesktopEditors 部署时 CI 把 {{APP_TITLE_TEXT}} 替换为产品名
    # （desktop 本地部署无构建替换步骤，改为直接替换为应用名）
    for old, new in [("'{{APP_TITLE_TEXT}}'", "'ONLYOFFICE'"),
                     ('{{COMPANY_NAME}}', 'ONLYOFFICE')]:
        if t.count(old) > 0:
            t = t.replace(old, new)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(t)
    print('Main.js stubs: %d' % n)


def stub_viewportjs():
    """Viewport.onLaunch 打桩：确认 asc_docs_api 构造调用与返回（data-mvlaunch/mvas0/mvas1）"""
    p = os.path.join(DST_WEB, 'apps', 'documenteditor', 'main', 'app', 'controller', 'Viewport.js')
    with open(p, 'r', encoding='utf-8') as f:
        t = f.read()
    STUBS = [
        ('onLaunch: function() {',
         'onLaunch: function() { document.documentElement.setAttribute("data-mvlaunch","1");'),
        ('this.api = new Asc.asc_docs_api(config);',
         'document.documentElement.setAttribute("data-mvas0","1"); try { this.api = new Asc.asc_docs_api(config); document.documentElement.setAttribute("data-mvas1","1"); } catch(__e) { document.documentElement.setAttribute("data-mvaserr", String((__e && (__e.stack || __e.message)) || __e).slice(0, 300)); }'),
    ]
    n = 0
    for old, new in STUBS:
        if t.count(old) != 1:
            print('!! viewport stub anchor not unique (%d): %s' % (t.count(old), old[:50]))
        else:
            t = t.replace(old, new)
            n += 1
    with open(p, 'w', encoding='utf-8') as f:
        f.write(t)
    print('Viewport.js stubs: %d' % n)


def patch_api_base():
    """rawfile 版 apiBase.js 修复：_openEmptyDocument 中 getEmpty() 返回的 OpenFileResult
    是 base64 字符串（"DOCY;v2;50190;"+base64），而 checkStreamSignature 用 charCodeAt
    逐字节比对——字符串走恒 false -> bSerFormat=false -> openDocument 走入 SDK 中不存在
    的 this.OpenDocument（word/api.js:8466）崩溃（实测 pf: od:false|string|DOCY;v|null）。
    BinaryFileReader.getbase64DecodedData（Serialize2.js:7816）原生支持 string base64
    （isBase64 = typeof szSrc === 'string'），故 string 直接置 bSerFormat=true 即可自然
    走进 OpenDocumentFromBin；字节数组（官方路径）保留原签名检测。"""
    p = os.path.join(DST_SDK, 'common', 'apiBase.js')
    with open(p, 'r', encoding='utf-8') as f:
        t = f.read()
    # 诊断：onEndLoadFile 分叉点标记（POC 用，正式化删除）—— 看 PK 字节为何没走到 openDocument
    if t.count('baseEditorsApi.prototype.onEndLoadFile = function(result)') == 1:
        old2 = "baseEditorsApi.prototype.onEndLoadFile = function(result)\n\t{"
        new2 = ("baseEditorsApi.prototype.onEndLoadFile = function(result)\n\t{\n\t\t"
                "try { console.error('OELF enter isload=' + this.isLoadFullApi + ' docinfo=' + !!this.DocInfo + ' mods=' + this._isLoadedModules() + ' data=' + (result && (typeof result.data) + ':' + String(result && result.data || '').slice(0, 14))); } catch (__o) {}")
        t = t.replace(old2, new2, 1)
        old3 = "\t\t\tthis.openDocument(this.openResult);\n\t\t\tthis.sendEvent(\"asc_onDocumentPassword\", (\"\" !== this.currentPassword));"
        new3 = ("\t\t\ttry { var _ACE = window.AscCommon && window.AscCommon.SpreadsheetEditorApi; console.error('OELF2 call od hooked=' + (this.openDocument.__pd2H || this.openDocument.__podd2 || 'NO') + ' proto=' + Object.getPrototypeOf(this).constructor.name + ' ACED=' + (!!_ACE) + ' pd2=' + (_ACE && _ACE.prototype.openDocument && _ACE.prototype.openDocument.__pd2H || '-') + ' sam=' + (_ACE && (Object.getPrototypeOf(this) === _ACE.prototype)) + ' own=' + this.hasOwnProperty('openDocument') + ' eqAsc=' + (this === window.Asc.editor) + ' eqW=' + (this === window.editor)); } catch (__o9) {}\n"
                "\t\t\tthis.openDocument(this.openResult);\n\t\t\tthis.sendEvent(\"asc_onDocumentPassword\", (\"\" !== this.currentPassword));")
        t = t.replace(old3, new3, 1)
    old = "file.data = AscCommon.getEmpty();\n\t\tfile.bSerFormat = AscCommon.checkStreamSignature(file.data, AscCommon.c_oSerFormat.Signature);"
    new = "file.data = AscCommon.getEmpty();\n\t\tfile.bSerFormat = (typeof file.data === 'string') ? true : AscCommon.checkStreamSignature(file.data, AscCommon.c_oSerFormat.Signature);"
    if t.count(old) != 1:
        print('!! apiBase anchor not unique (%d)' % t.count(old))
        return
    t = t.replace(old, new)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(t)
    print('apiBase.js patched (_openEmptyDocument bSerFormat: string->true)')


def patch_docscoapi_license():
    """rawfile 版 docscoapi.js 修复：无服务器（dummy）模式 CDocsCoApi.init 的 else 分支
    调 onLicense(null) -> apiBase._onEndPermissions 中 `null !== this.licenseResult` 恒 false
    -> asc_CAscEditorPermissions 保持构造默认 licenseType=c_oLicenseResult.Error(=1)
    -> Main.onEditorPermissions 的 license 警告分支（molgT）拦截 return
    -> asc_LoadDocument 从未被调 -> auth/onFirstLoadChangesEnd/asyncServerIdEndLoaded 链断
    -> ServerIdWaitComplete 恒 false -> _openDocumentEndCallback guard 卡死（v40 DEOC:SIdW 实测）。
    改为 dummy 直接下发 Success 许可（type=Success(3), rights=Edit(1)），与无服务器离线
    打开（B 架构 WebView 无文档服务器）语义一致。"""
    p = os.path.join(DST_SDK, 'common', 'docscoapi.js')
    with open(p, 'r', encoding='utf-8') as f:
        t = f.read()
    old = """    } else {
      // Dummy calls
      this.onFirstConnect();
      this.onLicense(null);
    }"""
    new = """    } else {
      // Dummy calls
      this.onFirstConnect();
      // v42: 无服务器离线模式 must 下发 Success 许可，否则 licenseType=Error(1)
      // 导致 Main.onEditorPermissions 警告拦截 -> asc_LoadDocument 从未执行 -> 文档链冻结
      // （c_oLicenseResult.Success=3, c_oRights.Edit=1, c_oLicenseMode.None=0）
      this.onLicense({
        'type': 3, 'rights': 1, 'mode': 0,
        'buildVersion': '7.5.4', 'buildNumber': 101,
        'branding': false, 'customization': false, 'light': false,
        'liveViewerSupport': null
      });
    }"""
    if t.count(old) != 1:
        print('!! docscoapi anchor not unique (%d)' % t.count(old))
        return
    t = t.replace(old, new)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(t)
    print('docscoapi.js patched (dummy license -> Success)')


def make_placeholder_sprites():
    """老式 sprite 资产（iconsmall/iconsbig/iconshuge@2.5x.svg、formats@2.5x.svg）是构建产物，
    源码树（v2 分图时代）与官方仓库都不存在。themeinit.js 的 apply_icons_from_url 会
    运行时 fetch 它们，缺失导致 404 对话框。
    真 sprite 由官方构建链生成（build/sprites grunt -> 写回 dev 树 img/*.png/@2.5x.svg，
    以及 iconsmall/…/iconshuge 的 svg sprite），此处仅对**不存在**的文件写空占位，
    避免覆盖构建产物。doc-formats 构建链未生成时保留空占位（无 404 对话框）。"""
    files = {
        'apps/documenteditor/main/resources/img/iconsmall@2.5x.svg': None,
        'apps/documenteditor/main/resources/img/iconsbig@2.5x.svg': None,
        'apps/documenteditor/main/resources/img/iconshuge@2.5x.svg': None,
        'apps/common/main/resources/img/doc-formats/formats@2.5x.svg': None,
    }
    n = 0
    for rel in files:
        p = os.path.join(DST_WEB, rel)
        if os.path.exists(p):
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as f:
            f.write('<svg xmlns="http://www.w3.org/2000/svg"></svg>')
        n += 1
    print('placeholder sprites: %d' % n)


def make_root_configs():
    """文档服务根级配置（部署时随服务器分发，本地 rawfile 无服务器）：
    - onlyoffice/themes.json  Themes.js get_themes_config('../../../../themes.json')
      解析 parse_themes_object(obj.themes) -> 与官方默认（apps/common/.../themes/themes.json）
      一致的空主题列表，走内置静态主题类渲染。
    - onlyoffice/plugins.json  sdkjs/common/plugins.js 与 Plugins.js 均期望 pluginsData。
    """
    files = {
        'themes.json': '{\n    "themes": []\n}',
        'plugins.json': '{\n    "pluginsData": []\n}',
    }
    for name, content in files.items():
        p = os.path.join(RAW, name)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(content)
    print('root configs: %s' % ', '.join(files))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry', action='store_true')
    args = ap.parse_args()

    if args.dry:
        total = 0
        for rel, _ in WEB_COPY:
            s = os.path.join(SRC_WEB, rel)
            p = 0
            if os.path.isfile(s):
                p = os.path.getsize(s)
                print('file %-60s %8.1f MB' % (rel, p / 1e6))
                total += p
            elif os.path.isdir(s):
                for root, _, files in os.walk(s):
                    parts = set(root.split(os.sep))
                    if WEB_EXCLUDE_DIR & parts:
                        continue
                    p += sum(os.path.getsize(os.path.join(root, x)) for x in files)
                print('dir  %-60s %8.1f MB' % (rel, p / 1e6))
                total += p
        for name in SDK_KEEP:
            s = os.path.join(SRC_SDK, name)
            p = sum(os.path.getsize(os.path.join(r, x))
                    for r, _, fs in os.walk(s) for x in fs)
            print('sdk  %-60s %8.1f MB' % (name, p / 1e6))
            total += p
        print('--- TOTAL %.1f MB ---' % (total / 1e6))
        return

    shutil.rmtree(DST_SDK, ignore_errors=True)
    shutil.rmtree(DST_WEB, ignore_errors=True)
    copy_sdkjs()
    copy_fonts()
    copy_webapps()
    stub_mainjs()
    stub_loadbinary()
    stub_cell_api()
    stub_viewportjs()
    patch_api_base()
    patch_docscoapi_license()
    pages = [('documenteditor', 'word'), ('spreadsheeteditor', 'spreadsheet'), ('presentationeditor', 'presentation')]
    for page, doc in pages:
        app_main = os.path.join(DST_WEB, 'apps', page, 'main')
        css_ok = precompile_css(app_main)
        make_index_html(page, os.path.join(app_main, 'index.html'), doc, use_css=css_ok)
    make_placeholder_sprites()
    make_root_configs()
    shutil.copy2(DOC_SRC, os.path.join(RAW, 'document.docx'))
    # 迭代2：三件套测试样本（docx/xlsx/pptx）打包进 rawfile/onlyoffice/（rawfileLoader 直读；
    # 沙箱 filesDir 外部写入被 DAC 拒，故测试文档走 rawfile 路线）
    SAMPLE_DIR = os.path.join(ROOT, 'scripts', 'onlyoffice', 'samples')
    for _s in ('sample.docx', 'sample.xlsx', 'sample.pptx'):
        _p = os.path.join(SAMPLE_DIR, _s)
        if os.path.exists(_p):
            shutil.copy2(_p, os.path.join(RAW, _s))
        else:
            print('!! sample missing: %s' % _p)
    print('pack done: %s' % RAW)


if __name__ == '__main__':
    main()
