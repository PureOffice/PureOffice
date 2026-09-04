# ONLYOFFICE DesktopEditors 移植到鸿蒙 —— 功能支持矩阵

> 版本：2026-09-04（正规化 M1-M4 验收后）
> 基座：官方 sdkjs（v9.4.0，`--desktop` 构建，min+common 双清单经官方 loadSdk 自加载）
>       + 官方 web-apps（grunt 产物）+ 官方 loginpage（桌面版欢迎页）+
>       ArkTS 壳（ArkWeb + native x2t 转换 + 文件沙箱）。
> 说明：每一项 = 官方桌面能力 | 当前状态 | 返回值/行为 | 升级建议。
> 未特别注明即遵循官方 CEED（CEF V8 回调）降级契约（false/''/0/{}/[]）。

## 1. 已实现（与本机核心链路）

| 能力 | 状态 | 说明 |
|---|---|---|
| 官方欢迎页（recents 面板 + 新建卡片） | ✅ | loginpage 官方产物；recents = 真数据（`LocalFileRecents` 返回沙箱 `recents.json`，打开过即入列） |
| 打开本地文件（系统选择器） | ✅ | `open:folder`（loginpage「Open local file」官方命令）→ ArkTS `DocumentViewPicker.select`（docx/xlsx/pptx 过滤）→ 拷贝沙箱 → 现有 x2t 打开链；欢迎页左下「打开」FAB 即点即用 |
| 打开 docx/xlsx/pptx | ✅ | recents → 沙箱源文件 → x2t docx2doct_bin 等 → 官方 `openDocumentFromBinary` → 引擎渲染 |
| 编辑（文本/表格等） | ✅ | 官方编辑器全套 UI（工具栏/右侧栏/状态栏/缩放/分页） |
| 保存（Ctrl+S / 自动保存） | ✅ | `asc_Save` 官方桌面协议骨架 → `asc_nativeGetFileData`（BinaryFileWriter → DOCY;v10）→ x2t 按目标后缀自动选 `doct_bin2docx`/`xlst_bin2xlsx`/`pptt_bin2pptx` → save.&lt;ext&gt; + 回写源文件；编辑内容进入 `word/document.xml`（真机核验） |
| 导出 / 另存为 | ✅ | 编辑页左下「导出」按钮 → 自动触发官方保存 → 系统保存对话框（`DocumentViewPicker.save`）→ 写用户选定位置 |
| 分享 | 降级 | SDK 无 ShareKit（@ohos.share 缺失）—— 登记 P1：SDK 升级后接 `systemShare` |
| 新建空白 docx | ✅ | create:new（word）→ 官方空文档（`word/document/editor.js` getEmpty + bSerFormat 补丁） |
| 缩放/状态栏/多视图 | ✅ | 官方 UI 原生实现（100% 起点，Factor 1.0 语义） |
| 多页视图（新建提示） | ✅ | 官方功能（无 UI 依赖） |
| 字体（本地 12 个 Liberation 家族） | 部分 | `__fonts_files/__fonts_infos` 注册表 + web 字形引擎；文档字体名差异 → 默认字体替换（可见字形） |
| 中文/俄文等语言 | ✅ | 引擎语言包 + lang=zh-CN 参数；UI 中文完整 |

## 2. 降级（官方已实现、本机按契约降级）

| 桥方法 | 返回 | 官方UI表现 | 备注 |
|---|---|---|---|
| `isSupportMacroses` | false | 宏入口隐藏 | 宏引擎（V8 附加）未自带 |
| `isSupportPlugins` | false | 插件菜单隐藏 | sdkjs 插件系统可加；无签名校验宿主 |
| `isSupportNetworkFunctionality` | false | 在线功能入口隐藏 | 纯本地链 |
| `IsSupportNativePrint` / `IsFilePrinting` | false | 打印入口禁用 | PDF 渲染器（doctrenderer）未接入 |
| `IsSupportMedia` | false | 媒体/录音隐藏 | |
| `IsSignaturesSupport` / `IsProtectionSupport` | false | 签名/保护入口隐藏 | |
| `isBlockchainSupport` | false | 区块链存证隐藏 | |
| `GetExternalClouds` | `[]` | 云存储接入为空白 | 需 OAuth/网盘套件 |
| `getSupportCryptoModes` / `GetSupportCryptoModes` | `[]` | 加密选项隐藏 | |
| `GetCryptoMode` / `Property_GetCryptoMode` | 0 | 非加密模式 | |
| `GetInstallPlugins` / `GetBackupPlugins` | `[{"url":"","pluginsData":[]}×2]` | 插件列表空 | sdkjs `UpdateSystemPlugins` 修正 |
| `getDictionariesPath` | `""` | 无自定义词典 | |
| `CheckCloudFeatures` | 0 | 无云功能 | |
| `GetOpenedFile` | `[]` | 空文件列表 | |
| `GetDocumentInfo` / `getDocumentInfo` | `""` | 无封皮信息 | |
| `GetCurrentWindowInfo` | `{}` | 无窗口信息 | |
| `getOfficeFileType` | `""` | 无文件类型回调 | |
| `IsLocalFileExist` | true | 本地文件恒存在 | |
| `LocalFileGetSaved` | `[]` | 无已保存列表 | |
| `LocalFileTemplates` | `[]` | 模板面板空 | loginpage 模板区留白；补充可后续注入 |
| `GetHash` / `_GetHash` | false | | |
| `GetSupportScaleValues` / `GetFontThumbnailHeight` | false | 无额外缩放集 | 系统缩放走设备系数 |
| `CheckUserId` / `SetAdvancedOptions` / `ApplyAction` / `SetFullscreen` | false | 无内容交互 | 全屏可在 ArkTS 侧实现（当前未接） |

