# ONLYOFFICE Fork 化迁移方案（替代 patches + ascshim 注入层）

> 状态：方案已交叉验证修订（v2，2026-09-20）｜ 前置：现行方案全景盘点（本文 §2）
> 验证方式：关键假设逐项实证（源码/构建脚本核实），修订处以〔v2〕标注

## 1. 背景与动机

现行适配方案 = 官方 submodule pin v9.4.0 + 幂等 patch + ascshim 运行时注入 +
构建后处理。功能已闭环（三格式打开/保存/打印/字体/插件全通），但结构上有四类
**递增的维护成本**，是本方案的动机：

| 成本 | 表现（均为已发生的事实） |
|---|---|
| 注入层脆弱性 | wrap/hook 依赖官方源码内部结构：原型链 hook 勾错过 PDFEditorApi（docx 渲染崩）；AMD 零依赖声明类文件加载顺序抖动 → 打开偶发卡骨架屏（19937b4）；同类风险文件实测 88 个（§4.2） |
| 反直觉工作区态 | 「submodule modified 是预期态」——官方树上的工作区改动由 patch 脚本现场应用，任何 git 操作前都要人为记住这一点；core sdkjs web-apps 三仓各一份 |
| 补丁表达力上限 | patch 只能表达行级差异，不能表达行为分支；升级 9.5 时每个 patch 要靠人脑重新映射到漂移过的官方源码 |
| 语义靠外模拟 | DI 打开链（30_open 3.4）、保存链（40_save）全靠外部 wrap 官方对象，官方源码里本有 isDesktopApp 分支模式（apiBase+word/api.js 内 90 处）与 Local 桌面宿主段可走正路 |

**Fork 化的本质**：把「运行时对抗官方源码」翻转为「源码内显式定制分支」，
升级时的差异从「不可见的运行时行为」变成「可见的 git merge 冲突」。

## 2. 现状定制面全景（盘点结论，2026-09-20）

### 2.1 四层结构

```
L1 submodule 补丁层   5 个 .patch（core×3 + sdkjs×1 + webapps×1），官方树工作区应用
L2 ascshim 注入层     19 段拼接 3437 行 + 5 占位符（make_ascshim.py PARTS）
L3 构建后处理层       build_editors_ohos.py 20 项操作（注入/重写/品牌化/裁剪/生成）
L4 宿主桥层           AscNative._call（201 CEF 方法收敛）+ execCommand 12 子命令
                      + runJavaScript 反向调用 + URL 参数约定 + rawfileLoader 拦截
```

### 2.2 L1 补丁清单（吸收进 fork 的直接对象）

| patch | 文件 | 内容 | 性质 |
|---|---|---|---|
| core-ohos/02 | doctrenderer/hash.cpp（+172 行） | openssl 3.0 无 MD2 时软件回落 | 构建兼容 |
| core-ohos/01 | harfbuzz/make.py（+13 行） | apply_patch 幂等（防嵌套包裹） | 构建兼容 |
| core-ohos/03 | freetype configure | exec bit | 构建兼容 |
| sdkjs-desktop/01 | configs/{word,cell,slide}.json（裁剪）+ apiBase.js（+5 行） | desktop 构建清单裁剪（Local/common.js 崩溃源剔除）+ getEmpty 补 editor.js 段 + bSerFormat 显式 true | **功能定制** |
| webapps-desktop/01 | ColorPaletteExt.js（1 行） | define([]) 显式声明 BaseView 依赖（卡骨架屏根因） | **功能修复** |

### 2.3 L2 ascshim 19 段职责速览

