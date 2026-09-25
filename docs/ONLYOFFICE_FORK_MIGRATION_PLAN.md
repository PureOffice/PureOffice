# ONLYOFFICE Fork 化迁移方案（替代 patches + ascshim 注入层）

> **〔2026-09-23 已完结：阶段 0~4 全部做完〕本文档自此转为「现行子模块改动规范」**。
> 改子模块只有两条路，**判据 = `.gitmodules` 里的 url**：
> - 指向 `PureOffice/*` 的（`sdkjs` / `web-apps` / `desktop-apps`）→ **fork 直提交**：
>   子模块里改 + commit → `git -C third_party/<仓> push origin ohos` → 主仓
>   `git add third_party/<仓>` 更新指针，与主仓改动一起提交。**不 push 则主仓指针
>   不可复现**（别人 clone 后 `submodule update` 失败）。
> - 指向 `ONLYOFFICE/*` 的（`core`，官方仓推不进去）→ `patches/core-ohos/*.patch`
>   + `patch_core_ohos.sh` 幂等应用，工作区 modified 是预期态。
>
> 提交纪律见本文 **§3.3**。下面的 v3/v2 状态行是当时的方案版本记录，保留备查。

> 状态：v3（2026-09-21）——用户拍板：**ascshim 整体退役，全部定制以源码形态进
> fork，逐个 trick 重设计为正路实现**（v2 的「桥装配+粘合段留主仓」分类作废）｜
> v2（2026-09-20）交叉验证修订 ｜ 前置：现行方案全景盘点（本文 §2）
> 验证方式：关键假设逐项实证（源码/构建脚本核实），修订处以〔v2〕/〔v3〕标注

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

〔v3〕**终态拔高（用户拍板，2026-09-21）**：v2 方案保留了一个保守分类——桥装配
（20_bridge CEF 方法表/AscDesktopEditor/官方 shim）、主题粘合、doclang、放映通道
等段「留主仓 ascshim」。用户明确：**这些也要代码定制化，ascshim 最终退役**。
理由与可行性：
- ascshim 的存在本身依赖一个已消失的前提——「官方树不可改，只能注入」。fork 化
  后该前提不成立，注入层的每一段都应有源码形态；
- 注入层手段全部是 trick（轮询等待/原型 hook/运行时删对象/拦截/外部模拟），每个
  trick 都是潜在故障点（§4.0 映射表逐项列出正路）；
- 桥装配进 bundle 可行（已实证）：sdkjs bundle 为纯拼接（无模块包装），执行顺序
  = 清单顺序；`AscDesktopEditor` 的全部消费点（loadSdk 判定 editorscommon.js:11586、
  isDesktopApp 分支、Local 段）都发生在 bundle 全量执行**之后**的 Init 时机——
  ohos 桥模块放清单头部即可保证先于一切消费；唯一硬顺序约束是字体注册表须早于
  `checkAllFonts`（Externals.js），同样以清单位置解决；
- AscNative（ArkWeb registerJavaScriptProxy）的注入时序**不可依赖**（50_init
  的轮询防御恰是历史证据：ASC_WAITING 日志区分「ascshim 未加载」与「AscNative
  未注入」两种失败）。正路不是赌时序，而是**方法表对 AscNative 惰性求值**
  （每个方法体调用时才取 `window.AscNative`，装配期不依赖其存在）——装配与
  注入时序彻底解耦，轮询防御随之消除；首次真实调用（Init/用户交互）远晚于
  proxy 注入完成。

## 2. 现状定制面全景（盘点结论，2026-09-20）

### 2.1 四层结构

