# ONLYOFFICE OHOS 运行时资源缺口审计

日期：2026-09-05。触发：替换空演示模板后页面日志出现 `_offline_media/imageX` 系列
加载失败，用户指出「构建流程可能缺的不止几张图，需要系统分析打包完整性」。

## 审计方法

证据通道 = rawfileLoader 的运行时 miss 打点（设备 web_console.txt 中
`rawfile miss: <url>` 记录 WebView 请求过但 rawfile 中没有的每一个资源）。
对最新日志去重汇总，得到 **9 类运行时缺口**（下表）。随后逐类查明官方机制
（在 third_party 源码树中定位生成方/消费方），按「我们的链缺在哪一层」分级。

## 缺口清单与官方机制

### 1. `_offline_media/image1..6.jpg|png` — 引擎虚拟媒体缓存区（P0 级机制缺失）

- 现象：演示编辑器打开文档（含版式预览/内嵌图形时）请求
  `webapps/apps/presentationeditor/main/_offline_media/imageN`，全部 miss。
- 官方机制：`_offline_media/` **不是静态打包资源**（官方 deploy 树里也不存在此目录；
  sdkjs/web-apps/desktop-apps 源码树全无该字面量）——它是引擎对「文档媒体/预览图」
  的**运行时虚拟路径**（文档 URL 为 `_offline_` 时的媒体登记约定）。供给方按部署形态不同：
  - 服务器版：文档打开链把文档内嵌媒体落到缓存目录，WebView 请求 `_offline_media` 命中；
  - 桌面版：C++ 侧 Local 文件链（LocalFile_End）供给。
- 我们的 B 架构：打开走 openDocumentFromBinary 单点注入，**没有实现媒体供给层** → 引擎
  请求无应答（rawfileLoader 将非 rawfile URL 记为 miss）。
- 影响分级：**P0**——含图片/图形/版式预览图的文档渲染依赖该层。修复方向：打开链
  （ark 侧或页侧）实现 `_offline_media` / `media/` 前缀应答（sdkjs/slide/api.js:5681
  的 `documentUrl + 'media/'` 是另一同族路径）。

### 2. 中文字体（CJK）缺失 — 字体表只有拉丁字族（P0 级功能缺陷）

- 现象：演示编辑器占位文字「点击添加标题/文本/备注」渲染为方块（截图证实）——
  引擎在字体注册表（__fonts_files，仅 Liberation Sans/Serif/Mono 12 个）中找不到
  任何 CJK 字体。**中文文档正文/输入中文都将渲染为方块。**
- 官方机制：官方部署随包带全套中文字体（desktop-apps 打包字体目录含 Noto/方正等）。
- 修复方向：系统字体（HarmonyOS Sans / Noto Sans CJK）加入 FONT_FILES 与 FONT_INFOS
  注入表 + 预加密（build_editors_ohos.py 涉及）。

### 3. `sdkjs/slide/themes//themes.js` — 幻灯片主题面板数据（P1 功能缺失）

- 现象：presentationeditor Main.js:199 `api.SetThemesPath("../../../../sdkjs/slide/themes/")`
  → 引擎 loadScript(`themes.js`)（sdkjs/slide/api.js:1205）→ 3 次 miss。
- 官方机制：`sdkjs/slide/themes/src/` **只有 32 个主题 pptx**（01_blank…36_wild）；
  `themes.js`（主题列表定义+缩略图源）由「主题转换链」生成（桌面版 =
  desktop-apps/win-linux/src/cthemes.cpp；服务器版为 document-server 构建段）。
  我们的构建链（grunt + build.py --desktop）**不包含该生成步骤**。
- 影响分级：**P1**——「设计→主题」面板无数据、主题切换功能不可用。修复方向：落地
  主题转换链（本仓库有 themes/src 32 个 pptx + cthemes.cpp 参照），或按引擎
  ThemeLoader 契约生成 minimal themes.js。

