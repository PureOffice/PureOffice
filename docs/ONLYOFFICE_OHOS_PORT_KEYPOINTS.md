# ONLYOFFICE OHOS 移植 —— 方案关键点（不可变决策与实测数据流）

- 日期：2026-09-03（迭代 1 闭环后定稿）
- 作用：接手者的「不要推翻的东西」清单；与 `ONLYOFFICE_OHOS_PORT_DESIGN.md`（总设计）配合阅读

---

## 0. 一句话架构

**ArkTS 薄壳（ArkUI）包系统 ArkWeb（Chromium 固件自带）→ 渲染 ONLYOFFICE web-apps/sdkjs 编辑器；华为不提供可嵌入 libcef，编辑器 90% 是 Web（web-apps），core(x2t) 作为 native .so 经 NAPI 供 ArkTS 调用，负责「Office 格式 ↔ 内部格式」转换。**

## 1. 三条不可变约束（选型依据）

1. **B 路线（系统 WebView）是唯一低成本路径**：OHOS 无「应用可链接的独立 libcef」（`chromium_cef` 仅合编进系统 ArkWebCore.hap，桥接层在 ArkWeb 实际路径不启用）；Electron 路径（`openharmony-sig/electron` → VSCodium 背书）可行但需自编译维护 Chromium 整线，且桥仍是异步 IPC——对 ONLYOFFICE 收益 ≈ 0。
2. **异步桥是常驻形态**：`registerJavaScriptProxy`（JS→ArkTS）+ `runJavaScript`（ArkTS→JS）都是异步。ONLYOFFICE 桌面版同步 V8 原生桥（同步剪贴板/原生打印/拖拽/拼写）须重写为异步或降级——**打开/编辑/保存/导出不受影响（实测）**。
3. **引擎版本随固件（SDK 6.1.0(23)），不可 pin/patch**；web-apps/sdkjs/core 三者在打包时对齐同一 ONLYOFFICE 版本——当前双仓库均 **release/v9.4.0**（`Serialize2.js` 与官方 master md5 一致：`2cfea82350fb91ae82db4ac38b1e73df`）。

## 2. sdkjs ↔ core 分工（为什么 core 是必选项）

- sdkjs(JS) **只认内部二进制格式**（DOCY/XLSY/PPTY 文档二进制）；core(x2t, C++) 负责 `docx ↔ DOCY` 等全部转换（桌面版调 `x2t` 独立转换器）。
- 编辑的每个键击/选区/滚动/排版/Canvas 绘制 100% 在 sdkjs 内完成，**不过桥**；桥只承担「文档级一次性 I/O」。
- web 构建的 sdkjs 无 `CDocument.fromZip`（官方源码树全库无定义，visio 除外）——**纯 Web 直开 docx/ZIP 不可行**，必须走 core 转换（本项目打开链已闭环）。

## 3. DOCY 二进制家族（最核心的格式知识）

| 变体 | 头格式 | 谁产出 | 谁能读 |
|---|---|---|---|
| **v5** | `DOCY;v5;<len>;` + base64（纯 ASCII 文本） | 页面 `BinaryFileWriter(模型).Write(false)`；x2t 的 **`.doct` 后缀是 PK zip 退化，不可用** | 页面 BinaryFileReader（v5 分支）/ x2t `doct_bin2docx`——**双端互认（保存链验证）** |
| **v10** | `DOCY;v10;0;` + raw 二进制（**无 base64**） | x2t `docx2doct_bin`（`.bin` 后缀自动分派，core docx→内部格式的默认产物；DocumentServer 服务器同样产 v10） | 页面 BinaryFileReader 的 v10 分支（`c_nVersionNoBase64=10` 走 raw 直读）+ x2t 自读 |

- 版本数字由 `getbase64DecodedData` 动态解析（`AscCommon.CurFileVersion`），写/读两侧都用同一套序列化表（`BinReaderWriterDefines.h`：`g_sFormatSignature="DOCY"`、`g_nFormatVersion=5`、`g_nFormatVersionNoBase64=10`）。
- **页面拿到 v10 后，传给 `openDocument({bSerFormat:true, data})` 的 `data` 必须是 `Uint8Array`**（与 DocumentServer 前端 HTTP arraybuffer 形态一致）。传 binary string（atob 结果）时：一种运行 Read 静默返回 true 但模型为空（`cur` 停在头后 12、`pc=-1`），一种在 ReadMainTable 处**死循环卡死**（独立文档对象直读 45s 无返回）。**本坑实测两次形态，务必用 Uint8Array。**

