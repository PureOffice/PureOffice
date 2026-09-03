#!/usr/bin/env python3
"""POC-2: ONLYOFFICE core -> 单一 CMakeLists（OHOS arm64 交叉）。

输入: 各模块 qmake .pro/.pri（经 qmake2cmake.Parser 解析，源码/头/include/defines 抽为纯 CMake）。
输出: /data/share/office/build/core3d/CMakeLists.txt（构建目录 build/core3d/build）。
模块序列 = 官方 X2tConverter ADD_DEPENDENCY 链（静态库全部编译，最终 x2t 3 源成 libx2t.a；
NAPI convertershell 在下一阶段生成）。
"""
import os
import sys
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmake2cmake import Parser  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CORE = os.path.join(ROOT, 'third_party', 'core')
OUT_DIR = os.path.join(ROOT, 'build', 'core3d')

# (cmake_target, pro 相对 core 路径, 依赖 target 列表)
MODULES = [
    # ---- 基础三件套（官方 ADD_DEPENDENCY 底层序）----
    ('UnicodeConverter', 'UnicodeConverter/UnicodeConverter.pro', []),
    ('kernel', 'Common/kernel.pro', ['UnicodeConverter']),
    ('graphics', 'DesktopEditor/graphics/pro/graphics.pro', ['kernel']),
    ('CompoundFileLib', 'Common/cfcpp/cfcpp.pro', []),
    ('CryptoPPLib', None, []),  # 3dParty/cryptopp 的 libcryptopp.a 预编译
    # ---- OOXML 二进制/表格系 ----
    ('VbaFormatLib', 'MsBinaryFile/Projects/VbaFormatLib/Linux/VbaFormatLib.pro', []),
    ('DocFormatLib', 'MsBinaryFile/Projects/DocFormatLib/Linux/DocFormatLib.pro', ['CompoundFileLib']),
    ('PPTFormatLib', 'MsBinaryFile/Projects/PPTFormatLib/Linux/PPTFormatLib.pro', []),
    ('XlsFormatLib', 'MsBinaryFile/Projects/XlsFormatLib/Linux/XlsFormatLib.pro', ['CompoundFileLib']),
    ('XlsbFormatLib', 'OOXML/Projects/Linux/XlsbFormatLib/XlsbFormatLib.pro', ['CompoundFileLib']),
    ('BinDocument', 'OOXML/Projects/Linux/BinDocument/BinDocument.pro', ['CompoundFileLib', 'DocFormatLib', 'PPTFormatLib', 'XlsFormatLib']),
    # ---- 文本/开放格式 ----
    ('RtfFormatLib', 'RtfFile/Projects/Linux/RtfFormatLib.pro', []),
    ('TxtXmlFormatLib', 'TxtFile/Projects/Linux/TxtXmlFormatLib.pro', []),
    ('OdfFormatLib', 'OdfFile/Projects/Linux/OdfFormatLib.pro', []),
    ('DocxFormatLib', 'OOXML/Projects/Linux/DocxFormatLib/DocxFormatLib.pro', ['CompoundFileLib']),
    ('PPTXFormatLib', 'OOXML/Projects/Linux/PPTXFormatLib/PPTXFormatLib.pro', ['DocxFormatLib']),
    # ---- 图形/PDF/其他输入 ----
    ('Fb2File', 'Fb2File/Fb2File.pro', []),
    ('XpsFile', 'XpsFile/XpsFile.pro', ['graphics']),
    ('OFDFile', 'OFDFile/OFDFile.pro', []),
    ('DjVuFile', 'DjVuFile/DjVuFile.pro', ['graphics']),
    ('HWPFile', 'HwpFile/HWPFile.pro', []),
    ('EpubFile', 'EpubFile/CEpubFile.pro', ['graphics', 'XpsFile']),
    ('PdfFile', 'PdfFile/PdfFile.pro', ['graphics', 'kernel', 'UnicodeConverter']),
    # ---- 渲染链 ----
    ('DocxRenderer', 'DocxRenderer/DocxRenderer.pro', ['graphics', 'kernel']),
    ('doctrenderer', 'DesktopEditor/doctrenderer/doctrenderer.pro',
     ['graphics', 'kernel', 'UnicodeConverter', 'DocxFormatLib', 'DocxRenderer', 'PdfFile']),
    # ---- 签名/加密/格式互通（官方 x2t 完整链接集，Android libs_list 参照）----
    ('ooxmlsignature', 'DesktopEditor/xmlsec/src/ooxmlsignature.pro', []),
    ('ooxml_crypt', 'OfficeCryptReader/ooxml_crypt/ooxml_crypt.pro',
     ['CryptoPPLib', 'CompoundFileLib', 'UnicodeConverter', 'kernel']),
    ('HtmlFile2', 'HtmlFile2/HtmlFile2.pro', ['graphics', 'kernel', 'UnicodeConverter']),
    ('IWorkFile', 'Apple/IWork.pro', ['kernel', 'UnicodeConverter']),
    ('StarMathConverter', 'OdfFile/Reader/Converter/StarMath2OOXML/StarMath2OOXML.pro',
     ['kernel']),
    # kernel_network：官方 Android x2t 链接集 libkernel_network.so（CFileDownloader 等）——
    # Linux/OHOS 语义（core_linux:CONFIG += use_external_transport）无需内嵌 curl
    ('kernel_network', 'Common/Network/network.pro', ['kernel']),
    # ---- x2t：3 源 + 全链 ----
    ('x2t', 'X2tConverter/build/Qt/X2tConverter.pri',
     ['graphics', 'kernel', 'UnicodeConverter', 'CryptoPPLib',
      'Fb2File', 'PdfFile', 'EpubFile', 'XpsFile', 'OFDFile', 'DjVuFile',
      'doctrenderer', 'DocxRenderer', 'HWPFile',
      'VbaFormatLib', 'OdfFormatLib', 'DocFormatLib', 'PPTFormatLib',
      'RtfFormatLib', 'TxtXmlFormatLib', 'BinDocument', 'PPTXFormatLib',
      'DocxFormatLib', 'XlsbFormatLib', 'XlsFormatLib', 'CompoundFileLib',
      # Android 官方 x2t 链接集（libUnicodeConverter...libooxmlsignature）补充
      'HtmlFile2', 'IWorkFile', 'StarMathConverter', 'ooxmlsignature', 'ooxml_crypt']),
]

