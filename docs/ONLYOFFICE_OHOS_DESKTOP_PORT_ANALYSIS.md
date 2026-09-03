# DesktopEditors（PC 桌面版）迁移到 HarmonyOS —— 方案/难点/克服方案分析

- 日期：2026-09-03
- 结论先行：**可行但为"重资产"路线**。难点不在"少个浏览器"，而在"桌面协议"是一整包宿主能力；推荐维持 B 架构（已闭环）并按"算法组件逐步复用"原则增量吸收桌面版价值，而非整体切换。

---

## 1. DesktopEditors 是什么架构（据官方仓库 + 本地 sdkjs 源码实证）

```
桌面进程模型（CEF + Qt）
┌───────────────────────────────┐
│ Qt 主窗口（界面：菜单/对话框）          │
│ └─ CEF 浏览器进程（Chromium 内核）     │
│     └─ renderer 进程内跑 sdkjs(JS)    │
│         │ 同步 V8 原生桥（CefV8Handler）│
│         ▼                           │
│     C++ 能力池：                      │
│      └ x2t 转换（已在移植）            │
│      └ 字体系统（本地索引+光栅）          │
│      └ 文件 IO/对话框/打印/拼写/加密/插件 │
└───────────────────────────────┘
```

**关键实证**（本地 sdkjs 源码）：

- `common/Native/native.js:49` — `window.NATIVE_EDITOR_ENJINE = true;` —— 桌面启动脚本由 C++ **首屏注入**，它同时伪造了 `navigator/location/XMLHttpRequest/Asc/AscCommon/document` 整份 JS 环境（358 行）。**桌面模式 = C++ 侧先搭好了环境再放进 JS**。
- `IS_NATIVE_EDITOR` 分支面：**24 个文件**（cell 全套 api/graphics/History/clipboard/view、common 层 Charts/Drawings/apiBase、pdf viewer、libfont/loader）。
- `window.AscDesktopEditor` 调用点 **414 处**；被调方法（前 20 名）：IsLocalFile(73)、OpenFilenameDialog(29)、LocalFileGetImageUrl(29)、CryptoMode(23)、SetAdvancedOptions(14)、emulateCloudPrinting(12)、LocalFileGetSaved(12)、buildCryptedEnd(11)、onDocumentModifiedChanged(10)、MediaStart(10)、CryptoDownloadAs(10)、SpellCheck(9)、LocalFileGetSourcePath(9)、isSupportMacroses(8)、GetImageBase64(8)、DownloadFiles(8)、Print_Page/Print(7)、GetInstallPlugins(7) —— 协议面 = **本地文件系统 + 加密 + 打印 + 拼写 + 多媒体 + 插件**。
- `CreateEmbedObject("CZipEmbed")`（libfont/engine.js:693）—— native 模式字体/压缩引擎以 **V8 原生对象**形态使用。

## 2. 我们当前的 B 架构 vs 桌面版：已复用/缺什么

| 能力 | 桌面版 | 我们的 B 架构 | 复用程度 |
|---|---|---|---|
| 页面编辑器（sdkjs/web-apps） | 同 | 同（官方树直用） | ✅ 100% |
| 格式转换（x2t） | 内嵌 | NAPI 库（已编译） | ✅ 100% |
| 打开/编辑/渲染 | CEF 内 | ArkWeb 内（JS 渲染，已通） | ✅ 功能等价 |
| Browser 内核 | 自建 | 系统自带 | ✅ 零维护 |
| 桥 | 同步 CefV8Handler | 代理（JS→ArkTS 同步；ArkTS→JS 异步）| ⚠️ 重写（已在做） |
| 文件对话框/打印/拼写/加密/插件 | C++ 原生 | 无（降级/待做） | ❌ 缺 |
| 系统字体/光栅 | C++（HarfBuzz） | JS 光栅（wasm，够用） | ⚠️ 可渐进吸收 |

## 3. 方案分解（把"搬桌面版"拆成可权衡的子方案）

- **方案 X（全量桌面等价）**：自建内核（Electron/独立 Chromium）→ 内核底层协议仍异步，同步化须 patch Chromium；另需移植 Qt/CEF 层。高成本高不确定。
- **方案 E（模拟桌面协议）**：不换内核，页面注入假 `AscDesktopEditor`（JS 侧拼装对象，接口形态对得上的地方用代理函数顶出去）→ 引擎翻入 `IS_NATIVE_EDITOR` 分支。**同步性不再是障碍**（JS→ArkTS 桥同步；对象可在 JS 侧拼），障碍转移为"24 文件分支面的行为适配"。
- **方案 R（按需算法复用，推荐）**：维持 B 架构，逐组件把 C++ 算法搬进 NAPI 库（字体光栅/索引等），接口在 JS 侧自制。零分支翻转风险。