## 4. 打开链最终形态（迭代 1 已闭环）

```
用户文件 docx（PK 字节）
  → 页面 openDocument hook 检出 PK && AscConvertBridge 就绪
  → ascAbToB64：Uint8Array → base64（上桥，注册为 window.AscConvertBridge.convertDocxToDocy）
  → ArkTS AscConvertProxy.convertDocxToDocy：
       写沙箱 open-in.docx → x2tConvertSync(<Convert><m_sFileFrom>…</m_sFileFrom>
                                  <m_sFileTo>…/open-in.bin</m_sFileTo></Convert>)
       （.bin 后缀 → TCD_DOCX2DOCT_BIN；rc=0 成功 / 0x8004350 失败）
       → 读回 open-in.bin(252713B) → bufToB64（base64 信封）
  → runJavaScript(`window.__oobDocy('<b64>')`)
  → 页面：atob → Uint8Array → e8.openDocument({bSerFormat:true, url:'', data:arr})
  → BinaryFileReader 完整解析 → 8 页/俄语/表格渲染、无异常
```

- **传输铁律**：含任意字节的数据（v10 raw）ArkTS→页面**必须 base64 信封**（`bufToB64` ↔ 页面 `atob`）；raw 字符串直传会损坏（实测页面 FNV ≠ 磁盘）。`b64ToBuf`/`bufToB64` 为 ArkTS 手工实现（无内置 base64），在 EditorPage.ets。
- **页面注入**（index.html）：打开任何编辑器之前设 `window.Asc.Addons.ooxml = true`（否则 `asc_isSupportFeature("ooxml")=false` → 误走 native-only `OpenDocument` TypeError）。

## 5. 保存链最终形态（POC-5 / 迭代 1 均验证，详见 ONLYOFFICE_SAVE_CHAIN_REVISED.md）

```
页面模型 → BinaryFileWriter(模型).Write(false) → "DOCY;v5;<len>;"+base64
  → window.AscSaveBridge.save(docy)（registerJavaScriptProxy）
  → ArkTS AscSaveProxy：写 in.bin → x2tConvertSync(doct_bin2docx) → save.docx
验收：asc_AddText('OOH-<ts>') 插入 → 最终 save.docx document.xml 同时含
     OOH- 标记 + 原文内容（1017 w:t = 原文 1016 + 标记 1）
```

## 6. 格式↔后缀分派速查（x2t, cextracttools.cpp）

| 源 | 后缀 | 转换器 | 产物 |
|---|---|---|---|
| docx | `.bin` | TCD_DOCX2DOCT_BIN | **v10 raw**（打开链用） |
| docx | `.doct` | TCD_DOCX2DOCT | ⚠️ 实测输出 PK zip（退化），**不可用** |
| DOCY | `.docx` | TCD_DOCT_BIN2DOCX | docx（保存链用） |
| xlsx | `.bin`/`.xlst` | TCD_XLSX2XLST(_BIN) | XLSY-v10/v5（迭代 2） |
| pptx | `.bin`/`.pptt` | TCD_PPTX2PPTT(_BIN) | PPTY（迭代 2） |
| pdf 转换 | —— | doctrenderer 需 V8/fetch，当前未启用 | —— |

## 7. 诊断探针体系（日常开发必备）

- **页面侧**（index.html）：`window.__pf`（2000 条上限，主动 push `od:/ood:/p5:/f3:/o0:/seE:` 等关键事件；`seE` 为 sendEvent 捕获，**asc_onPaintTimer 已过滤防洪泛**——若需恢复注释处）。页面 `console.error` 经 EditorPage.onConsole 转 hilog（`[web]` 前缀，E 级稳定）。
- **壳侧**（EditorPage.ets `startProbe()`）：每 2s `runJavaScript` 读页面状态 → 沙箱 `files/probe.txt` 单行覆盖。关键字段：`pf/pfTail`（pf 尾部 -400，解决 2000 截断）、`pages`（pc=Get_PagesCount、pr=绘制页、ld=IsLoadingDocument、mx=模型 Objects 数）、`title`、`tag`、`xhr`。
- 常见判读：
  - `ood:got len=252713 head=DOCY;v10;0;` = 转换+传输正常
  - `p5:arr=252713` = Uint8Array 输入路径生效
  - `o0:drw:false`（m_oLogicDocument 未建）在打开瞬间是**正常**的（InitEditor 在 openDocument 内才建模型）；`o0 = 独立 CDocument 直读 o3` 卡死即 v10 问题
  - `f3:`（FNV-1a 32 位，页面 string 语义）对比哈希**必须用 node 同语义复算**（JS float 乘法溢出，Python 精确整数 hash 结果不同属正常假警报）

