#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate entry/src/main/resources/rawfile/onlyoffice/ascshim.js

拼接 scripts/onlyoffice/desktop/src/*.js（页面适配 JS 源码，按主题分文件）：
  09_fonts.js  字体字节预载（2026-09-05 中文方块根因：CJK 大字体文件晚于
               首次渲染到达 → LoadFont face=null → HB_ShapeString 失败方块；
               预取 + loader 喂字节，字体先于渲染就绪）
  00_boot.js   外层头/公共工具（__lsoB64；原 cell 剖面诊断已移除）
  10_engine.js Gateway 踢闸（serverId/images 引擎闸门适配 + 字节打点）
  20_bridge.js AscDesktopEditor 装配（方法表/官方 shim/字体注册表/就绪探针）
  30_open.js   DI 打开链（loadConfig 补发/CDocInfo/权限/m7 验收工具）
  40_save.js   保存/关闭链适配（SaveDocument 落盘/requestClose/错误拦截）
  50_init.js   初始化尾（AscNative 等待循环）

src 内以占位符接入脚本动态内容（一一对应下面 .replace）：
  @@METHOD_JS@@       方法表装配（asc_methods.txt 转 JS 方法体）
  @@SHIM@@            官方 InitJSContext shim（ascdesktop_shim_raw.js）
  @@FONT_FILES_JSON@@ 字体文件表（build_editors_ohos.FONT_FILES，同源不重复定义）
  @@FONT_INFOS_JSON@@ 字体元数据表

产物校验：node --check（JS 语法硬校验，失败即非零退出；宿主机无 node 时降级告警）。
设计总览（分层 / 各段职责 / 自检用法 / 使用边界）见 docs/ONLYOFFICE_ASC_SHIM_DESIGN.md
修改页面适配请改 src/*.js 后重新生成；**ascshim.js 是生成产物，勿手改**。
"""
import os
import json
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
# 字体表唯一来源在 build_editors_ohos.py（FONT_INFOS/FONT_FILES/FONT_RANGES；
# R,I,B,BI 顺序契约同注那里——两处独立定义会漂移导致字体注册表错位，
# 2026-09-05 审查收敛；FONT_RANGES = 引擎 CFontByCharacter 注册表第三张注入表）
from build_editors_ohos import FONT_INFOS, FONT_FILES, FONT_FILES_ALL, FONT_RANGES  # noqa: E402
# __fonts_files（20_bridge.js @@FONT_FILES_JSON@@）= rawfile + 系统字体
# （FONT_FILES_ALL）：引擎 checkAllFonts 建 g_font_files 需含系统字体条目
# （Id=文件名，页面 09_fonts.js 装填按 Id 匹配）；下标与 FONT_INFOS indexR
# 对齐（>= len(FONT_FILES) 者为系统字体，2026-09-07）。
METHODS = [l.strip() for l in open(os.path.join(HERE, 'asc_methods.txt')) if l.strip()]
SHIM = open(os.path.join(HERE, 'ascdesktop_shim_raw.js'), encoding='utf-8').read()

# 桥协议：AscNative._call 返回 JSON 编码字符串（对象/数组→JSON；纯字符串→带引号 JSON）。
# JS 侧统一 JSON.parse 解包——保证页面拿到真值（如 GetExternalClouds → [] 而不是 '[]'）。
method_lines = []
# 需回灌 loginpage 面板的方法（官方 CEF：Recents_Dump → ExecuteJavaScript
# window.onupdaterecents(json)；loginpage 面板订阅 sdk.on('onupdaterecents') → sdk.fire 桥接）
FIRE_MAP = {
    'LocalFileRecents': 'onupdaterecents',
    'LocalFileRecovers': 'onupdaterecovers',
}
# RAW 方法：官方 CEF 返回 **JSON 文本字符串**，消费端自己 JSON.parse()（sdkjs
# JSON.parse(AscDesktopEditor.GetInstallPlugins()) 等）—— 桥层不得解包。
#   桥返回形式同时保持 JSON 文本（ascBridge.ets 对应 case 已按官方空态结构返回）。
RAW_METHODS = {'GetInstallPlugins', 'GetBackupPlugins'}
for m in METHODS:
    if m in RAW_METHODS:
        body = (' var r = window.AscNative && window.AscNative._call(' +
                '"%s", Array.prototype.slice.call(arguments));' % m +
                ' return r; };')
        method_lines.append('  window.__ascDesktopEditorMethods["%s"] = function() {' % m + body)
        continue
    body = (' var r = window.AscNative && window.AscNative._call(' +
            '"%s", Array.prototype.slice.call(arguments));' % m +
            ' var v; try { v = r ? JSON.parse(r) : r; } catch(e) { v = r; }')
    if m in FIRE_MAP:
        body += (' try { window["%s"] && window["%s"](v); } catch(e) {}'
                 % (FIRE_MAP[m], FIRE_MAP[m]))
    body += ' return v; };'
    method_lines.append('  window.__ascDesktopEditorMethods["%s"] = function() {' % m + body)

METHOD_JS = '\n'.join(method_lines)
SHIM_INDENTED = '\n'.join('    ' + ln for ln in SHIM.split('\n'))

SRC_DIR = os.path.join(HERE, 'src')
# 00_theme 必须在首位：RendererProcessVariable.theme 必须早于官方 desktopinit 内联段
# （index.html 同步一次性消费——误放 AscNative 等待之后= 注入执行≠生效，2026-09-08 教训）
# 55_lic 之后追加 57_about（欢迎页 About 入口的 app:version 补发；仅欢迎页 URL 生效）
# （44_modalguard 已于 2026-09-21 fork 化阶段 1 退役：Desktop.js 八处裸调 native 的
#   壳层事件 handler 已在 web-apps fork 加 [OHOS: native-guard] 源码守卫——比 trigger
#   层兜底更彻底，同名后续 handler 不再被跳过）
# （29_inputfocus 同日退役：焦点抑制三件套进 sdkjs fork text_input2.js——
#   isGlobalDisableFocus 按 URL 参数 nofocus=1 初始化（替代轮询）、document focus
#   监听器早退条件扩展、点文档区补聚焦监听器进 InitBrowserInputContext；
#   HTMLElement.prototype.focus 全局原型覆写（trick 中副作用最大者）不再保留）
# （51_scrollpad 同日退役：scroll.js _MouseHoverOnScroller 判定加可选 tol 容差、
#   evt_mousedown 触摸起手传 8 CSS px × dPR——取代 capture 层坐标接管/双流同拦）
# （49_doclang 同日退役：cell/api.js defaultLanguage 构造按 sse-spellcheck-locale
#   偏好初始化（缺省 2052），面板侧官方 mode.lang fallback 已对——localStorage
#   预写 + api 就绪轮询回灌不再需要；回归判据改 LSO_DOCLANG init=2052）
# （58_pastebtn 同日退役：clipboard_base.js Button_Paste 头部 AscNative 分支 +
#   __lsoPasteIn 回调入口（惰性取 g_clipboardBase）——宿主侧 clip:paste 命令与
#   回调契约键名不变，轮询 300 次等 Button_Paste 的覆写不再需要）
# （57_about 同日退役：desktop-apps fork loginpage/panelabout.js init 内自治
#   fire on_native_message app:version（fetch version.json 单次）——消费链官方
#   原样（panels.js 侧栏显示/panelabout 视图创建），高频轮询 unhide + fire
#   重发×8 由「订阅先于 fire」的时序保证取代）
# 45_print 紧随 40_save 之后（编辑器页序列化链，顺序仅为可读性——与前面各段无依赖）
# 09_fontpick 紧贴 09_fonts（同为字体域；它是 smoke 专用映射探针，须在 00_boot 之前
#   的**独立段**里尽早装钩子——见该文件注释）
# 注意：00_boot.js 的 `(function() {` 是**故意不闭合**的「外层头」（其后各段都在它内部），
#   本文件之前各段均如此 —— 新增段放在 00_boot.js 之后即自动位于该外层 IIFE 内
# 29_inputfocus 紧跟 20_bridge（同为宿主↔页面基础能力，与前后段无依赖）
# 58_pastebtn 追加于 57_about 后（工具栏「粘贴」宿主桥；自包含段、外层 IIFE 之外）
PARTS = ['00_theme.js', '09_fonts.js', '09_fontpick.js', '00_boot.js', '10_engine.js', '20_bridge.js', '30_open.js', '40_save.js', '45_print.js', '46_fontimg.js', '47_img.js', '48_mediaunpack.js', '50_init.js', '55_lic.js']
OUT = os.path.join(HERE, '..', '..', '..', 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice', 'ascshim.js')


def build() -> str:
    js = '/* auto-generated by make_ascshim.py — do not edit */\n'
    js += ''.join(open(os.path.join(SRC_DIR, p), encoding='utf-8').read() for p in PARTS)
    return (js.replace('@@METHOD_JS@@', METHOD_JS)
               .replace('@@SHIM@@', SHIM_INDENTED)
               .replace('@@FONT_FILES_JSON@@', json.dumps(FONT_FILES_ALL))
               .replace('@@FONT_INFOS_JSON@@', json.dumps(FONT_INFOS))
               .replace('@@FONT_RANGES_JSON@@', json.dumps(FONT_RANGES)))


