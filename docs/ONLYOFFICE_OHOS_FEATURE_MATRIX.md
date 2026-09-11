# ONLYOFFICE DesktopEditors 移植到鸿蒙 —— 功能支持矩阵

> 版本：2026-09-12（文件格式扩展：打开 9 种格式 + 文件管理器「打开方式」接入后）
> 基座：官方 sdkjs（v9.4.0，`--desktop` 构建，min+common 双清单经官方 loadSdk 自加载）
>       + 官方 web-apps（grunt 产物）+ 官方 loginpage（桌面版欢迎页）+
>       ArkTS 壳（ArkWeb + native x2t 转换 + 文件沙箱）。
> 说明：每一项 = 官方桌面能力 | 当前状态 | 返回值/行为 | 升级建议。
> 未特别注明即遵循官方 CEED（CEF V8 回调）降级契约（false/''/0/{}/[]）。

## 1. 已实现（与本机核心链路）

| 能力 | 状态 | 说明 |
|---|---|---|
| 官方欢迎页（新建卡片；recents 面板已隐藏） | ✅ | loginpage 官方产物；**「最近使用」面板自 2026-09-05 起隐藏**（B 架构文件位置为 picker 授权 uri、授权会回收 → 路径语义不成立）；`recents.ets` 与打开链代码保留，待持久文件位置机制恢复 |
| 打开本地文件（系统选择器） | ✅ | `open:folder`（loginpage「Open local file」官方命令）→ ArkTS `DocumentViewPicker.select`（9 种后缀过滤，由 `formats.ets` 派生）→ 拷贝沙箱 → x2t 打开链；选择器按后缀**硬过滤**（非白名单后缀不出现，实测 exe/odt 不可见） |
| 打开方式（文件管理器交付） | ✅ | `module.json5` 声明 `viewData` skill（`scheme=file` + `utd=general.entity` + `linkFeature=FileOpen`）→ 文件管理器「打开方式」候选出现 Pure Office → `want.uri` → `handleLocalUri` 与 picker 共用处理链；不支持格式弹「暂不支持该格式：&lt;名&gt;」（2026-09-12 真机 1.6：docx 进编辑器 / odt 被拦） |
| 打开 9 种格式（docx·xlsx·pptx + doc·xls·ppt·rtf·txt·csv） | ✅ | 沙箱源文件 → x2t 按源后缀分派 → 官方 `openDocumentFromBinary` → 引擎渲染（word 走官方 loadDocument；cell/slide 走 DI 链+Gateway 踢闸）。旧二进制（doc/xls/ppt）与 csv 需**显式下发格式对/编码分隔符参数**（x2t 方向表与转换 switch 缺 case，详见 `formats.ets` 与 KEYPOINTS）；2026-09-12 真机 9/9 通过 |
| 编辑（文本/表格等） | ✅ | 官方编辑器全套 UI（工具栏/右侧栏/状态栏/缩放/分页） |
| 保存（Ctrl+S / 自动保存） | ✅ | `asc_Save` 官方桌面协议骨架 → `asc_nativeGetFileData`（BinaryFileWriter → DOCY/XLSY/PPTY;v10）→ x2t 按**目标后缀**自动选转换器 → save.&lt;ext&gt; + 回写源文件；编辑内容进入 `word/document.xml`（真机核验）。目标后缀由 `formats.ets` 的 `saveExt` 决定：旧二进制与 txt 存为 OOXML、rtf/csv 原地保存；不可原地保存的格式弹「格式不支持保存」→ 确认后转另存为（2026-09-12） |
| 导出 / 另存为 | ✅ | 编辑页左下「导出」按钮 → 自动触发官方保存 → 系统保存对话框（`DocumentViewPicker.save`）→ 写用户选定位置 |
| 打印（系统打印） | ✅ | 工具栏打印按钮 / 文件菜单「打印」→ 页面元文件流（`Save_End` 真实长度截断）→ x2t `bin2pdf`（随包字体目录）→ `@ohos.print` 调起系统打印界面（选打印机或"打印为 PDF"）；临时文件启动时清扫（2026-09-11 真机三格式全通） |
| 分享 | 降级 | SDK 无 ShareKit（@ohos.share 缺失）—— 登记 P1：SDK 升级后接 `systemShare` |
| 新建空白 docx | ✅ | create:new（word）→ 官方空文档（`word/document/editor.js` getEmpty + bSerFormat 补丁） |
| 缩放/状态栏/多视图 | ✅ | 官方 UI 原生实现（100% 起点，Factor 1.0 语义） |
| 多页视图（新建提示） | ✅ | 官方功能（无 UI 依赖） |
| 字体（本地 12 个 Liberation 家族） | 部分 | `__fonts_files/__fonts_infos` 注册表 + web 字形引擎；文档字体名差异 → 默认字体替换（可见字形） |
| 中文/俄文等语言 | ✅ | 引擎语言包 + lang=zh-CN 参数；UI 中文完整 |
| 插件系统（web 语义） | ✅ | `isSupportPlugins` 提真（#73）；官方装配链 plugins.json server 链 → 后台插件 run → AddToolbarMenuItem/AddContextMenuItem 全通（2026-09-06 真机） |
| AI 插件（官方 3.2.2 AGPL） | ✅ | 构建链安装（build_editors_ohos install_ai_plugin：plugins.json + plugins/ai + plugins/v1）；顶部「AI」tab/7 按钮/Settings/Chatbot 窗口全部真机验证；**对话需模型配置**（Ollama localhost 或 OpenAI 等，配置入口=无模型时 Chatbot 点击自动弹设置窗口，官方降级语义）；**联网=页面 fetch 直连（方案 A：loadRaw 对非 localhost URL 返回 null 放行走 ArkWeb 默认网络栈，2026-09-08 真机 1.4 DeepSeek models+多轮 chat 全通 ✅）** |