## 8. 构建与部署（迭代 1 沉淀）

```bash
bash scripts/onlyoffice/deploy_ohos.sh --probe     # 打包+装机+重启+读探针（日常一条命令）
```

- **禁止 `hvigorw clean`**：会删 `build/core3d`（libx2t.a 等），native 链断，重建 10+ 分钟：
  `python3 scripts/onlyoffice/core3d/gen_cmake.py && cmake -S build/core3d -B build/core3d/build -DCMAKE_TOOLCHAIN_FILE=<abs path>/scripts/onlyoffice/core3d/ohos-arm64.toolchain.cmake && cmake --build build/core3d/build -j$(nproc)`
- **增量打包校准**：改 .ets 后行为没变 → `strings entry/build/.../entry-default-signed.hap | grep <新字符串>` 确认进包（踩坑：modules.abc 未刷新）。
- hdc **多设备必须 `-t 192.168.1.8:33363`**；截图 `snapshot_display` 后缀必须 `.jpeg`。
- 签名复用 wineohos 证书（build-profile.json5 signingConfigs）。

## 9. 下一步（迭代 2/3）注意点

- xlsx/pptx 打开链与 docx 同构：`fileType` 分派 → `XLSY;v10;0;`/`PPTY;v10;0;`（页面 reads 均走 Uint8Array 路径；`SerializeWriter.js:1067` 已见 `"PPTY;v"+c_nVersionNoBase64+";"` 头封装）。
- 保存/报告回 x2t：`xlst_bin2xlsx`/`pptt_bin2pptx`（convertershell 26 库已含）。
- 大文档（≥10MB）base64 过桥的阈值评估（迭代 3 范畴）。
- 正式化时瘦身 index.html 诊断打点（保留 `__pf` 骨架即可）。

## 10. 迭代 2 实测沉淀（2026-09-03 真机 192.168.1.8）—— 打开链 v11

**Gateway 协议（webapps `apps/common/Gateway.js`）四个坑，必读：**
1. 命令名是 **驼峰**：`openDocument` / `openDocumentFromBinary`（`commandMap` 精确匹配；全小写 miss——`go:"-"` 实测）。
2. **jQuery `$me.trigger('xxx', data)` 会把「数组」展开为多参数**——`loadBinary` 只收到数组**首元素**（`type=[object Number]` → 字节全灭）。二进制数据必须包成**对象** `{bytes: arr}`（对象不展开）。
3. **`openDocumentFromBinary` 有 postMessage 对象形态专路**（Gateway.js:187 `data.command==='openDocumentFromBinary'` → `handler.call(this, data.data)`）；`init` 可以继续用 JSON 字符串形态。
4. **launch 等待条件勿含 `window.DE`**——`window.DE` 仅 DesktopEditors 原生渲染进程注入；WebView 恒缺 → 等待 500ms 死循环 → `init` 永不发出 → `loadConfig` 不跑 → toolbar/UI 永不构建（页面模型却可直连加载，极易误诊）。`LAUNCH_TICK {"de":false}` 即此。

**打开链身份（三层 hook，缺一不可）：**
- 实例层：`hookEditor(window.Asc.editor)` / `hookEditor(window.editor)`（800ms 轮询，两引用可能不同实例）。
- **原型层**：`AscCommon.*EditorApi.prototype.openDocument`（遍历 `window.AscCommon` 枚举）——cell 的 `Viewport.getApi()` 实例有 **own `openDocument`**（实例层 hook 不到时由 `Object.getPrototypeOf(this)===SpreadsheetEditorApi.prototype` + `hasOwnProperty` 判定；`OELF2` 证据有 `sam=true pd2=1 own=true`）。
- PK 检测**自行实现** `__isPK`（`AscCommon.checkOOXMLSignature` 只在 word 侧定义，cell/slide 恒 false）。