# 额外 include（qmake 树外交付件：boost b2 安装前缀 / ICU 交叉头）
EXTRA_INC = [
    'Common/3dParty/boost/build/ohos_arm64/include',
    'Common/3dParty/icu/android/build/ohos_arm64/include',
    'Common/3dParty/icu/android/icu/source/common',
    'Common/3dParty/icu/android/icu/source/i18n',
]

# 全局附加 define（OHOS 统一按 Linux 语义；错误驱动可增减）
EXTRA_DEF = [
    'LINUX', '_LINUX', 'CORE_LINUX',
    # 官方语义：UNICODE 由各模块 .pri 自控（raster.pri 显式 -UNICODE、x2t 同链 +UNICODE）
    # OHOS musl 无 pthread_cancel API；官方 Android 亦保留此番宏走同一路径
    'NOT_USE_PTHREAD_CANCEL',
    # openjpeg 上游 opj_malloc.h:96 的 `#pragma GCC poison malloc...` 官方逃生门
    # （opj_malloc.c 内 define OPJ_SKIP_POISON 因 include 链先 po 后 .c 而失效）
    'OPJ_SKIP_POISON',
]


# 裁剪：模块名 -> 排除的源文件名后缀（空表=不裁剪；GraphicsRenderer 的 CMetaFile 调用在
# 官方树 #if 0 内，源保留编译）
CUT_SUFFIXES = {
    # ooxml_crypt 官方 TEMPLATE=app（main.cpp CLI 入口）—— 库形态裁掉 main
    'ooxml_crypt': ['main.cpp'],
}

# 附加 include 根（相对 core）：Xls 族源大量 `../../../Common/...` 相对引用，
# 基准是 MsBinaryFile/、OOXML/ 根（官方 qmake 全局 include 环境提供）。
# 注意 GCC 对 quote-include 的 `../` 是「include 目录拼接后 OS 解析」：
# xls_format_logic.cpp（Logic/pri/ 下）写 `../../../Common/...`，上 3 级需落到
# MsBinaryFile → 补 `MsBinaryFile/XlsFile/Format/Logic`（其 ../.. 上级 = MsBinaryFile）
MODULE_EXTRA_INCS = {
    'VbaFormatLib': ['MsBinaryFile'],
    'DocFormatLib': ['MsBinaryFile'],
    'PPTFormatLib': ['MsBinaryFile'],
    'XlsFormatLib': ['MsBinaryFile', 'OOXML', 'MsBinaryFile/XlsFile/Format/Logic'],
    'XlsbFormatLib': ['MsBinaryFile', 'OOXML'],
    'BinDocument': ['MsBinaryFile', 'OOXML'],
}