| 段 | 行数 | 职责 |
|---|---|---|
| 00_theme | 145 | 主题默认经典浅色（localStorage 预写）/ tab 主题色上报 / 导出 PDF 菜单隐藏 |
| 09_fonts | 138 | CJK 字体流保供（rawfile 预取 + XOR 解码 + g_fonts_streams 装填） |
| 09_fontpick | 18 | 字体映射探针（回归/smoke 用，onLogPickFont） |
| 00_boot | 110 | IIFE 引导 + base64 工具 + 自动保存默认关 + 插件 fetch 取证 + 自检 |
| 10_engine | 97 | Gateway wrap：字节打点 + serverId/images 踢闸 + 字体 XHR 取证 |
| 20_bridge | 303 | 字体三表注入 + CEF 201 方法装配 + AscDesktopEditor 对象 + 官方 shim 内嵌 + 打开链注入桥 + loginpage recents 桥 + 就绪探针 |
| 29_inputfocus | 67 | 非 PC 形态输入焦点抑制（两条夺焦路径的原型 hook + 补聚焦） |
| 30_open | 985 | m7 自动验收 + DI 打开链（模拟 api.js _onAppReady：loadConfig/asc_CDocInfo/权限三刀）+ AI 插件修复 + 文件菜单新建桥 |
| 40_save | 625 | 保存链管控（asc_Save 重写/isOffline 覆写/DownloadAs 重定向/requestClose 覆写/-25 拦截）+ 放映全屏通道 + 头部装饰/菜单显隐/欢迎页精简等 UI 定制 + X 重定向守卫 |
| 44_modalguard | 78 | Desktop.js 七事件无保护 handler 的 TypeError 兜底 |
| 45_print | 164 | 打印链引擎侧（asc_Print wrap → 元文件流 → print:bin） |
| 46_fontimg | 74 | 用户字体名字图（canvas 复刻 wrap updateVisibleFontsTiles） |
| 47_img | 109 | 图片管线（getUrl 剥 _offline_ 前缀、引用重写） |
| 48_mediaunpack | 113 | 媒体供给（_offline_media/<name> 拦截应答） |
| 49_doclang | 59 | xlsx 编辑器语言预写 localStorage |
| 50_init | 24 | 初始化尾（AscNative 等待循环） |
| 51_scrollpad | 108 | 触摸拖拽滚动条（capture 层坐标接管 + 外扩 8px） |
| 55_lic | 101 | 许可信息弹层（target=_blank 拦截 → 自绘 iframe 弹层） |
| 57_about | 119 | About 版本通路（app:version 补发） |

### 2.4 L3/L4 要点（详见盘点记录，此处只列与迁移相关项）

- L3 对**源码/产物内容**的改动：ascshim script 注入（4 页）、viewport 注入、
  AllFonts.js 整体重写、字体 XOR/子集化/name 重写、缩略图精灵生成、
  品牌化文本替换（LeftMenu/About/app.css/欢迎页 About）、目录裁剪（help 596M 等）
- L4 是纯 ArkTS 侧，**不属 fork 范围**，但它的 201 方法表/命令集是与 L2 20_bridge
  配对的契约，迁移期冻结

〔v2〕**license 遗留疑云已核实——无消失的定制**：pack_web.py 时代的 docscoapi.js
license 解冻 patch 确未随迁（docscoapi.js:155-160 至今 `onLicense(null)` 原样），
但现行链由**两级显式提供** Success/Edit：引擎侧 `common/Local/license.js`
（_onEndPermissions 覆写，经 sdkjs-desktop patch 的 configs desktop 段注入，deploy
6 份 bundle 均含尾标实证）+ 页面侧 30_open.js:604-655 直发权限。若拿掉
Local/license.js 才会退回基础版对 licenseResult=null 发 licenseType=Error 的冻结
路径。附带结论：官方 Local 段两个文件中 **license.js 已在用、只有 common.js 被裁**——
阶段 3「Local 段 OHOS 化」实际只差一个文件（见 §5 阶段 3）。

〔v2〕**L2 拼接骨架与段间耦合**（决定逐段迁移的顺序约束，迁移前必读）：
- 00_boot.js:1 开外层 IIFE、50_init.js:24 闭合——10_engine～50_init 共用同一
  函数作用域 + strict 模式；00_theme/09_fonts/09_fontpick 在 IIFE 外各自独立；
  51_scrollpad/55_lic/57_about 也在外（排在 50_init 之后）
- **20_bridge 与 50_init 语法连体**：`var INSTALL = function(){`（20_bridge.js:76）
  的函数体闭括号在 50_init.js:5——单独删任一段 = 整个 ascshim 语法错误
- `__lsoB64`（00_boot.js:22）被 5 段调用（30_open/40_save×3/45_print/48_mediaunpack）
- **10_engine 与 30_open 功能硬耦合**：DI 打开链依赖 10_engine 的 Gateway 踢闸
  （删 10_engine 留 30_open → 文档加载永不完成，无报错纯卡死）