**三层闸门（cell/slide 直连打开白屏主因，`cell/api.js:3362` `_openDocumentEndCallback`）：**
```
if (isDocumentLoadComplete || !ServerIdWaitComplete || !FontLoadWaitComplete) return;
```
- `ServerIdWaitComplete` 由 `asyncServerIdEndLoaded()`（apiBase:1487，dummy coauth 语义）置位。
- `FontLoadWaitComplete` 由 `_loadFonts(fonts, cb)` 完成回调置位。
- **页面 `__oobDocy` 已内置踢闸**（`asyncServerIdEndLoaded()` + `_loadFonts([], cb)`，均幂等）。
- word 侧无此问题（word 的 contentReady 有旁路 `asyncImagesDocumentEndLoaded`（word/api.js:8135）。
- 剩余断点（10/31 晨）：launch 空文档 + loadBinary 重开 → toolbar✅ 但 WorkbookView 停留旧空模型（cells 不画）；launch 只 init + loadBinary 首开 → grid✅ 但 toolbar 缺（toolbar 由 Gateway loadDocument 建）——**cell 单机不支持「二次打开」语义，需 patch cell api 使重开重建 WorkbookView（待办）**。

**构建产物级：**
- CSS：宿主 `lessc` 预编译 `resources/less/app.less` → `resources/css/app.css`（三编辑器；`precompile_css`（旧 pack_web.py 时代；现 CSS 由官方 grunt 构建产物提供））。
- `.wasm` → `application/wasm` MIME（rawfileLoader.ets）——fonts.js wasm 流式编译必需。
- `PFLIM 400→15000` + `PFO_P1..P7` 分段（2500 字符各段）。
- 诊断 fallback：web console 全量落盘 `files/web_console.txt`（EditorPage onConsole append；hilog 在部分环境抓不到 [web]）。

**页面错误即弹窗干扰辨真伪**：`gwTest`（8B zeropad）曾污染诊断（cell 解析零 bytes → 弹窗）——**诊断注入别喂格式无效数据**。

## 11. 正规化打开链（2026-09-05 三格式全链复核沉淀）—— cell/slide DI 链 + 引擎闸门

> §4 为 POC 链历史；本节为正规化链（M3-M7）最终形态。word（docx）走官方
> `loadDocument({doc})` 即闭环；**cell/slide 必须走 ascshim DI 链**（官方
> loadDocument 无服务器环境崩 'lang'）。

**链路**：欢迎页 open:recent → ArkTS 沙箱读源文件 → x2t（源后缀分派
docx2doct_bin / xlsx2xlst_bin / pptx2pptt_bin）→ base64 信封 → 页面
`openDocumentFromBinary`（官方 Gateway 专路 → Main.loadBinary →
asc_openDocumentFromBytes）。

**cell/slide DI 链四个必修点（ascshim 3.4 段）**：
1. `Main.loadConfig({config})` + **遍历 controllers 补发 loadConfig**（
   Gateway.trigger('init') 非公开 API；word 无需补——LSO_INIT_ALL_OK n=0 佐证，
   cell/slide 必须，否则 FormulaDialog 等 `appOptions.lang` 级联崩）。
2. `Asc.asc_CDocInfo` 装配 + `api.asc_setDocInfo`——`put_Format` 必须与 URL
   fileType 一致（XLSY/PPTY 签名校验，不符 "打开文件错误"）。
3. `CDocsCoApi` 补 `onFirstLoadChangesEnd` dummy（docscoapi.js:187 auth 离线
   分支；**必须在 asc_setDocInfo 前**）。
4. 权限链（工具栏/菜单的 mode 电源）：先置 `_m.permissions`、`_m.document`、
   `_m.appOptions.spreadsheet`，再构造 `asc_CAscEditorPermissions`
   （Success/Edit/buildVersion=页面版本）`onEditorPermissions.call`，最后
   `api.asc_getEditorPermissions()`。**⚠️ slide 的 onEditorPermissions 读
   `this.document.info`（Main.js:1412 canFavorite）**——未设 `_m.document` →
   崩 reading 'info' → 尾段 `asc_LoadDocument` 跳过 → 编辑器空白（UI 组件有、
   画布空、载入遮罩挂）。cell 读 appOptions.spreadsheet.info、word 走
   loadDocument（501 this.document=data.doc），二者无此问题。