### 4. `sdkjs/common/Images/fonts_thumbnail_ea@2x.png.bin` — 字体缩略图（P2 UI）

- 现象：字体下拉框加载 EA（东亚）字体缩略图失败（ComboBoxFonts.js:59-66）。
- 官方机制：字体缩略图为 core fontengine 构建产物（普通图片 + .bin 二进制集合），
  官方部署由构建期的字体准备链生成；sdkjs 源码树无此资产（.gitignore 提及）。
- 影响分级：**P2**——字体下拉缺「字体外形预览」图（列表依然可用）。

### 5. `webapps/apps/spreadsheeteditor/main/resources/help/zh/Contents.json` — 帮助目录（P2）

- 官方机制：帮助文档为 web-apps 构建链的可选步骤（帮助 zip → zh/Contents.json）。
  我们的 grunt 未跑帮助生成。
- 影响：电子表格帮助面板（? 帮助按钮）打开时缺目录/文档。P2。

### 6. `onlyoffice/favicon.ico`（P3）

- 官方 index.html 有 favicon 链接；deploy 树的 favicon 在 apps/.../resources/img，顶层
  rawfile/onlyoffice/favicon.ico 缺失。P3 无影响。

### 7. `onlyoffice/plugins.json`（P3，已解释）

- AI 插件撤除后无 plugins 配置；引擎请求 404 属预期（保留 404 日志）。

### 8. `https://templates.onlyoffice.com/dashboard/api/oforms`（P3 在线依赖）

- 欢迎页「Templates/表格模板」在线 API。离线架构下 CORS 拒绝为预期——左侧
  Templates 面板项无数据。若要离线模板能力需自带模板包（后续需求）。

### 9. ServiceWorker 注册失败（P3 在线依赖）

- `document_editor_service_worker.js` 请求失败（WebView fetch）。官方 web 用它做
  离线缓存优化；B 架构 rawfile 本地供给无需 SW，失败无害（日志化即可）。

## 结论与处置建议

**用户判断正确**：资源缺口不止几张图，共 9 类；其中 1 类为本机机制缺失（_offline_media
供给层）、1 类为**主功能级缺陷（CJK 字体）**、1 类为功能级（themes.js 主题面板），
其余为 UI 装饰/在线依赖/已解释项。

## 2026-09-05 后续：CJK 字体机制修复进展（追加）

用户 Goal「主界面/pptx/docx/xlsx 默认中文」——界面中文已修复（homeUrl 加 lang=zh-CN，
欢迎页全部中文✅）。编辑器中文渲染基线：
- 三张注入表已齐（__fonts_ranges 补上，见 build_editors_ohos.py 注释）；
- 字体三坑记录在 build 注释（CFF/VF 不可用；static TTF + OS/2 位全 1 为现行方案）；
- 13 个字体 XHR 全部 200（CJK 9258880 字节）——字节确实进引擎；
- **渲染仍方块，未决**：wasm libfont 字符→字形一环（定位对、字形 notdef）。
- 最后一改 `g_fonts_selection_bin` unicode ranges 全 1（此前硬编码 0）——因设备
  掉线未终验。恢复后：m7 m7file=demo-cn.docx → 查 LSO_FONT_XHR/PROF_PICK。

建议处置顺序（按影响）：
1. **P0-#2 CJK 字体**：字体表补 CJK 字族（预期改动集中在 build_editors_ohos.py 字体
   配置 + 系统字体源发现），先做——影响中文文档显示。
2. **P0-#1 _offline_media 供给层**：实现引擎虚拟媒体应答（下一步打开含图文档的
   前置）。与「打开链重构（media 注入）」同任务。
3. **P1-#3 themes.js**：落地主题转换链（内容多、独立任务）。
4. **P2**：字体缩略图、帮助文档——可选优化。
5. 保障机制：把「运行时 miss 审计」固化进构建/部署链（deploy_ohos.sh --audit 或
   独立 check_assets 脚本：冒烟三格式→收集 miss→对比基线→异常即报）。