- 3.7「删 AscDesktopEditor」（40_save.js:300）与 20_bridge INSTALL 装配
  （20_bridge.js:91）构成运行时状态机（INSTALL 晚于删除执行；放映
  preview:show/hide 再翻转）——40_save 保存语义与放映通道迁移必须同批处理
- 自检登记 11 处（window.__lsoShim，删段只打 MISSING 不崩）；`__lsoWaitN` 被
  20_bridge 与 50_init 共享递增（重试预算互相消耗）
- 同作用域 var 提升合并（30_open 泄漏 5 个顶层 var、20_bridge 2 个）：迁移中
  新增同名 var 会静默互踩
- **自包含段（可独立迁删，无入站依赖）**：00_theme、09_fontpick、09_fonts、
  29_inputfocus、44_modalguard、47_img、48_mediaunpack、49_doclang、51_scrollpad、
  55_lic、57_about、45_print（半：语义前提是 30_open 的 canPreviewPrint=false）

## 3. 目标架构

### 3.1 Fork 仓库集合

| 仓库 | 处置 | 理由 |
|---|---|---|
| **sdkjs** | fork → `github.com/hackeris/sdkjs` | 引擎侧定制大头：configs 裁剪、getEmpty/bSerFormat、打开/保存语义、字体/图片/媒体供给、滚动条触摸、焦点守卫全在引擎行为层 |
| **web-apps** | fork → `github.com/hackeris/web-apps` | UI 层定制：ColorPaletteExt 类修复、菜单显隐、头部装饰、About/许可弹层、字体名字图、字体管理入口 |
| core | **不 fork**，保留 patch 工作流 | 3 个 patch 全是构建兼容类（openssl/harfbuzz/exec-bit），与运行时行为无关、升级漂移风险极低；fork 反而引入一条「无功能收益的升级面」（〔v2〕实测 .git 175M，存储不是障碍，纯收益考量） |
| desktop-apps | 不 fork，loginpage 定制保留 L3 后处理 | 现状干净；欢迎页改动是文本级后处理，量小且 loginpage 升级频率低。若后期欢迎页定制变重再 fork（决策点 §7.3） |
| build_tools | 不 fork | 现状零改动 |

### 3.2 分支模型与升级流

```
fork（以 sdkjs 为例，web-apps 同型）
  master ──┬── 基底 = 当前 submodule pin 的官方 commit（非 tag，见下）
           ├── OHOS 定制提交序列（每定制一提交，[OHOS] 前缀）
           └── 官方发 9.5 → git merge <新 release tag/ref> → 解冲突 → 打 tag ohos-v9.5.0.1
主仓 third_party/sdkjs → pin fork 的 ohos-v* tag（永不 pin 官方 ref）
```

〔v2〕**基底必须取当前 submodule pin 的 commit**（sdkjs 72b0421 / web-apps
9c0ca538——均为官方 master 上的 release merge 点，**不是** v9.4.0.N tag）。
官方发布模型（已核实）：`release/v9.4.0` 是活分支、持续打 `v9.4.0.N` tag
（N 已至 105+），master 频繁 merge release 分支。若基底取 tag，产物与现状必有
源码级差异，阶段 0「字节等价」验收无从谈起；取当前 pin commit 则定制提交前的
树与现状完全一致。升级时再 merge 官方新 tag（或 release 分支头）即可。

- 升级节奏完全由我们自己掌控：不升级时 fork 与「官方 pin 点 + 定制提交」等价
- 升级演练 = merge 官方新 tag → 跑 `grunt-build.sh` 全链 → 真机回归 33 case
  → tag → bump 主仓 submodule 指针（一次提交）

### 3.3 定制提交纪律（降低 merge 冲突的核心约束）

1. **改官方文件**：一律标记包裹 + 尽量收敛为单点插入——
   ```js
   // [OHOS: touch-scroll] 触摸按下判定留边界容差，桌面滚动条窄条可靠区不足
   <改动行>
   // [/OHOS]
   ```
   检索约定：`git log -S'[OHOS:'` 可全量定位定制点；merge 冲突时标记即上下文。
2. **新增文件**：集中进各自仓库的 `ohos/` 目录
   （`sdkjs/common/ohos/`、`web-apps/apps/common/main/lib/ohos/`），官方文件只留
   「一行调用插入」。
