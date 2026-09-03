# ONLYOFFICE DesktopEditors → 鸿蒙 Pad 移植设计文档

- 日期：2026-09-02
- 目标产物：鸿蒙 Pad（商用 HarmonyOS NEXT，真机 `192.168.1.8:33363`）上的 ONLYOFFICE 办公套件
- 源项目：<https://github.com/ONLYOFFICE/DesktopEditors>（AGPL-3.0）
- 参考工程：`../wineohos`（HAP 宿主范式）、`../qemuohos`；OHOS 侧参考件 `openharmony-sig/qt`、`openharmony-tpc/chromium_cef`

---

## 0. 一句话结论

**别保留 ONLYOFFICE 的 Qt+嵌入式 CEF，改用「ArkUI 原生壳 + 鸿蒙系统 WebView 渲染编辑器 + native core 引擎」的路线（下文 B 架构）。** 因为 OHOS 上**没有开箱即用**的可嵌入应用进程、可被 NAPI 驱动的独立 CEF 库——默认源码路径把 CEF 合编进系统 ArkWeb 引擎，应用只能以「浏览器视图」粒度访问；唯一的一条自建应用态 Chromium 路径（`pc_chromium_132` 独立浏览器分支，见 §2.3-§2.5）成本极高。唯一低成本、立即可行的办法，是把 ONLYOFFICE 的 `window.Asc.*` 原生桥按 ArkWeb 的"浏览器侧 JS 代理 + 异步回调"模型**重写**（方案 B）。另须说明：OHOS 上**也**存在"应用态嵌入 Chromium"的路径（`pc_chromium_132` 独立浏览器、`openharmony-sig/electron` + 已跑通的 `hos_vscodium`，见 §2.3），即"嵌入 Chromium 的应用"确实可做（方案 C）；但对 ONLYOFFICE，MVP 仍以 B 为主——成本最低、异步桥对核心编辑足够。

分三阶段落地（见 §3）：**阶段 1 做 POC（1→4）排掉最大风险，阶段 2 定壳并工程化，阶段 3 产品化。**

---

## 1. 目标与范围

**用户目标**：把 ONLYOFFICE DesktopEditors 移植到鸿蒙 Pad，能离线打开/编辑/保存 Office 文档（优先 DOCX/XLSX/PPTX），输出原生 Pad 体验。

**v1（MVP）范围**：
- 打开 DOCX → 系统 WebView 渲染编辑器 → 基础编辑（输入/格式/滚动）→ 本地保存
- 用最小成本验证「系统 WebView 渲染 + core 交叉编译」两项可行性

**v1 暂不追求**（列入后续）：表格/演示/PDF/Diagram 全套、云协作、插件市场、AI、原生打印/系统拖拽等原生深度集成。这些是**能力井**，在"无 renderer 原生钩子"约束下有明确降级方案，不阻塞 MVP。

---

## 2. 关键研究结论（为什么走 B）

### 2.1 ONLYOFFICE DesktopEditors 真实技术栈
多仓库（git submodule）结构，桌面端由四块拼成：

| 组件 | 说明 | 跨平台难度 |
|---|---|---|
| `desktop-apps` | **Qt 5.15（qmake）桌面壳**：`core gui widgets printsupport svg network`，提供窗口/标签/菜单/对话框 | Qt-on-OHOS 属 alpha + 构建仅 Windows |
| `desktop-sdk/ChromiumBasedEditors` | **CEF v103/107** 嵌渲染 `sdkjs` 编辑器 + `qt_wrapper`(Qt↔CEF 桥) + libVLC | OHOS 无独立 CEF |
| `core` | **C++ 文档转换引擎**（x2t，依赖 boost/openssl/icu/libxml2/hunspell） | 确定性交叉编译 |
| `sdkjs` + `web-apps` | **JS Web 编辑器**（工具条/菜单/文档画布全在这） | 天然跨平台（浏览器） |

> 关键：**编辑器 90% 的 UI 是 Web 内容（web-apps），不是 Qt。** Qt 只提供"文档容器壳"。文档画布由 CEF(Chromium) 渲染。

