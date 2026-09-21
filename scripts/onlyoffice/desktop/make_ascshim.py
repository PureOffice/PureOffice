#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate entry/src/main/resources/rawfile/onlyoffice/ascshim.js

拼接 scripts/onlyoffice/desktop/src/*.js（页面适配 JS 源码，按主题分文件）：
  09_fonts.js  字体字节预载（2026-09-05 中文方块根因：CJK 大字体文件晚于
               首次渲染到达 → LoadFont face=null → HB_ShapeString 失败方块；
               预取 + loader 喂字节，字体先于渲染就绪）
  00_boot.js   外层头/公共工具（__lsoB64；原 cell 剖面诊断已移除）
  10_engine.js 已退役（Gateway 踢闸进五编辑器 Main.js loadBinary [OHOS: engine]）
  20_bridge.js AscDesktopEditor 装配（方法表/官方 shim/字体注册表/就绪探针）
  30_open.js   DI 打开链（loadConfig 补发/CDocInfo/权限/m7 验收工具）
  40_save.js   保存/关闭链适配（SaveDocument 落盘/requestClose/错误拦截）
  50_init.js   初始化尾（AscNative 等待循环）

src 内以占位符接入脚本动态内容（一一对应下面 .replace）：
  @@METHOD_JS@@       方法表装配（asc_methods.txt 转 JS 方法体）
  @@SHIM@@            官方 InitJSContext shim（ascdesktop_shim_raw.js）
  （@@FONT_*_JSON@@ 字体三表占位已移除——2-j1 起字体注册表生成进 AllFonts.js）

产物校验：node --check（JS 语法硬校验，失败即非零退出；宿主机无 node 时降级告警）。
设计总览（分层 / 各段职责 / 自检用法 / 使用边界）见 docs/ONLYOFFICE_ASC_SHIM_DESIGN.md
修改页面适配请改 src/*.js 后重新生成；**ascshim.js 是生成产物，勿手改**。
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
# 字体表唯一来源在 build_editors_ohos.py（FONT_INFOS/FONT_FILES/FONT_RANGES）——
# 三表注入已随 fork 化阶段 2-j1 并入装配产物 AllFonts.js（gen_allfonts 尾部），
# ascshim 不再注入字体注册表（2026-09-21）。
# 方法表/官方 shim 生成逻辑已随 20_bridge/50_init 退役挪入装配链
# （build_editors_ohos.gen_method_js/expand_ohos_bridge，2026-09-21 2-j2）
SRC_DIR = os.path.join(HERE, 'src')
# 00_theme 必须在首位：RendererProcessVariable.theme 必须早于官方 desktopinit 内联段
# （index.html 同步一次性消费——误放 AscNative 等待之后= 注入执行≠生效，2026-09-08 教训）
# （00_theme 已于 2026-09-21 fork 化阶段 2 整段退役：0.9 主题默认预写/0.11 导出
#   PDF 菜单隐藏先期源码化进 themeinit.js 默认值 + RPV 兜底 + common.less
#   （1-i）；0.10 tab 主题色上报进 web-apps fork controller/Themes.js
#   [OHOS: theme] 块——ohos_report_theme_color 在 apply_theme 尾部（切换路径）
#   与 init 尾部（初始路径）各挂一次，取代 readyState 轮询 + MutationObserver）
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
# （55_lic 同日退役：许可/声明全文弹层随品牌化源码化分置两域——编辑器页
#   web-apps fork About.js（lic-open 精准触发 + 文件级弹层）、欢迎页
#   desktop-apps fork panelabout.js（同型）。「target=_blank+localhost 全局
#   捕获拦截」的通用拦截器不再保留（ArkWeb 无多窗口的适配收敛进源内 dialog）；
#   L3 patch_about_brand 同批停调——品牌化/欢迎页品牌/viewport/PDF 卡全部源码化）
# （46_fontimg 同日退役：ComboBoxFonts.updateVisibleFontsTiles 尾部直调
#   _ohosFixUserFontTiles（渲染真路径内聚，替代轮询 wrap prototype）——
#   __lso_user_font_names 契约不变，仍由 20_bridge 注册表注入时填充）
# （45_print 同日退役：三块全量源码化——asc_Print 主链进 sdkjs fork apiBase.js
#   [OHOS: print] 分支；打印面板打印机自报进五编辑器 Print.js onPostLoadComplete
#   （printSettings.on('show') → setPrintersInfo「系统打印」）；快速打印直通进
#   五编辑器 Main.js onPrintQuick 头部 [OHOS: print] 分支（canQuickPrint=false
#   且桥在时直通 asc_Print）。原段三组轮询（等 api 原型/等 printSettings/等
#   Main controller）全部消除）
# （10_engine 同日退役（阶段 2-c）：0.95 Gateway 踢闸 wrap → 五编辑器 Main.js
#   loadBinary [OHOS: engine] 源码分支（字节注入后直接补发 asyncServerIdEndLoaded/
#   asyncImagesDocumentEndLoaded，this.api 即达——Gateway.on wrap 的 api 回退链与
#   240×250ms 轮询全消）；0.94 字体 XHR 取证（纯诊断）挪 09_fonts 段首随字体域
#   迁移时决策去留。判据 LSO_KICK_SERVERID/LSO_GW_BIN 字样保留在源码分支）
# （47_img/48_mediaunpack 同日退役：UploadImageFiles 宿主供给进 editorscommon.js
#   函数头 [OHOS: image] 分支（替代轮询覆写）；媒体预解包进同文件尾
#   [OHOS: media-unpack] 块（引擎 bundle 执行早于文档注入与图片请求，时机等价
#   于页面早期注入）；同块头部附 Base64.encode 主线程补位（stringserialize.js
#   只进 worker bundle，主 bundle 的 AscCommon.Base64 原为 undefined——详见
#   sdkjs fork c4fde67 提交说明）——回归 media-supply×3 与 img-insert×3 case
#   即语义判据）
# 45_print 紧随 40_save 之后（编辑器页序列化链，顺序仅为可读性——与前面各段无依赖）
# 09_fontpick 紧贴 09_fonts（同为字体域；它是 smoke 专用映射探针，须在 00_boot 之前
#   的**独立段**里尽早装钩子——见该文件注释）
# 注意：00_boot.js 的 `(function() {` 是**故意不闭合**的「外层头」（其后各段都在它内部），
#   本文件之前各段均如此 —— 新增段放在 00_boot.js 之后即自动位于该外层 IIFE 内
# 29_inputfocus 紧跟 20_bridge（同为宿主↔页面基础能力，与前后段无依赖）
# 58_pastebtn 追加于 57_about 后（工具栏「粘贴」宿主桥；自包含段、外层 IIFE 之外）
PARTS = ['09_fonts.js', '09_fontpick.js', '00_boot.js', '30_open.js', '40_save.js']
OUT = os.path.join(HERE, '..', '..', '..', 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice', 'ascshim.js')


def build() -> str:
    js = '/* auto-generated by make_ascshim.py — do not edit */\n'
    js += ''.join(open(os.path.join(SRC_DIR, p), encoding='utf-8').read() for p in PARTS)
    # 字体三表占位（@@FONT_*_JSON@@）已随 2-j1 移除（生成进 AllFonts.js）——
    # 残留占位即拼接错误，显式断言拦截
    for _ph in ('@@FONT_FILES_JSON@@', '@@FONT_INFOS_JSON@@', '@@FONT_RANGES_JSON@@'):
        assert _ph not in js, '字体表占位 %s 残留（应只存在于 AllFonts.js 生成链）' % _ph
    for _ph in ('@@METHOD_JS@@', '@@SHIM@@'):
        assert _ph not in js, '桥占位 %s 残留（应只存在于 ohos/bridge.js 模板）' % _ph
    return js


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

print(f'parts: {", ".join(PARTS)}')
print(f'out: {OUT}')