3. **一定制一提交**，message 格式 `[OHOS-<域>] 动机 + 实测依据`（延续 patches 文件
   头注释的规范——补丁文件头注释里的「为什么/坑/证据」整体迁入提交信息与源码注释）。
4. **行为分支优先于改写**：能用 `if (AscOHOS.isEnable)` 分支表达的，不改官方
   原逻辑行，块级包裹。
5. **configs 的增与减走两条路**〔v2 已实证官方机制〕：sdkjs build.py 官方内建
   `--addon PATH`（可重复），合并语义 = dict 递归合并 + **list 只追加不能删减**
   （build.py:96-118 merge_into/load_configs）。因此：
   - **新增文件（ohos/ 模块）零冲突**：fork 里放 `ohos/configs/word.json` 追加
     清单，构建命令加 `--addon ohos` 即可，官方 configs 一个字不用改；
   - **裁剪（desktop 段剔除 Local/common.js）addon 表达不了**，候选三路：
     a) 阶段 3 修好 Local/common.js 后裁剪自然消失（configs 回官方原样，首选）；
     b) 不传 `--desktop`，改用 addon 把所需 desktop 文件（Local/license.js 等）
        追加进 min 清单（需核实 min 列表内顺序语义）；
     c) 退回改官方 configs + 标记包裹（a/b 均不可行时的兜底）。

### 3.4 职责边界（终态）

```
┌─ 主仓（PureOffice）────────────────────────────┐
│ ArkTS 宿主（EditorPage/ascBridge/DocTabHost）    │ ← 不变
│ AscNative 桥 + execCommand 命令总线              │ ← 冻结契约
│ 字体工程/精灵/模板/版本（build_editors 字体部分） │
│ ascshim 收缩为：CEF 桥装配（20_bridge 核心）+    │
│   debug/验收段（m7、探针）                       │
├─ third_party/sdkjs → fork ─────────────────────┤
│ OHOS 平台模块（common/ohos/）：字体流保供、图片/  │
│ 媒体供给、保存语义、打开链 Local 段、触摸/焦点     │
├─ third_party/web-apps → fork ───────────────────┤
│ UI 定制：显隐/装饰/About/弹层/字体下拉/入口       │
├─ third_party/core → 官方 + patch（不变）─────────┤
└──────────────────────────────────────────────┘
```

**判据**（一句话版）：依赖官方源码内部结构的 → fork；与 ArkTS 宿主配对的 → 主仓；
测量用途的 → 主仓 debug 段。

## 4. 定制点迁移分类表（逐段去向）

### 4.1 L1 补丁 → 阶段 0 全量固化

全部 5 个 patch 中：sdkjs×1、webapps×1 固化为 fork 提交（迁移后删除
patches/sdkjs-desktop、patches/webapps-desktop 与对应 patch_*.sh 的相关段）；
core×3 保留现行工作流。

### 4.2 L2 ascshim 19 段去向