### 2.2 OHOS 上的 CEF：只有"系统 WebView"，没有"可嵌入 libcef"
经一级源码核验 `openharmony-tpc/chromium_cef` 仓库（并非转述）：

```
宿主应用 (ArkTS/C++/Java)
  ↓ ohos_interface / ohos_nweb (web_webview 仓库)     ← 应用唯一入口（浏览器视图级 API）
ArkWebCore.hap (Chromium + CEF 合编产物)                 ← 系统引擎，随固件走
  ├── libcef/             CEF 核心
  └── ohos_cef_ext/       OHOS 扩展（只对系统构建开放）
```

原文佐证：
- 「本仓库**不独立编译**，跟随 `chromium_src` 的 OH **全量编译**流程」(`./build.sh -t w -A rk3568`)
- 「桥接层 `libcef_dll_wrapper`…仅被上游测试/示例程序依赖；**在 ArkWeb 实际运行路径中不起作用**」→ 唯一能让"应用链接 libcef 驱动 CEF"的 C ABI 桥，在 OHOS 上**不启用**。
- `BUILD.gn` 中 CEF(`//cef`) 依赖 `//ohos_nweb:cef_nweb`、`//arkweb/...`、`//ohos/adapter` —— 它是吊在 OpenHarmony 系统组件上的第三方零件。

**进一步的直接证据（`chromium_src` 根 `AGENTS.md` + 根 `BUILD.gn`）**：
- `chromium_src` 是 Chromium 内核源码，但被明确定位为 **ArkWeb 引擎的内核层**（对应上游 `src/`）。根 `AGENTS.md` 原文：「本仓库对应 Chromium 源码的 `src/` 目录，是 ArkWeb 引擎的内核层。」
- 它与 `chromium_arkweb`(ArkWeb 定制层)、`chromium_cef`(CEF 封装层)、`chromium_third_party`(第三方库，含 blink/v8/skia/icu) **四仓联合编译**，产物是 **`NWeb.hap`(ArkWebCore)** —— 一个**系统 WebView 组件**，不是应用可链接库。
- 根 `BUILD.gn`：`import("//cef/libcef/features/features.gni")`，`if (enable_cef) { deps += ["//cef:libarkweb_engine"] }` —— **CEF 在这里被编成 `libarkweb_engine`**，名字直白：给 ArkWeb 系统引擎用。整树无一个面向"应用进程 link `libcef_dll` + 自驱动 browser/renderer 多进程"的 target。
- 结论：**"内核源码存在（真 Chromium）" ≠ "应用可嵌入 libcef"**，两者在 OHOS 上是割裂的。`chromium_src` 提供的是系统 WebView 的内核，不提供 app 嵌入出口。

### 2.3 修正：OHOS 其实能做出"嵌入 Chromium"的应用（两条真实路径）
`chromium_src` 的默认分支(master)是四仓联合编译成系统 WebView(`NWeb.hap`)，但**那不是唯一路径**。本仓库的 `pc_chromium_132` 分支以及 OHOS 上的 Electron 生态，证明**应用态嵌入 Chromium 是可行的**——我此前"只有系统 WebView"的表述不完整，修正如下：

| 路径 | 载体 | 产物形态 | Chromium 来路 | 多进程 | JS↔原生桥 |
|---|---|---|---|---|---|
| **B 系统 WebView** | 系统 ArkWeb(内置) | 应用内嵌 Web 组件 | 固件自带(零编译/零维护) | 系统管理 | `registerJavaScriptProxy`+`runJavaScript`(异步) |
| **C 自建 Electron/Chromium** | `libelectron.so` 运行时 | 打包成独立 HAP app | 自编译 Chromium(Electron) | 应用自管 | IPC(aki/callArkTSFunction,异步) |
| C 变体 `pc_chromium_132` 浏览器 | `libchrome_main_web.so` | 完整浏览器 HAP | 自编译 Chromium | 应用自管 | 浏览器 chrome 逻辑 |