## 2. 降级（官方已实现、本机按契约降级）

| 桥方法 | 返回 | 官方UI表现 | 备注 |
|---|---|---|---|
| `isSupportMacroses` | false | 宏入口隐藏 | 宏引擎（V8 附加）未自带 |
| `isSupportPlugins` | true（2026-09-06 提真，#73） | 插件菜单/系统显示 | web 语义插件运行时（sdkjs plugins.js）+ plugins.json server 链；插件无签名校验（本地链，仅随包官方插件） |
| `isSupportNetworkFunctionality` | false | 在线功能入口隐藏 | 纯本地链 |
| `IsSupportNativePrint` / `IsFilePrinting` | false（桥面保持） | 官方打印面板链路不启用 | 打印已由自建链实现（元文件流 → x2t bin2pdf → `@ohos.print`，见 §1「打印」行）——这两项保持 false 是官方语义分割，不影响用户可见的打印功能 |
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
| `CheckUserId` / `SetAdvancedOptions` / `ApplyAction` | false | 无内容交互 | |
| `SetFullscreen` | true | **已接**（2026-09-11）：PPT 放映全屏——Pad 收起 tab 条 / PC 沉浸最大化（`ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER`），退出按进入前窗口状态精确还原 | 真机 1.5/1.6 均✅；调用被 ascshim 3.7.1 在放映期临时恢复的 `AscDesktopEditor` 触发（3.7 平时删除它） |

## 3. 未实现（无官方UI入口或登录页未暴露）