JS = build()
# 输出目录自建：毁灭性重建演练（rm rawfile/onlyoffice 后全链）暴露的缺陷——
# 目录被清后本脚本不自愈（FileNotFoundError），必须先 mkdir（2026-09-21 阶段 0）
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, 'w', encoding='utf-8') as f:
    f.write(JS)

# 语法硬校验：node --check（宿主机 node 为 web-apps 构建链依赖，必然存在；
# 缺失时告警不阻断——2026-09-05 审查补上 else 分支的明确提示）
if shutil.which('node'):
    import tempfile
    tmp = tempfile.mktemp(suffix='.js')
    try:
        with open(tmp, 'w', encoding='utf-8') as tf:
            tf.write(JS)
        rc = subprocess.run(['node', '--check', tmp], capture_output=True, text=True)
        if rc.returncode != 0:
            print(rc.stderr, file=sys.stderr)
            sys.exit(f'node --check FAILED on generated ascshim.js: {OUT}')
        print('node --check: OK')
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
else:
    print('!! node 未安装：跳过 ascshim 语法校验（仅告警，不阻断）', file=sys.stderr)

print(f'total methods: {len(METHODS)}')
print(f'shim bytes: {len(SHIM)}')
print(f'parts: {", ".join(PARTS)}')
print(f'out: {OUT}')