# 模块级附加 define（对齐 djvulibre autoconf 检测结果：平台有 <wchar.h>/mbstate_t，
# 否则 GString.h 的 `typedef int mbstate_t` 与系统 __mbstate_t 冲突；HAS_WCHAR=1 令
# `<wchar.h>` 被 include（296 行 mbstate_t 使用需要）。openjpeg：上游 opj_malloc.h:96
# 的 `#pragma GCC poison malloc...` 官方逃生门 OPJ_SKIP_POISON（thread.c 同注 ulibc 问题））
MODULE_EXTRA_DEFS = {
    # djvulibre 各 .cpp 以 `#ifdef UNIX` 走 POSIX 分支（unistd.h/errno.h/mmap 等），
    # 官方 makefile 定义；autoconf 检测结果补充 wchar/mbstate
    # HAVE_STDINCLUDES: GException.cpp 走 `std::set_new_handler`（全局 set_new_handler 是旧
    # glibc 扩展，musl/libstdc++ 无）——同 djvulibre autoconf 的 HAVE_STDINCLUDES 检测
    'DjVuFile': ['UNIX', 'HAS_WCHAR=1', 'HAS_MBSTATE=1', 'HAVE_STDINCLUDES'],
}


def parse_module(pro_rel, extra_incs=None):
    p = Parser()
    # WMF/EMF/SVG/SVM 矢量元文件解释器：POC-2 x2t 链不需要，
    # 且 IMetaFile 类在官方 9.4 树已飘移（根 MetaFile.h 引用无定义类）
    # 官方 metafile 默认全开：`graphics_disable_metafile { DEFINES+=GRAPHICS_DISABLE_METAFILE }
    # } else { include(metafile.pri) }` —— 本移植走 else（保留 include(metafile.pri)，
    # 即官方 Linux 默认），then 分支（GRAPHICS_DISABLE_METAFILE）剥除。
    # 因此 IMetaFile（graphics/pro/Image.h:121）与解释器族源全部回归官方语义编译。
    # support_web_socket / support_oform：qmake 未启用 feature（默认关），
    # then 分支（websocket.pri / Certificate_oform.h）官方默认不编 → 剥 then
    p.skip_then_keys = {'graphics_disable_metafile', 'support_web_socket', 'support_oform'}
    # `use_openjpeg2000 { include(openjpeg.pri) } else { USE_GRAPHICS_JPEG2000 }`：
    # openjpeg.pri 引树内 openjpeg-2.4.0（then 分支），else 分支的 USE_GRAPHICS_JPEG2000
    # 走 raster J2kFile.h（Jpeg2000 命名空间），与 JPXStream2.cpp 的 openjpeg:: 调用不匹配
    # `!use_all_in_one { ... } else { opj_engine.cpp }`：官方默认（无 CONFIG use_all_in_one）
    # 走 then=逐个 .c 编译；else 的 unity 入口剥离（否则双份编译）
    p.skip_else_keys = {'use_openjpeg2000', '!use_all_in_one'}
    # js_base.pri 的 `!use_javascript_core {`：V8 引擎 wrapper（v8_base.cpp + inspector +
    # Common/3dParty/v8/v8.pri）。V8 树内无素材（v8_89 submodule 空、android 仅 build 脚本），
    # 且 x2t 转换不执行 JS 宏（宏重算在编辑器/DocBuilder 运行期）——POC-2 剥除 V8 触面
    # （js_base.cpp 本体无 v8 依赖：.so 里 <v8.h> 引用全在 v8_base.cpp 内）。
    # 官方完整链路（编辑器）仍需落地 V8 build 脚本（TODO）
    p.disabled_neg_blocks = {'use_javascript_core'}
    # 官方 qmake 全局变量：平台前缀（qmake2cmake 对未知 $$VAR 展开为空，
    # 依赖它的路径（openssl.pri 的 build/$$CORE_BUILDS_PLATFORM_PREFIX/{lib,include}）需落地值
    p.vars['CORE_BUILDS_PLATFORM_PREFIX'] = 'ohos_arm64'
    p.parse(os.path.join(CORE, pro_rel))
    # 模块根目录自动加入 include（官方各 pro 源大量 `#include "模块内相对路径"`，
    # 靠 qmake 的全局 include 环境而非 pro 自身 INCLUDEPATH 解析）。
    # 双级注入：pro 顶层目录（历史 split 语义：MsBinaryFile 族源 `../../../Common/` 基准）
    # + pro 所在目录（doctrenderer/server.h 等模块内相对 include 的解析基准）
    pro_root = os.path.join(CORE, pro_rel.split('/')[0])
    pro_dir = os.path.join(CORE, os.path.dirname(pro_rel))
    includes = [i for i in p.includes if os.path.isdir(i)]
    for r in (pro_dir, pro_root):
        if os.path.isdir(r) and r not in includes:
            includes.append(r)
    # MODULE_EXTRA_INCS（相对 core）：Xls 族源 `../../../Common/...` 相对引用基准
    # 是 MsBinaryFile/、OOXML/ 根（官方 qmake 全局 include 环境提供）
    for extra in (extra_incs or []):
        d = os.path.join(CORE, extra)
        if os.path.isdir(d) and d not in includes:
            includes.append(d)
    return {
        'sources': [s for s, _ in p.sources],
        'headers': [h for h, _ in p.headers],
        'includes': includes,
        'defines': p.defines,
    }