**证据链（应用态嵌入 Chromium 确实可行）**：
- `chromium_src` 的 `pc_chromium_132` 分支：`build.sh -t b` → `ohos_build_target="chromium"`，产物 `libchrome_main_web.so`+`libadapter.so` → 打包 `chromium-default-signed.hap`(包名 `com.huawei.ohos_chromium`)。命令行参数(`--remote-debugging-port`/`--gpu-launcher`/`--no-sandbox`/`--inspect`)证明是**多进程 Chromium**。
- `openharmony-sig/electron`：Electron 移植(`electron-v37.2.0-openharmony`)，基于 `chromium-electron` patch 到 ohos chromium，产物 `libelectron.so`+`resources.pak` → `electron-default-unsigned.hap`；主进程/渲染多进程，桥 aki(C++→ETS)/callArkTSFunction(JS→ArkTS)。
- `hos_vscodium`：一个**真实复杂 Electron 应用(VSCodium)已跑通**——复用上述 Electron 运行时(Chromium 138+Node 22)，`executableBinaryPaths` 随 HAP 分发，真机 MateBook Pro 验证，Workbench/集成终端/Open VSX 扩展市场可用(带已知缺陷：退出偶发 dlclose 崩溃、spdlog/sqlite3 被移除，个人项目 11 提交)。

**但 Electron 路径对 ONLYOFFICE 需打三个问号（关键澄清）：**
1. **Electron 给的是"自包含 app 运行时"，不是"可借给任何宿主 app 的 libcef 库"。** 你能基于它把 Chromium 嵌进**你自己这个 app**(如 VSCodium)，但不能把它的 Chromium 转手给**另一个非 Electron 宿主壳**(如 ONLYOFFICE 的 Qt)用。
2. **Electron 的桥仍是"异步 IPC"，与 WebView 的 `registerJavaScriptProxy` 同类。** 即：即便走 Electron，ONLYOFFICE 桌面版那种**同步 CefV8Handler 依旧要重写**(只是 IPC 形态)；要真同步，还须 patch Chromium(更深坑)。
3. **Electron 给 ONLYOFFICE 的额外收益≈0**：可跑 Node(不需要)、多进程/沙箱控制(不需要)、可改 Chromium 行为(不需要)；而成本 = 自编译 Chromium+Electron(>200G 磁盘/>32G 内存/数小时~天/Ubuntu 源码编译)+ 每版本跟踪上游 + 出 hap + 自维护整条运行时线。

**结论**：**"能不能搞出嵌入 Chromium"→ OHOS 上能(有 VSCodium 背书,属实)。"该不该为 ONLYOFFICE 走 Electron"→ 不划算,除非你明确要"桌面级还原 + 愿背 Chromium 维护线"。** MVP 走 B 的理由：Chromium 免费内置零维护；异步桥对 ONLYOFFICE 打开/编辑/保存/导出**足够**；唯一牺牲的少数同步原生能力(同步剪贴板/原生打印/拖拽/拼写)可降级异步或改走 OHOS 原生 API。

### 2.4 两条常驻硬约束（贯穿全项目）
- **① 引擎版本被固件锁定、无法定制（仅 B 路径）**：走系统 WebView 时，ArkWeb 版本随设备（SDK `6.1.0(23)`），不可 patch/pin/加扩展；可用 API = 设备提供的 `ohos_nweb`/`@ohos.web.webview`。若走 Electron(C) 则可自定版本，但须自编译维护。
- **② 能力天花板（仅 B 路径）：无 renderer 原生钩子、无应用级多进程控制**：ONLYOFFICE 里依赖"同步 V8 原生桥"的能力（同步剪贴板/原生打印/系统拖拽/原生拼写）须浏览器侧重写或降级异步。Electron(C) 能自管多进程，但桥依旧异步，故非必要。

### 2.5 环境实测（已就绪）
- `hdc 3.2.0d`：`/apps/harmony/sdk/default/openharmony/toolchains/hdc`，已连通真机 `192.168.1.8:33363`（另有 `192.168.1.4`）
- OHOS SDK：`/apps/harmony/sdk/default/openharmony`（ets/js/native/toolchains），目标 `HarmonyOS NEXT 6.1.0(23)`，native 编译器 BiSheng
- node v22 / hvigorw / ohpm 齐备；wineohos 已有签名证书（.cer/.p7b/.p12）与 sign 脚本可复用