## 3. 未实现（无官方UI入口或登录页未暴露）

| 能力 | 现状 | 升级建议 |
|---|---|---|
| PDF 编辑器 | 能力缺失（模板页有卡片，点击无动作） | 接入 PDF 分支需 doctrenderer/PDF 引擎 |
| 云存储（Google/OneDrive etc.） | 未接入 | 需各 OAuth + 外部云 API 适配 |
| 协同编辑/评论在线同步 | 未接入（本地 editing） | 需 DocumentServer 服务端 |
| 保存到云端/复制云端链接 | 未接入 | 同云存储 |
| 打印（PDF 导出） | 入口禁用 | 需 core/doctrenderer 打印分支 |
| 宏编辑器 | 入口隐藏 | sdkjs macros 引擎 + 存储 |
| 插件市场 | 入口隐藏 | plugins 系统 + 插件仓库 |
| 拼写检查（在线词典） | 离线降级（无字典） | 内置字典包 |
| 加密文档（密码保护） | 降级 | CryptoMode 支持（core 层可加） |
| 代码签名/数字签名 | 降级 | 需签名服务 |
| 表单填写（在线验证） | 部分（本地渲染可看） | 表单工具链 |
| 模板新建（线上模板库） | 空白 | 本地模板注入 |

## 4. 引擎层已知差异（非降级、属平台适配）

| 项 | 说明 |
|---|---|
| 渲染引擎 | web 字形引擎（libfont wasm 语义），非 C++ native 光栅；像素由 ArkWeb 合成 |
| 桥形态 | `window.AscDesktopEditor` = JS 装配（arkweb 同步代理 `AscNative._call`），非 CEF V8 对象 |
| 字体元数据 | `__fonts_files/__fonts_infos` 直注（R/I/B/BI 顺序），AllFonts.js 供 `g_fonts_selection_bin` |
| sdk 双文件 | min（核心）+ common（Serialize2/History/…），官方 `loadSdk` 时序自动加载（不得预载、不得在 min 清单叠加类文件） |
| `window.native` | 保持未定义！仅保存序列化期间临时挂 `Save_End`（全局 stub 会放跑 loadScript 假成功分支） |

## 5. 验收记录

- M1 官方构建链 ✅ / M2 桥 ✅ / M3 欢迎页+docx 打开 ✅（2026-09-04 上午，真机 192.168.1.8）
- M4 打开三格式 + 保存闭环 ✅（2026-09-04 07:39 真机：编辑文本 → save.docx/sample.docx 内 `word/document.xml` 出现编辑内容，zip 校验通过）
- M5 清理 POC（探针/自测/AscSaveBridge/AscConvertBridge 移除）✅ 回归无异常（2026-09-04 07:46 真机）
- M5 补丁「关闭」链（web 语义，ff7a8ad）✅ 真机（2026-09-04 18:38）：文件菜单出现「关闭」项 → 点击 → 回欢迎页（`LSO_REQUEST_CLOSE -> welcome` 打点 + 截图双证）；同轮顺验 create:new（新建 docx 即点即开）
- M7 文件进出（90c15ee + c590e15）✅ 真机全闭环（2026-09-04）：
  - **打开**：`open:folder`（loginpage Open local file 官方命令 + FAB「打开」双入口）→ 系统「选择文件」picker 弹出；**外部文件 m7-open-test.docx → 渲染「M7-OPEN-TEST from external file」（第1页/共1页截图）**；三格式字节注入齐备（docx 756B/xlsx 50545B/pptx via LSO_OPEN_OK）
  - **保存三格式**：自动验收工具（`&m7auto=1` 仅显式带参触发）→ 序列化（DOCY/XLSY/PPTY;v10）→ saveBinRaw → x2t 按目标后缀选转换器 → **docx 26071B（document.xml 含 'M7AUTO-EDIT-OK'）/ xlsx 22810B（workbook+sheet1 合法）/ pptx 13392B（slide1 合法）**，全部 zip 校验通过
  - **导出/另存为**：编辑页「导出」FAB → 系统「选择路径」对话框（文件名自动带出）→「保存」→ **Docs/sample.pptx 13392B 落盘，md5 与保存链产物完全一致（d74fe148…）**
  - **recents 真数据**：打开过的文件（sample.pptx/xlsx、m7-open-test.docx、Unnamed.docx）随重启持久显示
  - 注意：cell（xlsx）打开耗时 40-60s（wb/工具栏 GUI 懒建，v13 已知）；「正在保存文档」快速完成

## 6. 后续升级路线（建议次序）

1. 模板库：`LocalFileTemplates` 返回沙箱模板 JSON（官方 loginpage 模板卡片直接吃）
2. PDF 编辑器/打印：接 core 的 doctrenderer（现有 x2t 链可作 pdf 输出的降级前身）
3. 拼写检查词典包
4. 全屏/窗口管理：ArkTS 全屏能力 + `SetFullscreen` 桥
5. 宏：sdkjs macros + 宏存储