| 能力 | 现状 | 升级建议 |
|---|---|---|
| PDF 编辑器 | 能力缺失（模板页有卡片，点击无动作） | 接入 PDF 分支需 doctrenderer/PDF 引擎 |
| 云存储（Google/OneDrive etc.） | 未接入 | 需各 OAuth + 外部云 API 适配 |
| 协同编辑/评论在线同步 | 未接入（本地 editing） | 需 DocumentServer 服务端 |
| 保存到云端/复制云端链接 | 未接入 | 同云存储 |
| 打印（PDF 导出） | 入口禁用 | 需 core/doctrenderer 打印分支 |
| 宏编辑器 | 入口隐藏 | sdkjs macros 引擎 + 存储 |
| 插件市场 | 无在线市场 | 插件系统已可用（随包官方插件）；在线市场需插件分类/下载服务（可后续） |
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
- 三格式全链复核（2026-09-05 真机 `a759995` 后）✅：**docx/xlsx/pptx 「打开→渲染→编辑→保存→产物 zip 校验」逐一通过**——
  - **docx**：openDocumentFromBinary 252713B → 插入读回 OKИзменение → save.docx 33768B，document.xml 1017 w:t（原文 1016 + 编辑标记 1）；截图：全套菜单/工具栏/8 页内容正常
  - **xlsx**：DI 链打开（POC-13 修复链）→ grid/工具栏/全部菜单选项卡正常（tbLen 629415）→ save.xlsx 22805B 含编辑内容
  - **pptx**：本次两处修复后才全通——① DI 链补 `_m.document`（slide onEditorPermissions 读 this.document.info，未设 → 权限分发崩 → asc_LoadDocument 跳过 → 编辑器空白）；② slide 引擎 `_openDocumentEndCallback` 双闸门（serverId + images）→ Gateway 踢闸补 `asyncImagesDocumentEndLoaded`；save.pptx 布局/文本保留、zip 合法
  - **工具栏达成根因**：cell/pptx 此前工具栏空白 = 权限链未分发（asc_onGetEditorPermissions 引擎回调仅服务器链发）→ 修复 = 直接构造 `asc_CAscEditorPermissions` + onEditorPermissions.call（详见 KEYPOINTS §11）
  - 生产形态：M7_TARGET 置空后欢迎页/编辑器无任何自动测试痕迹（recents 真数据 + 四新建卡片 + 打开 FAB，截图确认）
- **AI 插件 + 插件链真机矩阵全通**（2026-09-06，m7accept 验收态，word（docx））✅：
  - 装配链：plugins.json/config.json/v1 plugins.js fetch 200 → serverPlugins.plugins=arr1 → store=1（visible=true）→ 插件 tab liDisplay=inline-flex（**根因修复**：background-only 部署时 Plugins.js:485 `me.viewPlugins.backgroundBtn.show()` undefined——onResetPlugins 背景分支早退未建钮；修复=parsePlugins wrap，见 KEYPOINTS §17）
  - run 链：后台插件「AI」开关点击 → pluginsMap/runnedPluginsMap 含 AI → iframe_<guid> 隐藏帧 index.html → `Asc.plugin`/`Asc.PluginWindow`/`executeMethod` 均 function（sdk-all plugin_base 注入 iframe，无需替换 v1 框架）→ Buttons.ButtonsToolbar=7
  - 工具栏：AddToolbarMenuItem → 「AI」tab（data-tab=随机 UUID！Button id 缺省 y()——探针按 caption 动态取 key）→ 面板 7 按钮（Settings/Chatbot(ask-ai 图标)/Summarization/Translation…）
  - 窗口链：Chatbot 点击 → chatWindowShow →（有模型时）PluginWindow.show → sdkjs ShowWindow → asc_onPluginWindowShow → **PluginDlg 弹窗 iframe src=plugins/ai/chat.html?lang&theme-type ✅**
  - **无模型降级（官方语义）**：AI.Request.create 无模型 → 自动弹 settings 窗口（engine.js:466-470）——不是 bug；验收态预注入双键（storage_key+actions_key，Ollama 本地模型）后 chat 直接开
  - 生产形态：插件链全程验收态触发；生产 URL 无 m7auto 不加载探针；模型配置由用户 settings 窗口自理
- **构建可复现演练**（2026-09-06，#71 收尾）：`rm -rf entry/src/main/resources/rawfile/onlyoffice/*`（11 项构建产物清零）→ `deploy_ohos.sh` 从零全链重生成+构建+安装+启动 RC=0；设备干净重装（uninstall+install）后 m7 全链——打开（rc=0）/保存（zipok×2）/插件链（srvPlugins=arr1/AI tab/chat 窗口）全部正常，重装清 localStorage 后 AI 窗口走官方无模型降级 settings（预期语义）——**一键可复现验证通过**

## 6. 后续升级路线（建议次序）

1. 模板库：`LocalFileTemplates` 返回沙箱模板 JSON（官方 loginpage 模板卡片直接吃）
2. PDF 编辑器/打印：接 core 的 doctrenderer（现有 x2t 链可作 pdf 输出的降级前身）
3. 拼写检查词典包
4. 宏：sdkjs macros + 宏存储