---

## 3. 总路线图（阶段划分）

```
阶段 1  POC：排掉两大风险 —— **2026-09-03 完成 ✅（全部通过，进入阶段 2）**
  POC-1  系统 WebView 渲染编辑器 + window.Asc.* 桥可行性   ✅（最大风险排掉）
  POC-2  core 交叉编译到 arm64 OHOS（.so + NAPI）          ✅
  POC-3  端到端整合：选 docx→core 实时转→WebView 渲染→编辑→保存  ✅（诊断完成，保存断点由 POC-5 链替代）
  POC-4  壳方向探测：ArkUI 薄壳 vs Qt 壳（拿实证定 A/B）     ✅ **按规则直接选 B**（POC-1/3 判异步桥可行；POC-0 不插入）
  POC-5  「编辑→保存」全开源链真机验证                     ✅
         页面 BinaryFileWriter(DOCY) → AscSaveBridge → x2t doct_bin2docx → save.docx
         验收：真机 asc_AddText 插入 POC5-1788365602126 → DOCY;v5;292662;+b64(390231B)
         → x2t rc=0x0 → 26077B docx → recv 后 word/document.xml 含
         POC5-1788365602126（编辑内容进成品）

阶段 2  定壳 & 工程化（POC-1/3 产物 + POC-4 结论）
  2.1  确定壳（趋势 ArkTS；除非 POC-4 证明 Qt 明显更省）
  2.2  补齐 window.Asc.* 桥到 MVP 所需子集（open/save/close/原生对话框）
  2.3  core 功能集到"常用三件套"所需（docx/xlsx/pptx 打开/保存/导出 PDF）
  2.4  HAP 打包 + 签名 + hdc 部署 CI

阶段 3  产品化
  3.1  全套件（Writer/Sheets/Slides/PDF/Diagram）功能对齐
  3.2  原生 Pad 体验：文件管理/最近列表/云盘/多标签触控手势
  3.3  受约束能力的降级方案落地（打印→PDF/OHOS 打印；剪贴板→异步；拖拽→点选）
```

**里程碑判定**：POC-1 若能跑通编辑器渲染并走通 `window.Asc.*` 主要回调 → 方案成立，进入 2。POC-1 失败 → 回到 2.1/3.x 重新评估桥的替代（例如用 ONLYOFFICE Document Server 的 HTTP/socket 模式替代 CEF 桥）。

---

**阶段 1 完成宣告（2026-09-03）**：功能可行性全部清零（POC-1/2/3/5 真机闭环；POC-4 依规则直选 B；POC-0【Electron 重路线】仅在同步桥不足时才插——已证异步桥足用，明确不做）。壳方向 = **ArkTS 薄壳包 ArkWeb（B 路线）**。POC-4 原第二试探线（Qt 嵌 ArkWeb surface）与 Electron 重路线均不再评估。

### §3.1 阶段 2 迭代计划（2026-09-03 起，工程化）

| 迭代 | 范围 | 内容 | 验收 |
|---|---|---|---|
| **迭代 1**（进行中） | 2.1+2.2+2.4 MVP | 壳层"打开用户文件"入口 → rawfileLoader 增加 `userfile/` 沙箱文件拦截（URL 参数化打开，替代硬编码 `_offline_` 内置文档）→ POC-5 探针改造为正式保存按钮（页内 `__poc_save` 全局函数）→ 部署脚本沉淀 `scripts/onlyoffice/` | 真机沙箱任意 docx 打开（内容指纹=该文件，非内置 demo）→ 编辑标记 → 保存按钮 → recv 验证 document.xml 含标记+原文件内容 |
| **迭代 2** | 2.3 | 三件套 xlsx/pptx：cell/slide 页面资源、XLSY/PPTY → xlst_bin2xlsx / pptt_bin2pptx（convertershell 已含）真机验证 | 真机 xlsx/pptx 编辑→保存闭环 |
| **迭代 3** | 2.2 补 | 生命周期：切后台/旋转/WebView 状态保持；长会话语义（多页/大文档 base64 过桥阈值评估）；打开/保存对话框走原生 | 桌面体验一致；大文档（≥10MB）打开+保存不崩 |
| **后续** | 3.x | 产品化：文件管理/最近列表/触控手势；受约束能力降级（打印→PDF、剪贴板异步、拖拽→点选） | —— |

