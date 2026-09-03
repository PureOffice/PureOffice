# 保存链修正方案：编辑→保存的全开源官方链（2026-09-02 全源码分析）

> 依据：`.temp/` 16 仓 + `third_party/sdkjs|core`（均 9.4.0 master）全量本地分析。
> 修正对象：本来「保存依赖闭源 ooxml addon 或服务器」的认知（POC-3 结论）与对应方案。

## 0. 一句话结论

**「编辑后模型→docx」官方链路 100% 开源，且我们真机正在跑的 sdkjs 构建产物（`sdkjs/word/sdk-all.js`）里就带着序列化器：**

```
sdkjs  BinaryFileWriter(模型) → "DOCY;v<n>;<len>;"+base64 二进制    （前端，开源）
x2t    doct_bin2docx → BinDocxRW::CDocxSerializer → docx zip       （native，纯 C++，无 V8）
```

无需闭源 addon（`Asc.Addons.ooxml`/`saveDocumentToZip`）、无需服务器、无需建服务器。

## 1. 三条官方面向「编辑→保存」的线（全貌）

| # | 线 | 字节来源 | 转换执行 | 闭源依赖 |
|---|---|---|---|---|
| 1 | 桌面发行版（ooxml 加装） | `saveLogicDocumentToZip`→`saveDocumentToZip`（addon 注入，apiBase.js:3242 契约） | 无（前端直出 docx zip，壳落盘） | **Asc.Addons.ooxml（私有）** |
| 2 | **docbuilder/旧桌面/无 ooxml** | `asc_nativeGetFileData()` = `BinaryFileWriter(模型)`（**word/api.js:13523 开源**） | **x2t `doct_bin2docx` → `CDocxSerializer`（纯 C++）** | **无（全开源）** |
| 3 | web（DocumentServer） | 服务器重放（原始文件+DB 变更→`converter.js` 调 x2t） | 服务器 x2t | 服务器线 |

**方案修正：走 #2**——线 2 的字节源与转换器全在已交付的资产里（前端 `sdk-all.js` + native `libx2t.a`），线 1 的字节源是私有注入（此前卡点），现在根本不需要它。

## 2. 证据链（本地源码钉死）

### 2.1 前端字节源（sdkjs 开源）

- `word/api.js:13523` `asc_nativeGetFileData()`：
  - 若 `isOpenOOXInBrowser && asc_isSupportFeature("ooxml")` → 走 `saveLogicDocumentToZip`（线 1）；
  - **否则** → `new AscCommonWord.BinaryFileWriter(this.WordControl.m_oLogicDocument)` → `oBinaryFileWriter.Write(true)` → `_memory.data`（DOCY 二进制）+ `window["native"]["Save_End"](header, len)`。
  - web 版 `isOpenOOXInBrowser` **恒 false**（word/api.js 从不赋值——仅 visio/slide 有赋值）→ **必然走 else 分支，即开源 BinaryFileWriter 路径**。
- `word/Editor/Serialize2.js:1875` `BinaryFileWriter` 类：
  - `Write(false)` = `GetResult()` = `WriteFileHeader(len, Version)` + `memory.GetBase64Memory()`
  - `WriteFileHeader` = `Signature + ";v" + version + ";" + nDataSize + ";"`（:1916/:1920）
  - 头部常量：`word/apiDefines.js:142` `c_oSerFormat = {Version:5, Signature:"DOCY"}`
- **真机部署验证**：`rawfile/onlyoffice/sdkjs/word/sdk-all.js` **含** `window["AscCommonWord"].BinaryFileWriter = BinaryFileWriter`（行 611605）与 `"DOCY"`（`DOCY;v4;` 字样）——**无需重新构建前端**，现有资源就能产 DOCY。

### 2.2 转换链（X2tConverter 开源，纯 C++）

- `X2tConverter/src/ASCConverters.cpp:2074` `TCD_DOCT_BIN2DOCX` → `doct_bin2docx`（`X2tConverter/src/lib/docx.h:106`）→ `doct_bin2docx_dir`(:154)：
  - `BinDocxRW::CDocxSerializer`（`OOXML/Binary/Document/DocWrapper/DocxSerializer.h:53`）
  - `loadFromFile`（DocxSerializer.cpp:323）读 `"DOCY;v<ver>;<len>;" + base64(...)`：
    - `g_sFormatSignature="DOCY"`、`g_nFormatVersion=5`、`g_nFormatVersionNoBase64=10`（`BinWriter/BinReaderWriterDefines.h:76-78`）
    - 与 sdkjs `c_oSerFormat.Signature="DOCY" Version=5`、`c_nVersionNoBase64=10`（commonDefines.js:459）**精确对齐**
  - → docx 目录 → `dir2zipMscrypt` → 成品 docx。
