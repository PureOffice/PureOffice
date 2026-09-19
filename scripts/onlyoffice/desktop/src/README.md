# ascshim 页面适配 JS 源码

`make_ascshim.py` 按 `PARTS` 顺序拼接本目录各文件，插值 4 个占位符后生成
`entry/src/main/resources/rawfile/onlyoffice/ascshim.js`（**生成产物勿手改**）。

| 文件 | 职责 |
|---|---|
| `09_fonts.js` | CJK 字体流保供（rawfile 预取 + XOR 解码 + `g_fonts_streams` 装填，中文方块根因修复） |
| `00_boot.js` | IIFE 引导 + 公共工具（`__lsoB64` Uint8Array→base64 单点） |
| `10_engine.js` | Gateway `opendocumentfrombinary` wrap：字节打点（LSO_GW_BIN）+ serverId/images 踢闸（引擎闸门适配） |
| `20_bridge.js` | 字体注册表注入、CEF 方法装配（`@@METHOD_JS@@`）、`window.AscDesktopEditor`/`desktop` 对象、就绪探针（isLoadFullApi → LocalStartOpen）、loginpage 面板刷新桥、官方 shim（`@@SHIM@@`） |
| `30_open.js` | m7 自动验收（`?m7auto=1`/`?m7open=`，URL 显式带参才触发）、3.4 DI 打开链（loadConfig 补发/asc_CDocInfo/权限三刀） |
| `40_save.js` | 保存链管控（asc_Save 重写/nativeGetFileData → save:bin）、saveDocument 落盘、requestClose 覆写、错误拦截（sendEvent -25 单点） |
| `50_init.js` | 初始化尾：AscNative 等待循环（ASC_BOOT/ASC_FOUND） |
| `51_scrollpad.js` | 触摸拖拽滚动条（触摸输入在窄条边界 ±3px 内命中判定不稳定 + sdkjs 桌面滚动条判定零容差，capture 层按坐标含外扩接管：pointer 流转发引擎处理器、touch 流仅拦截） |

动态内容占位符（由 make_ascshim.py 替换）：
`@@METHOD_JS@@` / `@@SHIM@@` / `@@FONT_FILES_JSON@@` / `@@FONT_INFOS_JSON@@`。

段落行内注释（`// ---- 0.95 …`）保留官方源码行号与修复历史，改动请延续该风格。

纪律（2026-09-05 用户要求）：
- 产品路径不得凭界面元素/固定延时猜业务状态；等状态只允许官方引擎对象/事件
  （isLoadFullApi / Common.Gateway / asc_onDocumentContentReady …）。
- 自动验收（m7 段、smoke prof-snap）为测量用途，走 URL/启动参数双重门控，
  产品 URL 无参数即不触发；改动 m7 段请保持门控不变窄。
- 轮询必须带页门控（`/main/index.html`）+ 重试上限（默认 300 次 ≈ 60-90s）。