> 迭代 1 唯一可能回退的切点：「真文件打开」若在拦截器/offline 模式受限，则单独扩一次小 POC（1-2 天），不阻塞其余切片。

---

## 4. B 架构设计

### 4.1 目标架构
```
鸿蒙 Pad HAP（单 Ability）
  ├── ets/  ArkT/ArkUI 壳（原生 Pad 体验）
  │     文档容器壳：打开/最近列表/保存；Web 组件承载编辑器画布
  ├── Web 组件 (ArkWeb = 系统引擎，Chromium) —— 文档画布
  │     └── 渲染 ONLYOFFICE web-apps/sdkjs（工具条/菜单/文档画布全在此 Web 内）
  │     │ JS↔原生：registerJavaScriptProxy(window.Asc.*) + runJavaScript
  │     │ 资源/协议：onInterceptRequest 实现 onlyoffice:// & loopback
  ├── cpp/ native
  │     ├── core 桥 (NAPI)：convert(path)→内部格式/PDF；文件存取
  │     └── ONLYOFFICE core (.so 交叉编译，随 rawfile/libs 打包)
  └── resources/rawfile
        ├── web-apps + sdkjs（JS 编辑器静态资源，预打包）
        └── 预转换好的内部格式文档（POC 离线准备）
```

### 4.2 数据流（打开→编辑→保存）
> 关键分工：**sdkjs(JS) 只认"内部格式"；core(x2t, C++) 负责"office格式↔内部格式"转换**（桌面版是调 `file_converter_path + "/x2t"` 独立转换器，见 `desktop_sdk/lib/src/fileconverter.h:240`）。因此 **core 是必选项**，不是加分项——无 core，sdkjs 打不开 docx。
```
用户选 docx (ArkTS 壳 → document picker)
  → native core: x2t 把 docx 转成 ONLYOFFICE 内部格式 (def/src.xml+font/media)
  → (大文档别当字符串过桥) 转换结果写到可访问文件/rawfile；sdkjs 用 onInterceptRequest / fetch 拿内容
  → WebView 加载 editor.html（onlyoffice:// rawfile + onInterceptRequest 供资源）
  → sdkjs 渲染内部格式 → 用户编辑（纯 JS 内进行，不经过桥）
  → 导出/保存: sdkjs 产出 → 经 window.Asc.Save / 文件路径 → core 写回 docx/pdf
```
- **性能要点**：编辑高频路径（逐键/选区/滚动/排版/Canvas 绘画）100% 在 sdkjs 内完成，**不经过桥**；桥只承担"文档级一次性 I/O"。唯一瓶颈是**大文档一次性过桥**（webview 的 runJavaScript 跨 IPC+复制），用"文件 URL / onInterceptRequest / 流式"规避。

> **【2026-09-02 修正】保存段有重大更新**（POC-3 后的全源码分析）：「编辑后→docx」存在**全开源**官方链——sdkjs `AscCommonWord.BinaryFileWriter(模型)` 产出 `"DOCY;v5;<len>;"+base64` 二进制，native x2t `doct_bin2docx → BinDocxRW::CDocxSerializer`（纯 C++，无 V8）转出 docx。**无需**此前依赖的闭源 `saveDocumentToZip`/`Asc.Addons.ooxml` 注入，也无需服务器。详见 `docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md`。对应新增验证项 **POC-5**（见 §5）。

### 4.3 组件划分（每个单一职责、接口清晰、可独立验证）
| 单元 | 职责 | 依赖 | 验证方式 |
|---|---|---|---|
| **ArkUI 壳** | 打开/保存/最近/查看器容器 | native 桥 | 真机 UI 走查 |
| **Web 渲染层** | 加载 web-apps/sdkjs；实现 `onlyoffice://` scheme | 系统 ArkWeb | POC-1 |
| **JS↔原生桥** | `registerJavaScriptProxy` 暴露 `window.Asc.*`；`runJavaScript` 反向调用 | ArkWeb + NAPI | POC-1 |
| **core 引擎(.so)** | 文档转换/读写 | boost/openssl/icu/hunspell | POC-2 |
| **NAPI core 桥** | 桥接 ArkTS ↔ core | ArkTS NAPI | POC-2 |
| **文件/沙箱适配** | OHOS 沙箱下文件读写/权限/无 exec 段 mmap 回避 | OHOS FS API | POC-2/3 |