| 段/小节 | 去向 | 迁移形态 |
|---|---|---|
| 44_modalguard | **sdkjs fork** | Desktop.js 七 handler 源码加守卫（if 保护，官方行为不变） |
| 29_inputfocus | **sdkjs fork** | document focus 监听器源码加守卫 + closest('#editor_sdk') 判据 + 吞后补聚焦；`nofocus=1` URL 开关语义保留（宿主传参） |
| 51_scrollpad | **sdkjs fork** | scroll.js `_MouseHoverOnScroller` 加触摸容差（外扩判定进引擎，删 capture 接管） |
| ColorPaletteExt（已 patch） | web-apps fork | 已是 patch，固化提交；〔v2〕同类 `define([])` 零依赖声明文件实测 **88 个**（旧口径 84 = 扣除 pdfeditor 4 个），fork 里成批修复（比产物层字符串替换可靠）。注意 ColorPaletteExt 修复后已带 1 依赖、不属该集合，属「同类风险」 |
| 00_theme 0.11 / 40_save 3.9、3.9.1（菜单与装饰显隐） | **web-apps fork** | 〔v2〕官方语义覆盖度已逐项核实：头像按钮**无**官方开关（Header.js:963-971 无条件渲染，layout 通道需 license）→ 源码改；头部 X 官方 `customization.close` 粗粒度且本壳 isDesktopApp 下本就不渲染（ascshim 隐藏的是空槽）→ 可源码删槽；save-as/export-pdf **无**单项开关（FileMenu.js 显隐公式固定）→ 源码改；「用模板创建」**有官方门控**——Desktop.js:578-580 `native.features.opentemplate` 门控被官方注释掉，fork 恢复一行 + 宿主 GetLocalFeatures 返回 `opentemplate:false` 即隐藏（纯配置，不改逻辑） |
| 57_about | **留主仓**（〔v2〕修正） | app:version 的消费方是 desktop-apps loginpage 的 panelabout.js:149/297（欢迎页域），与 web-apps About.js 无关——编辑器页 About 版本走 `{{PRODUCT_VERSION}}` grunt 构建期占位（Gruntfile.js:279-295/814），fork 化时由 grunt-build 传 `PRODUCT_VERSION` env 接上版本链即可，57_about 段随欢迎页域留主仓 |
| 55_lic | **web-apps fork** | 「许可信息」链接（现由 L3 品牌化注入编辑器页 About.js + ascshim 拦截 target=_blank）→ fork 里链接与弹层都进 About.js 源码，ArkWeb 无多窗口的适配收敛为源码内 dialog |
| 46_fontimg | **web-apps fork** | 字体下拉源码支持用户字体名字图 |
| 40_save 3.8.x 保存语义（asc_Save 重写/isOffline/DownloadAs/requestClose/-25） | **sdkjs fork**（阶段 3） | apiBase/api.js OHOS 分支（isDesktopApp 分支模式加 OHOS 条件） |
| 30_open 3.4 DI 打开链 + 10_engine 踢闸 | **sdkjs fork**（阶段 3，工作量最大） | 修好/适配官方 Local 段（common/Local/common.js）为 OHOS 宿主模式，替代外部模拟 _onAppReady |
| 20_bridge 2.33/3.5（打开注入桥 + 就绪探针） | sdkjs fork（随阶段 3） | 同上 |
| 09_fonts 装填 + 20_bridge 0 字体三表注入 | **sdkjs fork**（阶段 2） | 引擎侧 OHOS 字体模块：读主仓产的注册表 JSON 数据文件 + LoadFontBase64 按需拉取（XOR 解码进引擎） |
| 47_img / 48_mediaunpack | **sdkjs fork**（阶段 2） | 引擎资源加载 OHOS 分支（_offline_ 前缀在 getUrl 源头剥除、media 命中） |
| 45_print 引擎侧（asc_Print wrap） | **sdkjs fork**（阶段 2） | 打印 API OHOS 分支（元文件流 → execCommand('print:bin')）；宿主侧 @ohos.print 不动 |
| 20_bridge 0.2 用户字体（lsofonts）+ 尾部字典 | sdkjs fork（阶段 2） | 并入 OHOS 字体模块 |
| 00_theme 0.9（localStorage 预写）0.10（主题色上报） | **留主仓** | 纯宿主粘合，量小 |
| 49_doclang | 留主仓 | 同上 |
| 00_boot 自动保存默认关 | 留主仓（或 fork configs，迁移时定） | 官方 customization 语义 |
| 40_save 3.7.1 放映全屏通道 | 留主仓 | 与 ArkTS 窗口状态机强配对（桥语义） |
| 40_save 3.10 欢迎页精简 / 3.11 字体入口 | 留主仓 L3 后处理 | desktop-apps 不 fork（§7.3） |
| 00_boot 工具/自检、50_init | 留主仓（随桥装配收缩重整） | |
| 09_fontpick、10_engine 0.94、30_open 3.55 m7 段、00_boot 插件取证 | **留主仓 debug 段** | 回归框架载体（URL 门控纪律不变），不污染 fork |
| 20_bridge 1/2/3（CEF 201 方法 + AscDesktopEditor + 官方 shim） | **留主仓** | 与 ascBridge.ets 配对演进（契约冻结），升级时对照 desktop-sdk 重新提取 |

### 4.3 L3 构建后处理去向