**引擎闸门（`_openDocumentEndCallback`，模型已装载但 GUI 定型"加载中"）**：
- cell（cell/api.js:3362）：`!ServerIdWaitComplete` 等；
- **slide（slide/api.js:5835）：ServerIdWaitComplete + ServerImagesWaitComplete
  双闸**；
- 服务器链这两个 flag 由 CoAuthoringApi 服务器通知置位，无服务器链永不发 →
  **ascshim 0.95 段 wrap `Gateway.on('opendocumentfrombinary')`，在字节注入
  返回后踢闸**：`asyncServerIdEndLoaded`（apiBase:1486 基类公共方法）+ slide
  另踢 `asyncImagesDocumentEndLoaded`（slide 专有，api.js:5775）；
- 判据：日志 `PROF_GW_BIN → PROF_KICK_SERVERID（→ PROF_KICK_IMAGES）→
  PROF_GW_BIN_DONE` 全序即打开链完成。

**判据坑**：PROF_SNAP 的 main/api/ViewsTb/ctrlTb 判据系 cell 语义（wbModel 等），
word/pptx 下恒 false 属探针局限，非功能异常——以截图/产物为准。

**样本教训**：samples/sample.pptx 原为 POC2 极简产物（`<p:spPr/>` 无坐标、
bodyPr 空 → 引擎渲染堆字形），已重制为带 xfrm/off/ext/bodyPr 的规范布局
（4958B）；「渲染内容怪异」先验样本结构再疑引擎。

## 12. 字体链最终定论（2026-09-05 默认中文 A+B 方案，已真机）

**运行时脚本矩阵**（三份共存、职责不同——一切分析必须先分清）：
- `sdk-all-min.js`（app.js:58 require）：**web 主体**——AscFonts 创建（IIFE）、
  `AscFonts.load`（loadScript `libfont/engine/fonts*.js`）、FontPickerByCharacter、
  `asc_insertSymbol` 等；**无 CFontFileLoader/LoadFontAsync/LoadFontBase64**。
- `sdk-all.js` 28MB（apiBase.loadSdk → loadScript）：**Externals 段**——
  `checkAllFonts()` eval 即执行（读 `__fonts_files/__fonts_infos` 建 13 个
  CFontFileLoader，随后 **delete 两张表**——PROF_FONT `infos=0` 即此，非缺表）
  + CFontFileLoader/LoadFontAsync（桌面/ web XHR 双分支）。
- `fonts.js`（wasm 包装）：FT_*/HB 低层；`fonts_native.js` 为 C++ 引擎适配层。

**根因**：LoadFontAsync 的调用者只在**渲染期按需链**（FontPickerByCharacter.
checkText / asc_insertSymbol / watermark → LoadDocumentFonts2 → CheckFontLoadStyles
→ LoadFontAsync）。9.25MB HOS SC XHR 晚于首帧渲染（实测 8109/8165 次 face=null；
~15s 后字节到达，face=14231976 / gid中=7517 全正常）→ 首帧方块、重绘后正常。
「切语言后恢复」本质即触发重绘、字体已就绪。LoadFontBase64 桥/预取 hook 零触发
——目标函数不在调用路径上。

**方案 A（ascshim 09_fonts.js，真正效）**：页面头预取字节（绝对 URL
`http://localhost/onlyoffice/fonts/` + 相对兜底；rawfile 为 **pre_xor 加密态**
→ 装填前 32B XOR guidOdttf 还原）→ 哨兵等 28MB `checkAllFonts` 建表 →
`FontStream` push `g_fonts_streams` + `SetStreamIndex` + `Status=0` +
`CreateNativeStreamByIndex`（wasm 内存转移）。此后任何 LoadFont 立即有流——
不依赖任何异步加载链，竞态免疫。**第 3 张注入表 `__fonts_ranges` 必须存在**
（FontPicker Ranges 空 → 回退即失败）；FONT_INFOS/AllFonts 契约同源
（build_editors_ohos import 单点）。