### 4.4 错误处理（MVP 级）
- 转换失败：core 桥返回错误码 → 壳 toast + 不崩溃
- 桥调用超时/未实现：`window.Asc.*` 对未实现的回调返回空/`false`，JS 侧优雅降级
- WebView 加载失败：`onErrorReceive` 捕获 → 壳提示
- 编辑未保存退出：`beforeunload`/窗口关闭拦截 → 询问

---

## 5. POC 子方案与状态（1-5，2026-09-03 全部完成）

> 状态速览：POC-1 ✅ / POC-2 ✅ / POC-3 ✅ / POC-4 ✅（规则直选 B，A 线与 POC-0 不再评估）/ POC-5 ✅（详见 `docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md` §4，真机通过）。本节保留原子方案描述。

### POC-1 —— WebView 渲染编辑器 + 桥可行性（最大风险，先做）【✅ 已通过】
- **准备**: Linux 端用 core 把 `sample.docx` 预转成内部格式，连同 `sdkjs`+`web-apps` 打包进 HAP rawfile
- **方法**: ArkTS `Web`/`ohos_nweb` 加载；`onInterceptRequest` 实现 `onlyoffice://`；`registerJavaScriptProxy` 注入最小 `window.Asc.*`
- **通过标准**:
  - 编辑器 UI 显示、内文渲染、可输入/滚动
  - `window.Asc.*` 至少 open/save/close 回调走通
  - 记录每个回调的同步→异步换算结果（哪些需改、哪些可用）
  - **性能实测**：a) 逐回调频率 → 判定该"留 JS"还是"走桥"；b) 大文档打开耗时，验证"文件 URL / onInterceptRequest 喂内容、避免大字符串过桥"是否成立
- **输出**: 桥改写工作量清单 + 方案可行性判定

### POC-2 —— core 交叉编译到 arm64 OHOS 【✅ 已通过：convertershell NAPI 26 库真机就位，docx→ODT rc=0】
- **方法**: 用 OHOS NDK（BiSheng clang，`OPENHARMONY_NDK_ROOT` 指向 `/apps/harmony/sdk/default/openharmony/native`）交叉编译 `core`（先最小链路 x2t），`libs` → `.so`；NAPI 暴露 `convert(path)`
- **通过标准**: NAPI 在真机把 `sample.docx` 转成 PDF/内部格式成功；验证 OHOS 沙箱下无 exec 段 mmap、可写文件、Boost/OpenSSL/ICU/Hunspell 依赖链交叉编译通过
- **风险要点**: `NOEXEC_MMAP_ANALYSIS`（参照 wineohos）、`dlopen`、权限、`fork` 限制

### POC-3 —— 端到端整合（全链路里程碑）【✅ 已通过：诊断出保存断点=集成层职责，由 POC-5 全开源链替代；x2t docx→docx 重序列化 rc=0 zip=ok 实测】
- 用户选 `sample.docx` → 真机 core 实时转内部格式 → WebView 渲染 → 编辑 → 保存
- **通过标准**: 一个 docx 的"打开→看→改→存"在真机跑通

### POC-4 —— 壳方向探测（决定阶段 2 走 A 还是 B）【✅ 已定：按规则直选 B，A 线不试探】
> 注：POC-1/3 若判异步桥可行，则 POC-4 直接选 B；若判"个别同步能力不可少"，则额外插入 **POC-0（可选）**——基于 `openharmony-sig/electron` 装一个空 Electron 壳 HAP 到真机，验证"能否以 Electron 形态加载 ONLYOFFICE web + IPC 桥"（即评估重路线 C 的实际成本与收益，再决定是否切换主线）。
- 用 POC-1/3 产物分两条线试探：
  - ① ArkTS 薄壳包 WebView（B 雏形）
  - ② 试能否把 `QCefView` 换成 ArkWeb surface 塞进 Qt 窗口（A 雏形）