## 4. 难点清单（方案 E/全量的真实成本）

| # | 难点 | 证据/本质 | 克服方案 | 成本量级 |
|---|---|---|---|---|
| 1 | **环境注入面**：native.js 伪造整份 JS 环境，且桌面模式隐含"C++ 已把窗口/事件循环搭好" | native.js:49、24 文件分支 | 方案 E 在页面侧重造同等环境对象；每个分支逐个验证 | 高 |
| 2 | **字体系统**：桌面模式字体索引（`g_fonts_selection_bin` 类二进制）+C++ 光栅；系统字体清单须由原生产出 | libfont/engine.js:693; libfont/loader.js | 我们 NAPI 扫描 OHOS `/system/fonts`+应用字体区，产同格式索引；光栅可复用 core 3dParty HarfBuzz/freetype（已有源码） | 中高 |
| 3 | **打开链未知面**：native 模式下从 OpenFile→模型建成的内部链路与 web 版不同 | cell/api.js 等 openDocument 分支 | 实验验证：POC 注入最小 AscDesktopEditor → 记录第一个断裂点 | 未知（实验可定） |
| 4 | **保存链**：桌面保存契约（native 侧写盘/加密） | LocalFileGetSaved(12)/buildCryptedEnd(11) | 我们已有 web 保存链（BinaryFileWriter→x2t）；协议项按需实现 | 中 |
| 5 | **功能等价面**：对话框/打印/拼写/多媒体/插件（方法 TOP 表） | 见 §1 统计 | 单个实现：打印走 OHOS 打印、对话框走 ArkUI、拼写可选；"降级但可解释" | 中（项多） |
| 6 | **性能**：native 模式字体光栅为每字符调用，经我们异步桥将退化；同步桥则卡 JS 线程 | 官方警告同步长计算卡 H5 | 光栅计算在 NAPI 内 C++ 完成（微秒级）+ 缓存；仍要压测 | 中 |
| 7 | **内核级差异**：V8 原生对象（CreateEmbedObject）与 CEF 线程模型无法复制 | engine.js:693 | 对象接口在 JS 侧补全（用现有 JS 引擎实现顶替）；线程语义只有"单 JS 线程+桥"——可接受？ | 中（需验证） |

## 5. 克服难点的推荐路线（三阶段）

1. **阶段 1（实验，半天）**：POC——页面注入最小 `AscDesktopEditor`（只含 `CreateEditorApi`+`IsLocalFile`），真机看引擎首个断点在哪个分支 → 把"未知面"变"清单"。**数据决策**。
2. **阶段 2（组件吸收，低风险）**：维持 B 架构，按需从桌面版吸收组件：字体索引/光栅（HarfBuzz）、明文/加密保存、打印（OHOS 原生）——接口 JS 自制、算法进库、逐步替换 JS 短板。
3. **阶段 3（仅当产品要求"桌面级还原"才做）**：方案 E 全量模拟（协议补齐 414 处调用点对应能力）或方案 X（自建内核）——以阶段 1 清单位工期。

## 6. 结论

- "搬桌面版"在鸿蒙上不成立为"一条命令"；它等于**把 CEF+Qt 层面全部替换后，用我们的桥重新顶起整套桌面协议**（文件/加密/打印/拼写/插件）。协议开源可抄（sdkjs 侧引用点就是接口说明书），但每项都有 C++ 实现成本。
- B 架构（已闭环三格式）与"桌面版"的分水岭：**我们已经拥有 90% 的功能，缺的是 10% 的宿主能力**（对话框/打印等），两者不是互斥路线——按阶段 2 增量吸收是 ROI 最优解。
- 留给后续的"真决策点"：阶段 1 实验数据（native 分支断裂清单）出来后，再定要不要跳阶段 3。

## 附：本分析引用的本地证据（可复查）

```
third_party/sdkjs/common/Native/native.js:49               NATIVE_EDITOR_ENJINE = true（C++ 首屏注入+环境伪造）
third_party/sdkjs/common/Native/native_graphics.js(651行)  native 绘图接口（word scripts.js:430 已加载）
third_party/sdkjs/common/Native/jquery_native.js(8999行)   桌面 UI/事件模拟（桌面端注入，不在 web scripts.js 清单）
third_party/sdkjs/common/libfont/engine.js:693             CreateEmbedObject("CZipEmbed")
grep -c IS_NATIVE_EDITOR → 24 文件分支面
grep AscDesktopEditor → 414 调用点（方法 TOP 见 §1）
```