| 操作 | 去向 |
|---|---|
| 品牌化文本替换（LeftMenu/About/app.css） | **web-apps fork**〔v2 已核实源〕app.css 是构建产物（源树无 css/ 目录），`.asc-about-office` 规则唯一源 = `apps/common/main/resources/less/about.less:2-10`（五编辑器共享 import）——fork 直接改 less 单点 + LeftMenu/About.js 文本；web-apps grunt 版本号 = `PRODUCT_VERSION` env → `{{PRODUCT_VERSION}}` 占位（Gruntfile.js:814），构建链接上即可让编辑器页 About 显示产品版本 |
| AllFonts.js 重写 + 字体三表 | 留主仓字体工程（数据生产）；fork 引擎侧只改「读入方式」（阶段 2） |
| ascshim 注入/viewport 注入 | 留主仓（注入的是主仓产物） |
| 裁剪/版本/插件/smoke/licenses/templates | 留主仓（与 fork 无关） |

## 5. 分阶段实施计划

每阶段独立可验收、可停在某阶段长期不动（阶段间无耦合债务）。
**双轨纪律：任一定制点只活在一处——迁入 fork 的段当轮从 ascshim PARTS 删除。**

### 阶段 0：建 fork 与提交固化（无行为变化，纯结构迁移）

1. `github.com/hackeris/` 建 sdkjs、web-apps 两仓，**基底 = 当前 submodule pin 的
   官方 commit**（sdkjs 72b0421 / web-apps 9c0ca538，非 tag——保证定制提交前的树
   与现状逐字节同源）
2. 现行 patches/sdkjs-desktop、webapps-desktop + 对应 submodule 工作区改动 →
   固化为 fork 提交（一 patch 至少一提交，按 §3.3 纪律补标记）
3. 主仓 .gitmodules url 切 fork，submodule pin fork tag `ohos-v9.4.0.1`
4. grunt-build.sh 去掉已吸收的两个 patch_*.sh 调用；patches/ 对应目录删除
5. **验收**〔v2 产物对比方法已按构建实证细化〕：迁移前先留基线（deploy/ 不进
   git，须显式拷出）→ rm deploy 产物 → grunt-build.sh 全链重建 → 对比。构建
   确定性实证：sdkjs build.py 纯拼接无压缩无 sourcemap，唯一非确定源 = bundle
   头部 7 行 license 块的年份（`datetime.now().year`）与 env 注入
   （PRODUCT_VERSION/BUILD_NUMBER/APP_COPYRIGHT/PUBLISHER_URL/COMPANY_NAME——
   本链从未设置、恒默认值）。操作：统一 unset 上述 env + 同年内构建 →
   `diff -r` 全树应为空；跨年则对 8 份 bundle 跳过头 7 行再 diff。web-apps
   grunt 同型（仅年份嵌入）。验收外加真机回归 33/33。
6. 回退：submodule 指回官方 pin commit + 恢复 patch 调用（patches 目录在阶段 3
   完成前保留 git 历史）

### 阶段 1：低垂果实——修复类与 UI 显隐类源码化（高置信低风险）

- 44_modalguard、29_inputfocus、51_scrollpad → sdkjs fork（三个独立提交；
  均为 §2.4 耦合图中的自包含段，可独立迁删）
- ColorPaletteExt 类零依赖声明成批修复（88 个）→ web-apps fork
- 菜单/装饰显隐 → web-apps fork；「用模板创建」恢复官方 opentemplate 门控 +
  宿主 GetLocalFeatures 配置（§4.2，零逻辑改动）
- 55_lic、46_fontimg、品牌化（about.less 单点 + PRODUCT_VERSION env 版本链）→
  web-apps fork
- **验收**：每迁移一段跑一次 deploy_ohos.sh + 针对性真机验证（滚动条手指拖拽、
  软键盘、模态弹窗、About 版本行、字体下拉）；阶段收尾回归 33/33
- 回退：逐段独立 revert fork 提交即可（自包含段无入站依赖）

### 阶段 2：供给类源码化（引擎资源管线）

- OHOS 字体模块（09_fonts 装填 + 三表注入 + 用户字体 + LoadFontBase64 按需化）
- 图片/媒体供给（47_img、48_mediaunpack 进引擎资源加载分支）
- 打印引擎侧（45_print 引擎段）
- **验收**：中文渲染/宋体仿宋楷体/符号映射回归（font-* case）、插入图片/媒体
  管线、三格式打印；回归 33/33