**方案 B（build_editors_ohos `make_cjk_subset`）**：GB2312 全集+ASCII/Latin-1+
CJK 标点+全角 → 9.26MB 子集 → **1.93MB/7641 字符**。幂等（产物 mtime 复用），
断言链：尺寸 100KB~5MB + cmap 含 4E2D/41（防空壳子集）+ pre_xor 返回值。
pyftsubset 依赖 fontTools（已录注释）。

**验收键**：`FONT_WARM_BYTES→FONT_WARM_FILLED`（装填）→ 首帧 `PROF_LF ...
face=非null gid中=369 load中=0 err=0`（子集后 GID 重排 369；修复前 face=null
8109 次）；`FACE-NULL=0`（实测 18893 次全有效）。

**遗留观察项**：`PROF_HBS` 仍返回 null（探针 `arguments[0]` 取的是 textShaper
对象、txt 恒空，参数读取存疑；且 hb=3376640 已有效、GID/FT_Load 全通）——
正文字形走 CacheGlyph 路径无黑字，不阻断中文渲染，如再遇 HBS 路径场景先从
textshaper.js:124 实参开始取。

## 12.5 宋体修复与字体选择语义（2026-09-05 扩展，已真机✓）

**宋体渲染修复**（用户：选「宋体」输入显示的是无衬线黑体样式）：
- 根因：`FONT_INFOS` 宋体族行（宋体/SimSun/Songti SC/simsun.ttf）全映射下标 12
  的 HarmonyOS_Sans_SC.ttf（黑体文件）——选了宋体=用黑体取字形。
- 真宋体入库：HarmonyOS SDK previewer 自带 `NotoSerifCJK-Regular.ttc` 是 **CFF
  轮廓**（wasm libfont 精简 freetype FT_Open_Face 失败——老契约，勿回退）；
  `otf2ttf`(>=0.2, pip3 install --break-system-packages otf2ttf) CFF→glyf
  静态化（**TTC 面序 JP/KR/SC/TC/HK → SC=face_index=2**，命令固化为
  build_editors_ohos.py FONT_SRC_BY_FILE 注释）→ 全量 31.5MB **不入库**
  （按构建可复现原则：全量源缺失时 subset 幂等复用——git clone 后无需重转）→
  `make_cjk_subset` GB2312 子集 → **5.5MB 入库** `NotoSerifCJK-SC.subset.ttf`。
  FONT_FILES 追加 `NotoSerifCJK-SC.ttf`（下标 13）；宋体族四行 12→13；
  黑体族（黑体/雅黑/Noto Sans/HarmonyOS Sans SC/simhei/msyh）仍 12；
  `make_cjk_subset` 泛化（参数化+上限放宽 6MB+源缺失复用）；缩放精灵取源
  subset 优先；09_fonts.js 单字体装填→**双 CJK 清单**（黑体+真宋体）。

**★ 字体内部 name 契约（2026-09-05 真机实证，最重要的教训）**：字体文件
name 表（ID1/16 family）**必须等于 FONT_INFOS 注册行名**（引擎把'宋体'归一为
'SimSun'）。第一版宋体包（内部名 'Noto Serif CJK SC' ≠ 注册名）→ 渲染槽失效
→ **整个 run 空白（含拉丁 'dd'，run 级非字形级）**。修复=构建链 `family` 参数
→ `rewrite_font_name`（fontTools setName ID1/2/3/4/6/16/17 + 断言，幂等）。
黑体原文件内部名='HarmonyOS Sans SC' 与注册行名恰一致——此前从未暴露该契约。

**字体选择语义（产品行为说明，与 Word/官方桌面版一致）**：
- 工具栏字体选择器设置**西文字体**（ascii/hAnsi），**中文字体（eastAsia）由
  docDefaults 的 `w:eastAsia="SimSun"` + `w:lang="zh-CN"` 决定**（空模板与
  sample/docDefaults 规范化已设置）。
- 因此「选择器=Times New Roman，中文显示宋体」**符合预期**（Word 同行为）；中
  文要换字体需文档 eastAsia 声明（或后续接「字体→高级」eastAsia 选项——当前
  移植未接，属合理缺口）。