```
> **〔2026-09-20 盘点快照——迁移前状态，勿当现状读〕** 现状：L1 只剩 `core-ohos/`
> 的 3 个 patch（sdkjs/web-apps 已改走 fork）；L2 的 ascshim 已整体删除，20 段定制
> 全部进三个 fork 或主仓 `ohos/` 模块。见文档头部「现行子模块改动规范」。

L1 submodule 补丁层   5 个 .patch（core×3 + sdkjs×1 + webapps×1），官方树工作区应用
L2 ascshim 注入层     20 段拼接（〔v3〕修正：58_pastebtn 为方案定稿后新增）
                      + 5 占位符（make_ascshim.py PARTS）
L3 构建后处理层       build_editors_ohos.py 20 项操作（注入/重写/品牌化/裁剪/生成）
L4 宿主桥层           AscNative._call（201 CEF 方法收敛）+ execCommand 子命令
                      （〔v3〕13 个：58_pastebtn 定稿后新增 clip:paste）
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

### 2.3 L2 ascshim 20 段职责速览

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
| 58_pastebtn | 92 | 工具栏「粘贴」宿主桥（轮询覆写 Button_Paste → clip:paste 命令；方案定稿后新增） |

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
| **sdkjs** | fork → `github.com/PureOffice/sdkjs`（ohos 分支） | 引擎侧定制大头：configs 裁剪、getEmpty/bSerFormat、打开/保存语义、字体/图片/媒体供给、滚动条触摸、焦点守卫全在引擎行为层 |
| **web-apps** | fork → `github.com/PureOffice/web-apps`（ohos 分支） | UI 层定制：ColorPaletteExt 类修复、菜单显隐、头部装饰、About/许可弹层、字体名字图、字体管理入口 |
| core | **不 fork**，保留 patch 工作流 | 3 个 patch 全是构建兼容类（openssl/harfbuzz/exec-bit），与运行时行为无关、升级漂移风险极低；fork 反而引入一条「无功能收益的升级面」（〔v2〕实测 .git 175M，存储不是障碍，纯收益考量） |
| desktop-apps | 〔v3〕**fork** → `github.com/PureOffice/desktop-apps`（ohos 分支，§7.1 拍板） | 欢迎页定制源码化：viewport/导航精简/PDF 卡/recents 面板/About 版本（替代 L3 后处理与欢迎页注入段） |
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

### 3.4 职责边界（〔v3〕终态：ascshim 退役）

```
┌─ 主仓（PureOffice）────────────────────────────┐
│ ArkTS 宿主（EditorPage/ascBridge/DocTabHost）    │ ← 不变
│ AscNative 桥 + execCommand 命令总线              │ ← 冻结契约（与 fork 桥模块配对）
│ 构建工程：字体工程（表/精灵/XOR）、模板、装配、   │
│   版本、裁剪、回归框架                           │
│ 平台模块：scripts/onlyoffice/ohos/{boot,bridge,  │
│   fonts}.js（env/bridge/fonts/userfonts/images/  │
│   media/print/paste/save/open/scroller/focus/    │
│   doclang/theme/fullscreen 各域）——源在主仓，     │
│   构建期注入 index.html 头部（〔实际实施〕见 §3.5）│
│ 【退役】ascshim.js 与 make_ascshim.py（回归 smoke │
│   走 EditorPage 外置注入通道，属测试设施非产品）  │
├─ third_party/sdkjs → fork ─────────────────────┤
│ 官方文件内的 [OHOS:] 行为分支（引擎侧定制：       │
│   nofocus、touch-scroll、configs、DocLang 等）   │
├─ third_party/web-apps → fork ───────────────────┤
│ UI 定制：显隐/装饰/About/弹层/字体下拉/           │
│ ColorPaletteExt 类批修/modalguard 语义守卫        │
├─ third_party/desktop-apps → fork ───────────────┤
│ loginpage：viewport/导航精简/PDF 卡/About 版本/  │
│ recents 面板（源码化，替代 L3 后处理+欢迎页注入段）│
├─ third_party/core → 官方 + patch（不变）─────────┤
└──────────────────────────────────────────────┘
```

〔v3〕**判据更新**：产品功能定制 → 一律 fork 源码（含桥装配）；测量/验收 → 回归
smoke 外置注入（非产品）；ArkTS 宿主行为 → 主仓。v2 的「与 ArkTS 宿主配对 → 留
主仓 ascshim」判据作废——「配对」的正确形态是 fork 桥模块 ↔ ascBridge.ets 的显式
契约（方法表/命令集双端对照），不是注入层页面脚本。

### 3.5 〔v3〕OHOS 平台模块设计

> **〔实际实施，2026-09-23 已完成，与本节方案有偏差——以此为准〕**
> 平台模块**没有**放进 `third_party/sdkjs/common/ohos/`（该目录不存在），而是放在
> **主仓** `scripts/onlyoffice/ohos/{boot,bridge,fonts}.js`，由 `build_editors_ohos.py`
> 在构建期注入各 app 的 `index.html` 头部（与官方脚本同处 `<head>`，时机等价）。
> sdkjs fork 侧只保留**官方文件内的 `[OHOS:]` 行为分支**（nofocus / touch-scroll /
> configs / DocLang 等）。
> **并且实际只落了 3 个模块**（`boot` / `bridge` / `fonts`）——下表清单里的 userfonts /
> images / media / print / paste / scroller / focus / doclang 各域**未按此拆分**，那些
> 能力现散在 `boot.js` / `bridge.js` 内或 fork 中（2026-09-25 核实）。下面的「挂载
> 机制」是当时的方案设计，「顺序约束」的思路仍适用，**但模块划分不要按表对照**。

**挂载机制**：`common/ohos/` 各文件进 build.py 清单（fork 直接改 configs，先例=
sdkjs-desktop patch 的 configs 定制；或 --addon 追加，§3.3.5）。bundle 纯拼接、
无模块包装，执行顺序 = 清单顺序 → **ohos 模块置于清单头部**，先于一切官方文件。

**模块清单与顺序约束**：

| 顺序 | 模块 | 职责（替代的 ascshim 段） | 硬时序约束 |
|---|---|---|---|
| 1 | `ohos/env.js` | `AscOHOS` 命名空间 + 平台判定（`!!window.AscNative`，一次求值缓存） | 无（最先） |
| 2 | `ohos/bridge.js` | AscDesktopEditor/desktop 对象装配 + 201 方法表 + LoadFontBase64 回填语义 + 官方 InitJSContext shim 合并（ascdesktop_shim_raw.js 内容转正） | 先于 bundle 内任何 AscDesktopEditor 顶层消费（实测消费点均在函数体内、Init 时机触发；env/bridge 头部放置即满足） |
| 3 | `ohos/fonts.js` | 字体注册表（三表）读取 + g_fonts_streams 预取装填 + LoadFontBase64 按需 | **必须早于 Externals.js 的 checkAllFonts**（清单位序保证）；注册表数据 = 主仓构建产的 manifest（数据文件，非注入行为，见下） |
| 4 | `ohos/userfonts.js` | 用户字体：URL 参数解析 + 注册表追加 + g_fontSelections.List 补条目（改在 CFontSelectList.Init 完成回调内，替代外部轮询等 IsInit） | 晚于 fonts、早于首次字体解析 |
| 5+ | images/media/print/paste/save/doclang/theme/fullscreen/scroller/focus | 各功能域（§4.0 逐项） | 各域内部约束 |

**字体注册表的数据形态**：三表（FONT_FILES_ALL/FONT_INFOS/FONT_RANGES）由主仓
字体工程生成（依赖随包+系统字体清单，fork 不可承载）。沿用官方「构建期静态数据
文件」模型（同 AllFonts.js/g_fonts_selection_bin）：主仓构建链在 sdkjs deploy 产物
旁生成 `ohos_fonts_manifest.js`（纯数据赋值），ohos/fonts.js 以官方 loadScript 同型
方式加载消费。数据文件属产物非定制，不违反「零注入」。

**方法表契约迁移**：asc_methods.txt（201 方法）→ fork `ohos/bridge.js` 内方法表
（数据区），ascBridge.ets 对照端不变；FIRE_MAP/RAW_METHODS 特例语义随迁。
getFontBySymbol 等「引擎内部消费全局」的约定（__fonts_files 等 window 全局）在
fork 内可改为显式传参/命名空间，但**阶段 2 首版保持全局名不变**（语义等价优先，
收敛命名放阶段 4）。

**web-apps fork 结构**：`apps/common/main/lib/ohos/`（新文件）+ 官方组件文件内
[OHOS] 标记插入（显隐/About/lic 弹层/字体下拉名字图）。
**desktop-apps fork 结构**：loginpage 源内直改（viewport/精简/PDF 卡/About），
recents 面板刷新桥转正（loginpage sdk.js 源码配合 ArkTS Recents 命令）。

## 4. 定制点迁移分类表（逐段去向）

### 4.0 〔v3〕trick → 正路重设计映射（本次规划核心）

ascshim 的每类 trick 都源于同一历史约束——「官方树不可改」。fork 化后逐一
重设计为源码正路。**语义等价是硬约束**：每项迁移的验收 = 现有功能判据 +
回归 33/33 不缩水。

| # | trick（现状） | 用在哪 | 当时为何只能 trick | fork 正路实现 | 阶段 |
|---|---|---|---|---|---|
| 1 | **轮询等对象出现**（50ms~300ms × 300~600 次重试，`__lsoWaitN` 共享预算互耗） | 50_init 等 AscNative、3.5 等 isLoadFullApi、2.6 等 sdk、用户字体等 IsInit、58 等 Button_Paste | 注入脚本没有生命周期挂点，只能从页面侧等 | 方法表惰性求值解耦 AscNative 时序（§9 #14，装配期零等待）；isLoadFullApi 等待被 Local 段打开链取代（#5）；用户字体挂 CFontSelectList.Init 完成点；粘贴挂 api.Paste 官方入口 | 2/3 |
| 2 | **原型链 hook / 运行时 wrap**（Gateway wrap 踢闸、hookProtoOpen（含 PDF 误勾前科）、getUrl/updateVisibleFontsTiles/asc_Print/asc_Save/sdk.LocalFile* wrap） | 10_engine、30_open、47_img、46_fontimg、45_print、40_save、2.6 | 官方函数不可改，只能包一层 | 改官方函数源码加 `[OHOS]` 分支（行为分支优先于改写，§3.3.4） | 1/2/3 |
| 3 | **运行时删对象/缓存恢复状态机**（3.7 删 window.AscDesktopEditor 逼官方走 web 语义；放映期 `__lsoAscDE` 临时恢复） | 40_save | 无法改 isDesktopApp 判定本身 | 引擎侧显式平台判定：isDesktopApp 消费点加 OHOS 条件（语义=「桌面但离线壳」），不再靠对象存在性间接表达；放映走官方 SetFullscreen 通道 | 3 |
| 4 | **拦截层**（XHR/fetch 取证、rawfileLoader loadRaw、target=_blank 拦截、-25 错误拦截、postMessage 桥） | 10_engine、47/48、55_lic、40_save、2.33 | 资源与导航无法进引擎分支 | 资源加载官方函数 OHOS 分支；lic 弹层=About.js 源内 dialog；错误处理=保存链分支；2.33 休眠桥随 Local 段正路化废弃 | 2/3 |
| 5 | **外部模拟桌面语义**（DI 链模拟 _onAppReady：loadConfig/CDocInfo/权限三刀；10_engine 踢 serverId/images 闸） | 30_open、10_engine | 官方 Local/common.js 在 web 宿主崩，只能裁掉后外部模拟 | Local/common.js OHOS 化（对照 desktop-sdk 调用契约适配），打开链走官方正路；闸门随 Local 段就位自然通过 | 3 |
| 6 | **window 全局三表 + URL 参数契约**（__fonts_files/infos/ranges、lsofonts base64） | 20_bridge 段0、0.2 | 字体清单依赖主仓字体工程产物，引擎侧无数据通道 | manifest **数据文件**（官方 AllFonts.js 同型构建期静态数据）+ CFontSelectList 源扩展吃用户字体条目 | 2 |
| 7 | **capture 层坐标接管 + 外扩 8px + 双流同拦防回弹** | 51_scrollpad | 官方滚动条窄条判定零容差，注入层无法改判定 | scroll.js `_MouseHoverOnScroller` 判定加触摸容差（外扩进引擎，capture 层删除） | 1 |
| 8 | **吞事件 + 补聚焦**（原型 hook document focus 监听器，吞后必须补聚焦否则点文档区也不弹） | 29_inputfocus | 非 PC 形态两条夺焦路径无守卫 | 官方监听器源码加守卫 + `closest('#editor_sdk')` 判据 + nofocus=1 URL 语义保留 | 1 |
| 9 | **无保护 handler 兜底**（七事件 try/catch 外挂） | 44_modalguard | Desktop.js native 事件 handler 无保护，异常中断 Backbone 同步 trigger | Desktop.js 源码内加 if 保护（官方行为不变，仅防 TypeError） | 1 |
| 10 | **localStorage 抢跑预写**（ui-theme-id/sse-spellcheck-locale 页面加载前写） | 00_theme 0.9、49_doclang | 官方读值早于注入可控时机，只能预写 | 主题默认=grunt 构建配置/官方 themeinit 语义源内化；doclang=编辑器语言官方偏好通道默认值 | 1/2 |
| 11 | **方法重定向**（asc_DownloadAs→asc_Save、X 关闭重定向守卫） | 40_save | 官方保存语义与离线壳不匹配 | apiBase/api.js OHOS 分支显式实现离线保存语义 | 3 |
| 12 | **桥方法特化回填**（LoadFontBase64 返回值须自写 window[id]，模仿 C++ 行为） | 20_bridge 2.1 | 通用方法表只会 _call+解 JSON，C++ 语义无法表达 | Externals.js LoadFontAsync OHOS 分支源内回填（官方桌面分支同型） | 2 |
| 13 | **工具栏按钮运行时覆写**（轮询 300 次等 Button_Paste 后覆写） | 58_pastebtn | g_clipboardBase 无法改 | clipboard_base.js Button_Paste 源码加 AscNative 分支（三编辑器收敛单点；ArkTS pasteClipboard 侧不变） | 2 |

**消除的故障面**：轮询竞态（#1）、hook 误勾（#2，PDFEditorApi 前科）、对象
删恢复窗口（#3）、拦截层顺序（#4）、AMD 加载顺序抖动（88 个 define([]) 文件
批修，§4.2）——这些正是 19937b4/软键盘/滚动条等历次事故的根因类别。

### 4.1 L1 补丁 → 阶段 0 全量固化

全部 5 个 patch 中：sdkjs×1、webapps×1 固化为 fork 提交（迁移后删除
patches/sdkjs-desktop、patches/webapps-desktop 与对应 patch_*.sh 的相关段）；
core×3 保留现行工作流。

### 4.2 L2 ascshim 20 段去向（〔v3〕全量进 fork/smoke，零留主仓产品段）

| 段/小节 | 去向 | 迁移形态 |
|---|---|---|
| 20_bridge 1/2/3（CEF 201 方法 + AscDesktopEditor 装配 + 官方 shim） | **sdkjs fork `ohos/bridge.js`**（阶段 2，基础设施最先） | 方法表转正为 fork 源码数据区（FIRE_MAP/RAW_METHODS 特例随迁，asc_methods.txt 退役）；官方 InitJSContext shim（ascdesktop_shim_raw.js 162 行）内容合并入 bridge；LoadFontBase64 特化→trick #12 正路；install 时机=清单头部同步执行（轮询消除，trick #1） |
| 20_bridge 0 字体三表 + 09_fonts 装填 | **sdkjs fork `ohos/fonts.js`**（阶段 2） | 三表 = 主仓产 manifest 数据文件（官方 AllFonts.js 同型）；流保供/预取进引擎；trick #6 |
| 20_bridge 0.2 用户字体 + 尾部 g_fontSelections 字典补丁 | **sdkjs fork `ohos/userfonts.js`**（阶段 2） | URL 参数解析 + 注册表追加 + List 补条目挂 Init 完成点（外部轮询消除，trick #1/6） |
| 20_bridge 2.33 打开注入桥（休眠） | **废弃**（阶段 3） | Local 段正路化后该协议桥无存在必要（注释里的安全告警随之了结） |
| 20_bridge 2.5/2.6 loginpage recents 桥 | **desktop-apps fork**（阶段 1） | loginpage sdk.js 源码配合：面板订阅/刷新链源内实现（欢迎页域，desktop-apps 已拍板 fork）；wrap LocalFileRemoveRecent 消除（trick #2） |
| 20_bridge 3.5 就绪探针（等 isLoadFullApi→LocalStartOpen） | **sdkjs fork**（阶段 3） | Local 段打开链接管时机；探针轮询消除（trick #1/#5） |
| 44_modalguard | **web-apps fork** | Desktop.js 七 handler 源码加守卫（trick #9） |
| 29_inputfocus | **sdkjs fork `ohos/focus.js`** | 官方监听器源码守卫 + nofocus=1 语义保留（trick #8） |
| 51_scrollpad | **sdkjs fork `ohos/scroller.js`**（改 scroll.js 判定） | 触摸容差进引擎，capture 层删除（trick #7） |
| ColorPaletteExt（已 patch） | web-apps fork | 已固化提交；同类 `define([])` 零依赖声明文件实测 **88 个**，fork 成批修复（AMD 顺序故障面根除） |
| 00_theme 0.11 / 40_save 3.9（菜单与装饰显隐） | **web-apps fork** | 官方语义已逐项核实〔v2〕：头像/X/save-as/export-pdf 无单项开关→源码改；「用模板创建」恢复官方 opentemplate 门控 + 宿主 GetLocalFeatures 配置（零逻辑改动） |
| 00_theme 0.9 主题默认 | **web-apps fork**（阶段 1） | 官方主题默认值源内化（grunt 配置/themeinit），localStorage 抢跑预写消除（trick #10） |
| 00_theme 0.10 主题色上报 | **sdkjs fork `ohos/theme.js`**（阶段 2） | tab 主题色上报走 bridge 方法（宿主配对不变，代码域迁引擎侧） |
| 55_lic | **web-apps fork** | 「许可信息」链接与弹层进 About.js 源码（ArkWeb 无多窗口收敛为源内 dialog；target=_blank 拦截消除，trick #4） |
| 46_fontimg | **web-apps fork** | 字体下拉源码支持用户字体名字图（updateVisibleFontsTiles wrap 消除，trick #2） |
| 57_about | **desktop-apps fork**（阶段 1） | app:version 消费方在 loginpage panelabout.js:149/297（欢迎页域）；编辑器页 About 版本 = grunt `PRODUCT_VERSION` env 版本链 |
| 40_save 3.10/3.11 欢迎页精简/字体入口 | **desktop-apps fork**（阶段 1） | loginpage 源码直改（替代 L3 后处理文本替换） |
| 40_save 3.8.x 保存语义 | **sdkjs fork `ohos/save.js`**（阶段 3） | apiBase/api.js OHOS 分支（trick #11） |
| 40_save 3.7 删 AscDesktopEditor + 3.7.1 放映状态机 | **sdkjs fork**（阶段 3） | 平台判定显式化（trick #3）+ `ohos/fullscreen.js` 走官方 SetFullscreen 通道；ArkTS 窗口状态机配对不变 |
| 30_open 3.4 DI 打开链 + 10_engine 踢闸 | **sdkjs fork**（阶段 3，工作量最大） | Local/common.js OHOS 化替代外部模拟（trick #5）；两段功能硬耦合必须同批（§2.4） |
| 47_img / 48_mediaunpack | **sdkjs fork `ohos/images.js`/`ohos/media.js`**（阶段 2） | 资源加载 OHOS 分支（_offline_ 前缀源头剥除、media 命中；getUrl wrap/拦截消除，trick #2/#4） |
| 45_print 引擎侧 | **sdkjs fork `ohos/print.js`**（阶段 2） | 打印 API OHOS 分支（asc_Print wrap 消除）；宿主 @ohos.print 不动 |
| 58_pastebtn | **sdkjs fork**（阶段 2） | Button_Paste 源码 AscNative 分支（轮询覆写消除，trick #13）；ArkTS pasteClipboard 配对不变 |
| 49_doclang | **sdkjs fork `ohos/doclang.js`**（阶段 2） | xlsx 编辑器语言官方偏好通道默认值（trick #10） |
| 00_boot 自动保存默认关 | **sdkjs fork configs**（阶段 1） | 官方 customization 语义源内配置 |
| 00_boot 工具（__lsoB64 等） | **随用随迁**（阶段 2） | 各 ohos 模块自带工具函数（五段共用一处全局的耦合消除） |
| 09_fontpick、10_engine 0.94 字节打点、30_open 3.55 m7、00_boot 插件取证/自检 | **回归 smoke 外置注入**（阶段 4） | EditorPage 已有外置注入通道；产品产物零验收代码（URL 门控纪律不变） |
| 50_init | **解散**（阶段 2） | AscNative 轮询/INSTALL 尾声随 bridge 转正消失（trick #1）；IIFE 骨架随拼接退役 |

### 4.3 L3 构建后处理去向

| 操作 | 去向 |
|---|---|
| 品牌化文本替换（LeftMenu/About/app.css） | **web-apps fork**〔v2 已核实源〕app.css 是构建产物（源树无 css/ 目录），`.asc-about-office` 规则唯一源 = `apps/common/main/resources/less/about.less:2-10`（五编辑器共享 import）——fork 直接改 less 单点 + LeftMenu/About.js 文本；web-apps grunt 版本号 = `PRODUCT_VERSION` env → `{{PRODUCT_VERSION}}` 占位（Gruntfile.js:814），构建链接上即可让编辑器页 About 显示产品版本 |
| AllFonts.js 重写 + 字体三表 | 留主仓字体工程（数据生产）；fork 引擎侧只改「读入方式」（阶段 2） |
| ascshim 注入/viewport 注入 | 迁移期留主仓（注入的是主仓产物）；viewport 注入随阶段 1 loginpage 源码化删除；ascshim 注入随阶段 4 退役删除 |
| 裁剪/版本/插件/smoke/licenses/templates | 留主仓（与 fork 无关） |

## 5. 分阶段实施计划

每阶段独立可验收、可停在某阶段长期不动（阶段间无耦合债务）。
**双轨纪律：任一定制点只活在一处——迁入 fork 的段当轮从 ascshim PARTS 删除。**

### 阶段 0：建 fork 与提交固化（无行为变化，纯结构迁移）

1. `github.com/PureOffice/` 建 sdkjs、web-apps、desktop-apps 三仓〔**执行修正：
   2026-09-23 最终托管于 PureOffice 组织**（下述 hackeris 系当时拟址）；v3：desktop-apps
   并入，§7.1〕，**基底 = 当前 submodule pin 的官方 commit**（sdkjs 72b0421 /
   web-apps 9c0ca538 / desktop-apps 8f452c7f，非 tag——保证定制提交前的树与
   现状逐字节同源；desktop-apps 工作区零改动，ohos 分支基底即头）
2. 现行 patches/sdkjs-desktop、webapps-desktop + 对应 submodule 工作区改动 →
   固化为 fork 提交（一 patch 一提交，提交信息吸收 patch 头注释的动机/坑/证据）。
   〔执行修正〕§3.3 的 [OHOS] 标记**不在本阶段补**——加标记=改内容=破坏字节
   等价验收；固化逐字节原样，标记纪律自阶段 1 功能提交起
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

### 阶段 1：低垂果实——修复类、UI 显隐类、欢迎页域源码化（高置信低风险）

- 44_modalguard、29_inputfocus、51_scrollpad → sdkjs fork（三个独立提交；
  均为 §2.4 耦合图中的自包含段，可独立迁删）
- ColorPaletteExt 类零依赖声明成批修复（88 个）→ web-apps fork
- 菜单/装饰显隐、55_lic 弹层、46_fontimg、品牌化（about.less 单点 +
  PRODUCT_VERSION env 版本链）、00_theme 主题默认源内化、自动保存默认关
  configs → web-apps fork
- **desktop-apps loginpage 源码化**〔v3 新增，§7.3 已拍板 fork〕：viewport/
  导航精简/PDF 卡删除/panelabout 版本（57_about 随迁）/recents 面板刷新链
  （20_bridge 2.5/2.6 随迁）；L3 对应后处理段同批删除
- **验收**：每迁移一段跑一次 deploy_ohos.sh + 针对性真机验证（滚动条手指拖拽、
  软键盘、模态弹窗、About 版本行、字体下拉、欢迎页）；阶段收尾回归 33/33
- 回退：逐段独立 revert fork 提交即可（自包含段无入站依赖）

### 阶段 2：桥装配代码化 + 供给类源码化（引擎侧主力）〔v3 重排〕

**桥装配最先**（其余各域的 OHOS 分支都经它调 AscNative）：
- `ohos/env.js` + `ohos/bridge.js` 进 sdkjs 清单头部：201 方法表/AscDesktopEditor
  装配/官方 shim 合并/LoadFontBase64 源内回填；ascshim 侧 20_bridge 段同批停用
- **桥对拍验收**（语义等价的核心证据）：fork bridge 与 ascshim 装配产物的方法表
  逐一对照（201 方法名集合 + FIRE_MAP/RAW_METHODS 特例）；真机判据 =
  ASC_FOUND/方法调用日志与迁移前同型
- 时序实测前置：bundle 内 bridge 的执行先于全部消费点（§3.5 依据），首轮真机
  若出现消费早于装配（理论不应发生），回退成本低（撤 configs 清单行）

供给类：
- OHOS 字体模块（`ohos/fonts.js` manifest 数据文件 + 流保供 + `ohos/userfonts.js`
  Init 挂点）
- 图片/媒体供给（`ohos/images.js`/`ohos/media.js` 引擎资源加载分支）
- 打印引擎侧（`ohos/print.js`）、粘贴（Button_Paste OHOS 分支，58_pastebtn 段退役）、
  doclang、主题色上报（`ohos/theme.js`）
- **验收**：中文渲染/宋体仿宋楷体/符号映射回归（font-* case，引擎答案判据不变）、
  插入图片/媒体管线、三格式打印、工具栏粘贴；回归 33/33
- 风险：字体链历史坑最密集（渲染槽 name 契约、selection_bin、装填时序）——
  保持「引擎答案判据」（onLogPickFont/像素级对比）不变，只换供给路径；保守
  「先并后删」（新路径真机过一版再删旧段）

### 阶段 3：语义类源码化——打开/保存链与平台判定显式化（工作量最大，最后做）

〔v2〕**范围修正——Local 段只剩一个文件**：官方 Local 段两文件中
`Local/license.js` 已在用（license 语义提供者，§2.4），被裁的只有
`Local/common.js`（796 行纯桌面宿主原型覆写：onEndLoadFile 本地打开链/
本地限制/外部转换/桌面文件对话框，强依赖 AscDesktopEditor 方法集）。本阶段
= 把这一个文件适配到我们的 AscDesktopEditor 桥上：
- 对照 desktop-apps 调用契约修 common/Local/common.js 为 OHOS 可用，替代
  30_open 3.4 外部模拟 _onAppReady（含 loadConfig/asc_CDocInfo/权限三刀/
  getEmpty 路线）；10_engine 踢闸、20_bridge 2.33/3.5 随迁废弃（10_engine 与
  30_open 是功能硬耦合，必须同批——见 §2.4 耦合图）
- 保存语义：asc_Save/isOffline/DownloadAs/requestClose/-25 → apiBase OHOS
  分支（trick #11）
- **平台判定显式化**（trick #3）：3.7「删 AscDesktopEditor」状态机废除，
  isDesktopApp 消费点加 OHOS 条件；放映全屏 `ohos/fullscreen.js` 走官方
  SetFullscreen 通道（ArkTS 窗口状态机配对不变）
- configs：优先走「修好后裁剪消失」路径（§3.3.5 a），兜底 b/c
- **验收**：三格式新建/打开/保存/另存为/加密文档全链（含 m7 双源验收）+
  回归 33/33 + 与迁移前保存产物逐部件对比
- 本阶段建议再拆小步（DI 链内部按 word→cell→slide 分三步），每步独立回归

### 阶段 4：ascshim 退役定形（〔v3〕终态从「收缩」改为「退役」）

- **删除**：ascshim.js 产物注入、make_ascshim.py、desktop/src/ 各段源文件
  （先归档至 docs 附录或 git 历史索引）、build_editors_ohos.py 的注入段
- **debug/验收段外置**：09_fontpick/字节打点/m7/插件取证/自检 → 回归 smoke
  注入通道（EditorPage 既有设施改造），产品产物零验收代码
- 命名收敛：过渡期保留的 window 全局契约（__fonts_* 等）在 fork 内显式化
  （命名空间/传参），ascBridge.ets 对照端同批调整
- 文档：src/README.md 段表、docs/ONLYOFFICE_ASC_SHIM_DESIGN.md 标注退役、
  本文档定稿互引
- **验收**：回归 33/33 + 毁灭性重建演练（rm 全部产物 → grunt-build.sh 全链 →
  真机回归，终态一键复现证明）；deploy 产物中 grep 不得再出现 ascshim 标识

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| fork 与官方 merge 冲突失控 | §3.3 纪律（标记+单点插入+ohos/ 目录+addon 机制）；升级间隔拉长时每次 merge 前先跑产物对比基线 |
| 双轨期同逻辑双写（fork 改了 ascshim 忘删） | 每段迁移 = 同一提交内「fork 加 + PARTS 删」；deploy_ohos.sh 加断言：ascshim 不得包含已迁移段的哨兵串 |
| 产物装配差异引入隐性回归 | 阶段 0 建立产物字节基线（方法见 §5 阶段 0）；每阶段收尾回归 33 case 不缩水 |
| sdkjs 构建对 fork 新文件不感知 | 〔v2〕官方 build.py `--addon` 机制已实证可零冲突追加清单（§3.3.5）；min 列表内顺序语义在阶段 2 首个 ohos 模块接入时核实 |
| 字体链迁移破坏渲染时序 | 阶段 2 保守策略：先并后删（新路径上线跑一版真机，再删旧装填段） |
| ascshim 段间隐性耦合导致删段崩溃 | §2.4 耦合图为迁移前置读物：连体段（20_bridge+50_init/00_boot IIFE 骨架）同批迁；硬耦合对（10_engine+30_open、40_save 保存+放映状态机）同批迁；迁移期新段顶层 var 命名加段前缀防提升互踩 |
| 〔v3〕桥装配进 bundle 后出现早消费（时序假设不成立） | 消费点已逐一核实均在函数体内、Init 时机触发（§3.5），理论无窗口；万一实测出现：bridge 移清单更前/该消费点单独加惰性兜底；撤 configs 清单行即回退 |
| 〔v3〕语义等价漂移（迁移引入行为差异） | 硬验收三件套：桥对拍（201 方法逐一）+ 各域既有功能判据 + 回归 33/33 不缩水；字体链引擎答案判据不变；保存链产物逐部件对比 |
| 〔v3〕字体 manifest 数据文件加载时序（同步语义） | 沿用官方 AllFonts.js 同型通道（构建期静态 JS、引擎加载序固定）；首版保持 window 全局名不变，命名收敛放阶段 4 |
| ~~pack_web.py 历史 patch（docscoapi license）可能存在未记录定制~~ | 〔v2〕已核实无缺口（Local/license.js + 30_open 两级提供，§2.4），风险消除 |

## 7. 决策点（〔v3〕2026-09-21 全部拍板）

1. **fork 仓库数量** → **拍板：三仓**（sdkjs + web-apps + desktop-apps）。
   用户选择超出 v2 推荐两仓：desktop-apps 亦 fork，欢迎页定制同步源码化
   （阶段 1 承接，§4.2）。
2. **fork 托管位置** → 当时拍板 `github.com/hackeris` 公开〔**执行修正
   （2026-09-23）：最终落在 `github.com/PureOffice` 组织**，与主仓同组织〕。
   AGPL 对应源码在 fork 化后含 OHOS 定制提交，NOTICE 源码地址必须指向用户
   可得处——公开是合规硬需求。
3. **desktop-apps 是否 fork** → **拍板：fork**（并入决策 1）。
4. **debug/验收段归宿** → 拍板「留主仓 ascshim」；〔v3〕goal「ascshim 全部
   更换为代码定制」覆盖该选择 → **升级为 smoke 外置注入**（阶段 4）：产品
   产物零验收代码，回归框架改造与退役同批完成。
5. **〔v3 新记录〕ascshim 终态** → **用户拍板：整体退役**。全部定制以源码
   形态进 fork，语义等价验收（§4.0），不保留注入层产品段。

## 8. 工作量预估（〔v3〕重估，较 v2 增加 desktop-apps 域 + 桥装配代码化 + 退役）

| 阶段 | 规模 | 说明 |
|---|---|---|
| 0 | 0.5~1 天 | 结构迁移 + 等价验收；无代码改动（本地固化已完成，待建仓 push） |
| 1 | 3~4 天 | 修复类有根因注释可依；UI 类 less 源已定位；+ desktop-apps loginpage 源码化 |
| 2 | 4~6 天 | 桥装配对拍 + 字体链最险（保守「先并后删」）+ 供给类五域 |
| 3 | 5~8 天 | Local/common.js OHOS 化 + 保存语义 + 平台判定显式化（trick #3）；DI 链按格式拆步 |
| 4 | 1~1.5 天 | ascshim 退役 + smoke 外置 + 文档 + 毁灭性重建演练 |

合计 13.5~20.5 天。每阶段独立可验收、可停住长期不动（阶段间无耦合债务）。

## 9. 交叉验证记录（v2/v3 修订依据）

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
| 13 | 〔v3〕AscDesktopEditor 装配可进 sdkjs bundle（不依赖注入层抢跑） | ✅ bundle 纯拼接无模块包装（=v2 #5）；消费点核查：editorscommon.js:11586 loadSdk 判定、apiBase isDesktopApp 分支、Local 段调用均在**函数体内**、Init 时机触发，bundle 内无顶层立即消费；清单头部放置即满足全部顺序约束 | §3.5 桥模块设计成立；阶段 2 保留「时序实测前置」防翻车 |
| 14 | 〔v3〕AscNative 注入时序可依赖 | ❌ 不可依赖也不必依赖：50_init 轮询防御的存在即证据；方法表惰性求值（调用时取 window.AscNative）使装配与注入时序解耦 | §1/§3.5 表述修正；轮询消除的机制=解耦而非赌时序 |
| 15 | 〔v3〕字体三表可数据文件化 | ✅ 官方同型先例：AllFonts.js/g_fonts_selection_bin 即构建期静态数据文件通道；三表本源在主仓字体工程（随包+系统字体清单），fork 只承载「读取与装填」逻辑 | §3.5 manifest 数据文件设计；window 全局名首版保持不变（语义等价） |