- 风险：字体链历史坑最密集（渲染槽 name 契约、selection_bin、装填时序）——
  保持「引擎答案判据」（onLogPickFont/像素级对比）不变，只换供给路径

### 阶段 3：语义类源码化（打开/保存链，工作量最大，最后做）

〔v2〕**范围修正——Local 段只剩一个文件**：官方 Local 段两文件中
`Local/license.js` 已在用（license 语义提供者，§2.4），被裁的只有
`Local/common.js`（796 行纯桌面宿主原型覆写：onEndLoadFile 本地打开链/
本地限制/外部转换/桌面文件对话框，强依赖 AscDesktopEditor 方法集）。本阶段
= 把这一个文件适配到我们的 AscDesktopEditor 桥上：
- 对照 desktop-apps 调用契约修 common/Local/common.js 为 OHOS 可用，替代
  30_open 3.4 外部模拟 _onAppReady（含 loadConfig/asc_CDocInfo/权限三刀/
  getEmpty 路线）；10_engine 踢闸、20_bridge 2.33/3.5 随迁（10_engine 与
  30_open 是功能硬耦合，必须同批——见 §2.4 耦合图）
- 保存语义：asc_Save/isOffline/DownloadAs/requestClose/-25 → apiBase OHOS
  分支；与 3.7 删 AscDesktopEditor/preview 状态机同批处理
- configs：优先走「修好后裁剪消失」路径（§3.3.5 a），兜底 b/c
- **验收**：三格式新建/打开/保存/另存为/加密文档全链（含 m7 双源验收）+
  回归 33/33 + 与迁移前保存产物逐部件对比
- 本阶段建议再拆小步（DI 链内部按 word→cell→slide 分三步），每步独立回归

### 阶段 4：ascshim 收缩定形（终态清理）

- PARTS 收缩为：CEF 桥装配（20_bridge 核心）+ 00_boot 工具 + 00_theme 粘合段
  + 49_doclang + 放映通道 + debug/验收段
- build_editors_ohos.py 删除已迁走的后处理段；src/README.md 重写段表
- 更新 docs/ONLYOFFICE_ASC_SHIM_DESIGN.md 与新架构文档互引
- **验收**：回归 33/33 + 毁灭性重建演练（终态一键复现证明）

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| fork 与官方 merge 冲突失控 | §3.3 纪律（标记+单点插入+ohos/ 目录+addon 机制）；升级间隔拉长时每次 merge 前先跑产物对比基线 |
| 双轨期同逻辑双写（fork 改了 ascshim 忘删） | 每段迁移 = 同一提交内「fork 加 + PARTS 删」；deploy_ohos.sh 加断言：ascshim 不得包含已迁移段的哨兵串 |
| 产物装配差异引入隐性回归 | 阶段 0 建立产物字节基线（方法见 §5 阶段 0）；每阶段收尾回归 33 case 不缩水 |
| sdkjs 构建对 fork 新文件不感知 | 〔v2〕官方 build.py `--addon` 机制已实证可零冲突追加清单（§3.3.5）；min 列表内顺序语义在阶段 2 首个 ohos 模块接入时核实 |
| 字体链迁移破坏渲染时序 | 阶段 2 保守策略：先并后删（新路径上线跑一版真机，再删旧装填段） |
| ascshim 段间隐性耦合导致删段崩溃 | §2.4 耦合图为迁移前置读物：连体段（20_bridge+50_init/00_boot IIFE 骨架）同批迁；硬耦合对（10_engine+30_open、40_save 保存+放映状态机）同批迁；迁移期新段顶层 var 命名加段前缀防提升互踩 |
| ~~pack_web.py 历史 patch（docscoapi license）可能存在未记录定制~~ | 〔v2〕已核实无缺口（Local/license.js + 30_open 两级提供，§2.4），风险消除 |

## 7. 待拍板决策点

1. **fork 仓库数量**：本方案推荐 sdkjs + web-apps 两个 fork（§3.1）。若坚持
   「一个 submodule」，可退化为只 fork sdkjs（web-apps 改动小，保留 patch），
   但 UI 类迁移（阶段 1 一半内容）将失去归宿，不建议。
2. **fork 托管位置**：默认 `github.com/hackeris/{sdkjs,web-apps}`（与主仓同账号，
   上架合规材料里需列入 NOTICE 组件表——AGPL 无障碍）。
