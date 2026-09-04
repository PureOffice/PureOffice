# ascshim 页面适配 JS 源码

`make_ascshim.py` 按 `PARTS` 顺序拼接本目录各文件，插值 4 个占位符后生成
`entry/src/main/resources/rawfile/onlyoffice/ascshim.js`（**生成产物勿手改**）。

| 文件 | 职责 |
|---|---|
| `00_boot.js` | IIFE 引导 + cell 打开剖面（PROF 诊断，仅 spreadsheeteditor 页启用） |
| `10_engine.js` | Gateway `opendocumentfrombinary` wrap：serverId/images 踢闸（引擎闸门适配） |
| `20_bridge.js` | 字体注册表注入、CEF 方法装配（`@@METHOD_JS@@`）、`window.AscDesktopEditor`/`desktop` 对象、字节桥（postMessage）、loginpage 面板刷新桥、官方 shim（`@@SHIM@@`） |
| `30_open.js` | m7 自动验收（`?m7auto=1`/`?m7open=`，URL 显式带参才触发）、字体链修复、3.4 DI 打开链（loadConfig 补发/asc_CDocInfo/权限三刀） |
| `40_save.js` | 保存链管控（asc_Save 重写/nativeGetFileData → save:bin）、saveDocument 落盘、requestClose 覆写、错误拦截、引擎诊点 |
| `50_init.js` | 初始化尾：AscNative 等待循环（ASC_BOOT/ASC_FOUND） |

动态内容占位符（由 make_ascshim.py 替换）：
`@@METHOD_JS@@` / `@@SHIM@@` / `@@FONT_FILES_JSON@@` / `@@FONT_INFOS_JSON@@`。

段落行内注释（`// ---- 0.95 …`）保留官方源码行号与修复历史，改动请延续该风格。