- 验证现场：Unnamed 空模板/docDefaults 中文默认=宋体；demo-cn.docx docDefaults
  `ascii=Arial eastAsia=SimSun`（run 无覆盖→全文宋体=正确）；真机 18:52 验证
  SIMSUN run 渲染衬线正常、字体下拉=SimSun 一致。

## 13. 字族下拉无法展开（2026-09-05 终局：官方 web 语义的资源侧修复，已真机✓）

**链路（全链实证）**：`ComboBoxFonts.onBeforeShowMenu`（store 空 → preventDefault，
ComboBoxFonts.js:661）← `fillFonts` 卡在第一步 `loadSprite(callback)`
（ComboBoxFonts.js:556——精灵不回调则永无 store.set）← `CThumbnailLoader.load`：
官方 web 语义（Desktop.isActive=false）→ `supportBinaryFormat=true` → XHR
`sdkjs/common/Images/fonts_thumbnail_ea@2x.png.bin`（+`.bin` 由组件自拼）——
**资源缺失** → 浏览器对 404 仍触发 `xhr.onload` → **404 页字节被当 RLE 解码**
（12B 头 width 爆炸）→ `createImageData(巨值)` Out of memory 抛 RangeError
（真机日志 `Uncaught RangeError ...ComboBoxFonts.js:243`）→ 菜单渲染崩 → 展开
失效。

**修复（两级，均官方协议，无注入/无覆盖）**：
1. **数据侧**：ascshim 30_open 打开链补发 `api.sync_InitEditorFonts(CFont 数组)`
   （官方 LoadDocumentFonts 同构语义，sdk-all.js:244037；双条件轮询：`g_font_infos`
   就绪 ∧ `NotificationCenter._events['fonts:load']` 订阅就位——一次性早发命中
   两个时机盲区，实测 LSO_UI_FONTS n=18；`__lsoFontsSent` 防重）。
2. **资源侧**：build_editors_ohos `make_fonts_sprites`——官方 RLE 格式精灵
   （12B 大端头 width/heightOne/count + 0x00,len 透明 run / 其余=alpha 字节）
   `fonts_thumbnail_{ea,_}@<ratio>x.png.bin` ×5 ratio，每格以该字族字体文件
   PIL 渲染「字族名样例」（18 格 300×28×ratio），仅记录待升级点：PIL 渲染字形
   预览为黑字蒙版；后继可切官方桌面 getFontsSprite（native 通道）。

**弃用记录（勿回退）**：曾以覆盖/桩 Common.Controllers.Desktop 实现——
① 官方 Desktop.js:786 在 requirejs 模块中晚于 ascshim 定义会覆盖桩；
② `window.native` 语义会把引擎 `AscFonts.load` 切到 native 分支
（sdk-all-min.js:49957——wasm fonts.js 不加载）；
③ `isActive=true` 窗口会激活桌面语义启动链（应用启动崩溃，实测）。
正路 = 官方 web 语义（isActive=false）+ 资源产物，或完整桌面语义迁移
（见 §14 路线）。

**验收键**：`PROF_CLICK_CAP`（点击到组件）+ `PROF_PREV`（prevent 判定）+ 菜单
DOM；修复后真机截图：18 字体项列出、正文中文字形正常、文档语言=中文-
中华人民共和国。

## 14. B 架构适配路线（2026-09-05 用户探讨：fork 定制 vs 当前 ascshim）

三种 hack 来源：① 产物/资源缺失（仓库/构建链补齐——非源码问题）；
② 语义错配（引擎/ web 对无宿主假设——源码级修整收益高）；
③ 宿主接口缺失（B 架构缺 C++ 那层——**官方本就为宿主设计了接入面：
desktop-apps 渲染层**）。
**推荐**：fork 对象 = `third_party/desktop-apps`（非 sdkjs/web-apps——后者
release 升级会冻结）；构建切官方 --desktop 语义；B 架构补 native 三件套
（字体精灵/loadjs/AllFonts——KEYPOINTS 既有规划）。在「native libfont 编译件」
到位后立项；当前 ascshim 方案与之一致（ascshim 的适配内容即官方渲染层同构）。## 15. 默认中文三修复（2026-09-05，#66/#67/#68，真机✓）

### 15.1 欢迎页语言 = URL lang 参数（loginpage 唯一入口）
- 官方 loginpage：`utils.js:541-553` `getUrlParams()` 默认 `{lang:'en'}`；`locale.js:316`
  页面加载 `(getUrlParams()['lang'])` 初始化（correctLang：`-`→`_`，l10n 键 `zh_CN`）。