- **无 V8**：`CDocxSerializer` 是纯 C++ 内存模型→OOXML 序列化器（不含 doctrenderer JS 引擎）。此前 POC-2 卡点（docx→PDF 走 doctrenderer/V8）**不阻塞本条链**。
- 兄弟格式同构：cell `"XLSY"`→`xlst_bin2xlsx`（Sheets/BinReaderWriterDefines.h:44）；slide `"PPTY"`→`pptt_bin2pptx`（ASCConverters.cpp:1315）；visio `"VSDY"`→`fromVsdtBin`。

### 2.3 转换命令入口确认

- x2t 命令行方向表（`cextracttools.cpp:600+`）：`doct_bin2docx`（TCD_DOCT_BIN2DOCX）为**单文件 DOCY→docx**；`zip2dir`/`dir2zip`(TCD_ZIPDIR) 是旧式容器工具（TEAMLAB 容器/发布包解包用，`fromT` 走它）。
- **我们的调用形态**：`<Convert><m_sFileFrom>editor.docy</m_sFileFrom><m_sFileTo>save.docx</m_sFileTo></Convert>` + `auto`（格式由 `OfficeFileFormatChecker2.cpp` 内容识别：985/1205/1876/2060 行 TEAMLAB 内容识别，`AVS_OFFICESTUDIO_FILE_TEAMLAB_DOCY` = 0x1001，OfficeFileFormats.h:146）。
- 兜底形态：`editor.bin`（单文件 DOCY，可直接喂 `doct_bin2docx` 方向）。

## 3. 修正后的 B 架构保存数据流

```
编辑态（纯 JS，sdkjs 内）
  → 用户点保存 (asc_Save → …) 或 JS 直接调：
      const w = new AscCommonWord.BinaryFileWriter(editor.WordControl.m_oLogicDocument);
      const s = w.Write(false);           // "DOCY;v5;<len>;" + base64（一条字符串）
      AscSaveBridge.save(s)               // 现有桥（runJavaScript/registerJavaScriptProxy）
  → ArkTS: Base64Helper.decodeSync + 切分头/体（或整串 UTF-8 写）→ files/editor.docy
  → x2tConvertSync(<Convert>… in.docy → out.docx …)   // 已有 NAPI（libconvertershell.so）
  → 验证 zip 头（0x50 0x4B）→ files/save.docx
```

**JS 侧仅有的预备工作**：
1. `window.native = { Save_End: function(){} }` 桩（`asc_nativeGetFileData`/WordWriter 会调用 `window["native"]["Save_End"]`；纯 web 无此对象。若直接用 `new BinaryFileWriter(model).Write(false)` 可不触发 Save_End，但备桩无害）。
2. 保存触发：`checkSaveDocumentEvent`(apiBase.js:3160) 官方通路两分支都不可用（ooxml/服务器）→ **保存动作自己挂截获**：包一层 `asc_Save`/`asc_ForceSave`，在用户保存时执行上面的 Writer 调用并向 UI 反馈（MVP：工具条按钮/键 Ctrl+S 走我们的钩子）。**或者**：直接暴露「保存」按钮到 ArkTS 壳层，绕开 web-apps 的既有保存 UI（推荐——MVP 壳层做保存按钮，页内 JS 提供 `AscSaveBridge.save(result)` 前的获取函数）。

## 4. 新增 POC：POC-5（编辑→保存全链真机验证）—— **✅ 2026-09-03 真机通过**

- 步骤：
  1. 页面注入桩 `window.native`；`onPageEnd` 触发一次「模型→DOCY→桥→沙箱→x2t→docx」串行并打日志（沿用页面 setInterval 就绪轮询模式，X2TZIP 探针改造）。
  2. 真机日志确认：`DOCY;v` 头、base64 长度、`x2t rc=0`、`out.docx` zip 头（mk=0x504b）。
  3. 用 shell `hdc file recv` 拉回 `out.docx`，本地（Host）用 python zipfile 打开校验（`word/document.xml` 是否正确）。