3. **desktop-apps 是否 fork**：默认不 fork（欢迎页定制留 L3 后处理）。若希望
   欢迎页定制也源码化，阶段 1 可加 fork desktop-apps（成本：+1 仓升级面）。
4. **debug/验收段归宿**：默认留主仓 ascshim（回归框架载体）。若希望产品产物
   完全不含验收代码，可改为 smoke 外置注入（EditorPage 已有外置注入通道），
   属回归框架改造，与本方案解耦。

## 8. 工作量预估（粗）

| 阶段 | 规模 | 说明 |
|---|---|---|
| 0 | 0.5~1 天 | 结构迁移 + 等价验收；无代码改动 |
| 1 | 2~3 天 | 修复类有明确根因注释可依；UI 类 less 源已定位（about.less 单点） |
| 2 | 3~5 天 | 字体链最险，保守「先并后删」 |
| 3 | 4~7 天 | 〔v2〕Local 段范围收缩为仅 Local/common.js + 保存语义分支；DI 链仍是最深定制，按格式拆步 |
| 4 | 0.5~1 天 | 清理定形 |

## 9. 交叉验证记录（v2 修订依据）

关键假设逐项实证，方法 = 直接读官方源码/构建脚本，不凭记忆：

| # | 假设/原表述 | 验证结果 | 对方案的修正 |
|---|---|---|---|
| 1 | 阶段 3 可走「修好官方 Local 段」路线 | ✅ Local/common.js = 796 行纯桌面宿主原型覆写，强依赖 AscDesktopEditor 方法集；且 Local/license.js 已在用、被裁的只有 common.js 一个文件 | §5 阶段 3 范围收缩、置信度上调 |
| 2 | configs 定制需改官方文件 | ⚠️ 半误：官方 build.py 内建 `--addon`（list 追加式合并）——新增文件零冲突；裁剪不可表达 | §3.3.5 改为增/减两条路 |
| 3 | fork 基底取官方 v9.4.0 tag | ❌ 误：当前 submodule pin 的是 master 上的 release merge 点（非 tag），取 tag 则与现状有源码级差异 | §3.2/阶段 0 修正为 pin commit |
| 4 | 官方发布模型支持 merge 升级流 | ✅ release/v9.4.0 活分支 + v9.4.0.N 系列 tag（N>105） | §3.2 维持 |
| 5 | 构建产物可字节对比 | ✅（有条件）纯拼接、无压缩、无时间戳到日；唯一变量 = 头部年份 + 5 个未设置的 env | 阶段 0 验收方法细化（跳头 7 行/env unset） |
| 6 | app.css 品牌化无源不可迁 | ❌ 误：app.css 是产物，唯一源 = common about.less（五编辑器共享单点） | §4.3 品牌化迁 fork 成立 |
| 7 | 「同类 84 个零依赖文件」 | ⚠️ 实测 88 个（旧口径扣 pdfeditor）；ColorPaletteExt 修复后已带依赖不属该集合 | §4.2 数字修正 |
| 8 | UI 显隐类只能运行时隐藏 | ✅ 大体成立（头像/save-as/export-pdf 均无官方单项开关）；但「用模板创建」有被官方注释掉的 opentemplate 门控可恢复 | §4.2 新增零逻辑改动路径 |
| 9 | 57_about 补 app:version 归 web-apps fork | ❌ 误：app:version 消费方在 desktop-apps loginpage（panelabout.js）；编辑器页 About 版本 = {{PRODUCT_VERSION}} 构建期占位 | §4.2 改留主仓 + 版本走 env 链 |
| 10 | docscoapi license patch 可能未随迁成「消失的定制」 | ✅ 疑云解除：Local/license.js（引擎侧）+ 30_open（页面侧）两级显式提供 | §2.4 改已核实，阶段 0 减一项 |
| 11 | ascshim 段可随意逐段迁删 | ⚠️ 不全对：20_bridge+50_init 语法连体、10_engine+30_open 功能硬耦合、__lsoB64 五段共用、var 提升互踩风险、自包含段 12 个 | §2.4 新增耦合图；§6 新增对策 |
| 12 | core 不 fork 因仓库数 GB | ⚠️ 实测 .git 175M，存储非障碍 | §3.1 理由改为纯收益考量 |