- 三处欢迎页跳转必须带 `?lang=zh-CN`：EditorPage.homeUrl（#63 已带）、
  ascshim 30_open.goBack、ascshim 40_save.requestClose 覆写（本次补上——用户
  「关闭后变英文」即这两处）。
- 验证（真机 192.168.1.8）：点右上角 X（slot-btn-close）→ requestClose 覆写 →
  欢迎页全中文 ✓。uitest 点击坐标：`dumpLayout` JSON 的 bounds 物理像素。

### 15.2 新建 word 默认语言 = 空模板 docDefaults（链：模板→x2t→doct_bin）
- `make_empty_templates.py`（挂 grunt-build.sh / deploy_ohos.sh）扩展生成 empty.docx：
  `templates_src/empty.docx`（3 部件骨架，仓库跟踪）+ **新增 word/styles.xml**
  （docDefaults 全段照抄 demo-cn.docx：rFonts ascii=Arial eastAsia=SimSun、
  sz 22/22、w:lang val/eastAsia="zh-CN" bidi="ar-SA"）+ Content_Types Override +
  **word/_rels/document.xml.rels**。
- **★ 关系层级坑（本轮最痛，勿重犯）**：`styles.xml` 是 **word/document.xml 的部件
  关系**，必须挂 `word/_rels/document.xml.rels`（rId1 styles）——**不是包级
  `_rels/.rels`**！第一版挂包级 → dangling（包根无 styles.xml）→ x2t 当孤立部件
  丢弃 → doct_bin(768B) 无 docDefaults → 状态栏 still en-US（真机实锤）。
  修正后：doct_bin 1086B、状态栏「中文 - 中华人民共和国」、默认字体 Arial/11（=sz22）。
- 判据（勿用 LCID 字节搜索）：doct_bin 语言非 LCID 序列化（搜 0x804 无效），
  以 bin 体积变化 + 引擎状态栏/默认字体行为为准；先 unzip HAP 验证 rawfile 进包。
- deploy_ohos.sh 新增 `make_empty_templates.py` 步骤（与 make_ascshim 并列），
  防止模板源改动不进包。

### 15.3 隐藏编辑器左上角 ONLYOFFICE logo（官方 branding 语义）
- Header.js:798 `this.branding = this.options.customization`；
  :886-888 `branding.logo.visible===false → #header-logo.addClass('hidden')`。
- 修法：ascshim `editorConfig.customization` 加 `logo: {visible: false}`（与
  goback/close 同机制，非 DOM hack）。真机✓（工具栏最左只有打开/撤销/重做）。## 16. 欢迎页导航精简终态（2026-09-05，#68 同批，1.4 真机✓）

欢迎页（loginpage）左侧导航隐藏三项——均为「官方语义未接入的入口/或纯装饰」：
- **云服务**（`#idx-sidebar-portals`，panelconnect 灌入 providers/添加云 + 其后 devider
  分隔线）：桌面云连接功能，离线无 providers 恒空；一起隐藏防孤线残留。
- **设置**（`.tool-menu a[action="settings"]` 父 menu-item）：官方设置面板
  （语言/主题等），本产品定为默认 zh-CN 且无桌面设置存储。
- **模板**（`.tool-menu a[action="templates"]`，2026-09-05 用户反馈"模板页没东西"
  后决策隐藏）：官方模板列表走桌面原生桥 `window.sdk.LocalFileTemplates()`；
  离线 web 语义无此桥 → 恒「未找到结果」。官方模板资源在
  `third_party/desktop-apps/common/templates/<LANG>/`（EN 19M，文件为**加密编码名**
  的 .dotx 等，如 `[32]I5UWM5…======.dotx`——名称/预览映射在原生层，离线取不到；
  故即使拷贝文件，列表也只会是编码怪名——完整实现无收益，用户决策隐藏）。

实现：40_save.js §3.10 MutationObserver（panels.js $(document).ready 渲染后隐藏、
防 re-render 弹回；`.closest('.menu-item')` 精确到项，不动其余入口——官方无配置
开关，模板静态渲染，故适配层处理）。欢迎页当前 nav：主页 / 打开本地文件。