- **通过标准**：编辑后内容（如页面上打了 "POC5" 字符串）出现在 `out.docx` 的 `word/document.xml` 中。—— **已达成**。
- **实测结果（2026-09-03 真机 192.168.1.8）**：
  - 页面轮询等 `Asc.editor.WordControl.m_oLogicDocument`（CDocument）就绪 → `asc_AddText('POC5-1788365602126')`；
  - `new AscCommonWord.BinaryFileWriter(model).Write(false)` → `DOCY;v5;292662;CwCAAgAAC…` 整串 390231B（**v5 契约**，与 x2t loadFromFile 一致）；
  - `window.AscSaveBridge.save(docy)`（registerJavaScriptProxy）→ ArkTS 写沙箱 `in.bin`（390231B 精确一致）→ `x2tConvertSync(<Convert>)` **rc=0x0** → `save.docx` 26077B（比原始文档 seq 大 29B = 标记文字），`mk=0x504b zipok`；
  - recv 后 python zipfile 校验：16 条目结构完整，`word/document.xml` 中 `<w:r><w:t xml:space="preserve">POC5-1788365602126</w:t></w:r>` —— **编辑内容进成品 ✅**。
- 关键经验（POC-5 期间踩过）：
  1. **模型就绪时序**：`Asc.editor`/`WordControl` 出现 ≠ 文档打开完成；`m_oLogicDocument` 由 `asc_docs_api.InitEditor` 创建（TrueInitEditor→asc_SaveDocumentReady 链），必须轮询 `m_oLogicDocument` 非 null（文档打开约需 1-3s，Gateway openDocument 由 index.html POC-1 模板 postMessage 驱动）。
  2. **`BinaryFileWriter(null)` 不报错**——构造不校验，`Write()` 时才 `this.Document.App` → TypeError "Cannot read properties of null (reading 'App')"；按模型就绪轮询即根治。
  3. **save() 返回非 Promise**（`registerJavaScriptProxy` 在 SDK 6.1.0(23) 传 AsyncMethodList 后 `.then` 仍不可用）：**调用本身照常生效**（副作用完整写盘+转换），只是页面端拿不到解决值——后续版本用回调/轮询确认或改 runJavaScript 通道。**日志缺行 ≠ 未执行**：以沙箱 in.bin/save.docx 时间戳+大小为准。
  4. **hdc 多设备坑**：主机在列两台设备（192.168.1.4:44959 / 192.168.1.8:33363）时**所有命令必须 `-t <addr>`**，否则报 `ExecuteCommand need connect-key`（迷惑性强）。
  5. 后续收尾：POC-5 探针与 `tryNativeSaveStep1` 为临时代码（EditorPage.ets onPageEnd/aboutToAppear），阶段 2 换成正式保存按钮与原生对话框前应撤除。

## 5. 方案性修正汇总

| 旧方案点 | 修正 |
|---|---|
| 「编辑→保存」需闭源 addon/服务器 | **需**：BinaryFileWriter(DOCY)→x2t CDocxSerializer，全开源 |
| 保存器缺失（`saveDocumentToZip is not a function` 死巷） | 放弃 saveDocumentToZip 路径；改 `asc_nativeGetFileData`/`BinaryFileWriter` 路径 |
| PDF 输出卡 V8 | 与保存链无关；docx 保存纯 C++。PDF 输出仍需 doctrenderer（V8）——另行评估 |
| 前端资源需重新构建加 addon | 无需重新构建：现有 `sdk-all.js`（rawfile）已含 `AscCommonWord.BinaryFileWriter` |
| 桌面保存=前端字节+壳落盘（旧考证） | 细化：壳落盘的字节=DOCY 二进制（非 ooxml 时），native 层再经 x2t 转 docx——与我们的方案一致 |

## 6. 关联文档

- `docs/ONLYOFFICE_OHOS_PORT_DESIGN.md`（总体设计；本文件为其 §4.2 保存段的修正）
- 记忆：`onlyoffice-save-chain-docy`（全链结论）、`onlyoffice-poc3-save`（旧结论，已被部分推翻）、`onlyoffice-poc2-convert`（x2t 实测）