def module_sources(tgt, info):
    cuts = CUT_SUFFIXES.get(tgt, [])
    return [s for s in info['sources'] if not any(s.endswith(c) for c in cuts)]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = []
    lines.append('# 由 scripts/onlyoffice/core3d/gen_cmake.py 生成 — POC-2 ONLYOFFICE core (OHOS arm64)')
    lines.append('cmake_minimum_required(VERSION 3.16)')
    lines.append('project(onlyoffice_core_x2t LANGUAGES C CXX)')
    lines.append('set(CMAKE_CXX_STANDARD 14)')
    lines.append('set(CMAKE_CXX_STANDARD_REQUIRED ON)')
    # -fsigned-char：回归官方桌面 Linux 语义（x86_64 char 有符号；OHOS arm64 默认无符号，
    # 会令 ICCProfile 等负值常量表 -Wnarrowing 毙命；libstdc++/zlib 等均按 signed 假设）
    lines.append('add_compile_options(-fPIC -Wno-unused-result -fsigned-char)')
    lines.append('')
    lines.append(f'set(CORE_ROOT "{CORE}")')
    lines.append('')
    for inc in EXTRA_INC:
        lines.append(f'list(APPEND EXTRA_INC "${{CORE_ROOT}}/{inc}")')
    lines.append('')

    parsed = {}
    for tgt, pro_rel, deps in MODULES:
        if pro_rel is None:
            # 预编译静态库（cryptopp）
            lines.append(f'# {tgt}: prebuilt static lib (3dParty/cryptopp)')
            lines.append(f'add_library({tgt} STATIC IMPORTED GLOBAL)')
            lines.append(f'set_target_properties({tgt} PROPERTIES IMPORTED_LOCATION '
                         f'"${{CORE_ROOT}}/Common/3dParty/cryptopp/libcryptopp.a")')
            lines.append('')
            continue
        info = parse_module(pro_rel, MODULE_EXTRA_INCS.get(tgt))
        parsed[tgt] = info
        print(f'{tgt}: {len(info["sources"])} sources, {len(info["defines"])} defines, '
              f'{len(info["includes"])} includes', file=sys.stderr)

        srcs = ' '.join(f'"${{CORE_ROOT}}/{os.path.relpath(s, CORE)}"' for s in module_sources(tgt, info))
        if tgt == 'doctrenderer':
            # doctrenderer JS 引擎接入层（v8/jsc）的 OHOS 无引擎桩（js_stub_ohos.cpp）：
            # CJSContext/各 Embed 注册接口/NSAllocator 等符号以无操作实现满足链接
            # （POC 转换路径不触 JS 运行时；源文件与 js_base.h 同目录，随核心树）
            srcs += ' "${CORE_ROOT}/DesktopEditor/doctrenderer/js_internal/js_stub_ohos.cpp"'
        lines.append(f'add_library({tgt} STATIC {srcs})')
        incs = [f'"${{CORE_ROOT}}/{os.path.relpath(i, CORE)}"' for i in info['includes']]
        lines.append(f'target_include_directories({tgt} PUBLIC ${{EXTRA_INC}} {" ".join(incs)})')
        defs = [d for d in info['defines'] if not d.startswith('$')]  # 去掉未展开的 $$VAR 残留
        # qmake DEFINES 的 `FOO="1"` 在官方 make/shell 层被剥引号（shell 词法），
        # CMake 直接字面过 -> gcc 收到 `-DFOO="1"`，`#if FOO` 展开成 `#if "1"` 报错
        # （DjVuFile.pro:59 GCONTAINER_NO_MEMBER_TEMPLATES="1"）。剥值端成对引号
        # （首字符是宏名，不能对 d 自身剥首尾；strip 单端会留下半引号）
        defs = [re.sub(r'^([A-Za-z_]\w*)="(.+)"$', r'\1=\2', d) for d in defs]
        defs += MODULE_EXTRA_DEFS.get(tgt, [])
        lines.append(f'target_compile_definitions({tgt} PUBLIC {" ".join(EXTRA_DEF)} {" ".join(defs)})')
        if deps:
            lines.append(f'target_link_libraries({tgt} PUBLIC {" ".join(deps)})')
        lines.append('')

    with open(os.path.join(OUT_DIR, 'CMakeLists.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'written: {OUT_DIR}/CMakeLists.txt')
    return 0


if __name__ == '__main__':
    sys.exit(main())