- **通过标准**: 给出"A 还是 B 更省力"的实证结论（需一并核 `openharmony-sig/qt` 的 API 23 兼容性）
- **预期**: 依 2.2 结论 A 需改写桥 + 承担 Qt alpha 风险 → **B 大概率胜出**

---

## 6. 工程结构（根目录 `/data/share/office`，对齐 wineohos 骨架）

```
office/
├── entry/
│   └── src/main/
│       ├── ets/                 # ArkUI 壳: 文档容器 + Web 组件 + 窗口管理
│       ├── cpp/                 # native: core 桥(NAPI) + core(.so) + 沙箱适配
│       ├── resources/
│       │   └── rawfile/         # web-apps + sdkjs + 预转换文档 + onlyoffice scheme 配置
│       └── module.json5
├── core/                        # ONLYOFFICE core (git submodule)
├── desktop-sdk/                 # 仅取 web-apps/sdkjs 相关（不用 CEF/Qt 部分）
├── scripts/                     # 构建/打包/hdc 部署/check-submodules
├── docs/                        # 本设计文档 + 研究结论
├── build-profile.json5 / hvigorfile.ts / oh-package.json5 / local.properties
├── Makefile                     # 根编排：make deps | core | hap | deploy
├── .claude/rules/               # 构建命令与日志速查
├── .temp/                       # 研究素材（已建）
└── .ohos/                       # 签名证书（复用 wineohos 或新生成）
```

**构建配置要点**（对齐 wineohos 实测值）：
- `targetSdkVersion`/`compatibleSdkVersion` = `6.1.0(23)`，`runtimeOS: HarmonyOS`，native 编译器 BiSheng
- 交叉 ABI：`arm64-v8a`
- OHOS NDK 工具链：`$OHOS_SDK/native/llvm/bin/clang`（BiSheng），mkspec 用 `ohos-clang`

---

## 7. 真机部署链路

```bash
# 开发→真机联调循环（设备已 hdc 连通 192.168.1.8:33363）
hdc list targets                        # 确认 192.168.1.8:33363
hdc -t 192.168.1.8:33363 shell           # 进真机 shell
hdc -t 192.168.1.8:33363 install <app.hap>
hdc -t 192.168.1.8:33363 shell aa start -a <AbilityName> -b <bundleName>
hdc -t 192.168.1.8:33363 hilog | grep -iE 'onlyoffice|core|NAPI|web'
```

**构建（DevEco 命令行 / hvigor）**：
```bash
hvigorw assembleHap --mode module -p product=default --no-daemon
# 交叉编译 native: OHOS NDK + BiSheng clang; core 依赖链单独脚本 build_core_ohos.sh
```

**签名**：复用 wineohos 的 `.ohos/*.cer|.p12|.p7b`（debug 证书）或 `sign.py`/`sign.js` 新生成，`build-profile.json5` 的 `signingConfigs` 指向。

---

## 8. 风险 / 约束表

| 风险/约束 | 等级 | 缓解 |
|---|---|---|
| `window.Asc.*` 同步桥→ArkWeb 异步代理的换算点不明 | **高(POC-1 前置)** | POC-1 逐回调实测，产出改写清单；必要时用 ONLYOFFICE Document Server HTTP/socket 模式替代 CEF 桥 |
| core 依赖链在 OHOS 交叉编译失败（boost/openssl/icu/hunspell） | 高 | POC-2 先做最小 x2t 链路；共享静态库方案，逐个依赖攻 |
| OHOS 沙箱限制（noexec mmap / exec 可执行段 / fork / dlopen） | 中高 | 参照 wineohos `NOEXEC_MMAP_ANALYSIS`；`-Wl,--noexecstack`；匿名 mmap + pread；限定进程派生 |
| **引擎版本被固件锁定、无 renderer 原生钩子** | **常驻约束** | 接受浏览器侧模型；将同步原生能力（剪贴板/打印/拖拽/拼写）按"异步"或"MVP 降级"实现 |
| 本地 `http://127.0.0.1`（core loopback）混合内容/隐私限制 | 中 | `onInterceptRequest` + `allowFileAccess` / 混合内容模式；或改走自定义 scheme |
| Qt 壳（若 A 路线）alpha + 仅 Windows 构建脚本 + API 23 兼容 | 中 | POC-4 实证；按结论优先 B，规避 Qt |
| AGPL-3.0 合规 | 低 | 作为内部/开源项目声明；相关依赖许可证（Qt LGPL/CEF BSD/libVLC）需满足项记录 |
| web-apps/sdkjs 版本与 core 版本匹配 | 中 | 打包时锁定同一 ONLYOFFICE 版本 tag（submodule 对齐） |

---

## 9. 附：调研要点与参考

- **DesktopEditors**：`/data/share/office/.temp/desktop_editors/`（含 `.gitmodules`、7 个 submodule）
  - `desktop_apps/win-linux/`：Qt5.15(qmake) 壳，`defaults.pri` 模块=`core gui widgets printsupport svg network`；平台层用 GTK3/xcb/X11/cups/dbus/notify（OHOS 需替换为 `platform_ohos`）
  - `desktop_sdk/ChromiumBasedEditors/lib/`：CEF v103/107 + `qt_wrapper`(QCefView/QAScApplicationManager)；自定义 scheme `onlyoffice://`；`window.Asc.*` 原生桥类（AscApplicationManager/AscCrypto/AscSpellChecker…）
- **openharmony-sig/qt**：Qt 5.15.12/5.15.17 + 6.5.6；QtWebEngine 未移植；QPA `-platform openharmony`（NativeWindow+EGL+XComponent）；`qtohextras` 替代沙箱受限的 QProcess/QLocalServer
- **openharmony-tpc/chromium_src**（真 Chromium 内核，ArkWeb 引擎内核层，对应上游 `src/`）：根 `AGENTS.md` 明确「本仓库对应 Chromium 源码的 `src/` 目录，是 ArkWeb 引擎的内核层」；根 `BUILD.gn` 中 CEF 被编成 `//cef:libarkweb_engine`，联合编译 target 全为 `//ohos_browser_shell`/`//ohos_nweb_hap`/`//arkweb/...` → 产物是 **系统 NWeb.hap(ArkWebCore)，非应用可嵌入 libcef**。
- **四仓联合编译关系**（写入多个 OH 仓库维护说明）：`chromium_src`(内核) + `chromium_arkweb`(ArkWeb 定制层 + ohos_nweb + ohos_adapter_ndk) + `chromium_cef`(CEF 封装 + ohos_cef_ext) + `chromium_third_party`(blink/v8/skia/icu) → 联合编译 → `NWeb.hap (ArkWebCore)`。`chromium_cef` 在本体系仅作为"合编进系统 ArkWeb 的 CEF 封装"存在。
- **openharmony-tpc/chromium_cef**：Chromium 144/CEF 144；合编进系统 `ArkWebCore.hap`；应用经 `@ohos.web.webview`/`ohos_nweb` 访问；桥接层在 ArkWeb 路径不启用。
- **openharmony-sig/electron**：Electron 移植（`electron-v37.2.0-openharmony`，Chromium 138+Node 22），基于 `chromium-electron` patch 到 ohos chromium；产物 `libelectron.so` → `electron-default-unsigned.hap`；主/渲染多进程，桥 aki(C++→ETS)+callArkTSFunction(JS→ArkTS)。**证明 OHOS 应用态能跑"嵌入 Chromium 的运行时"。**
- **hos_vscodium**：真实复杂 Electron 应用(VSCodium)移植，复用上述 Electron 运行时，HAP 随 `executableBinaryPaths` 分发，真机 MateBook Pro 验证，特色 Workbench/集成终端/Open VSX 扩展市场——**产品级可用的佐证**（带退出 dlclose 崩溃等已知缺陷）。
- **wineohos 宿主范式**：HAP = ArkTS 宿主页(XComponent+窗口) + native C++（compositor/box64/audio/input/NCP 子进程/broker/NAPI bridge）—— 承载"外来 GUI 运行时"进 HAP 的可复用基础设施。
