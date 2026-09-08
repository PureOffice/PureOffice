# 多文档 Tab 编辑（方案 A）详细实现设计

> 2026-09-08 · 未定稿 · 交付审查
> 现状基准：HEAD 31ecae8 + 工作区未提交改动（40_save 3.9.1 模板项移除 / 1.0.42）
> 组件关系：EditorPage.ets(879) = @Entry 单页；ascBridge.ets(304) = AscNative._call 同步桥

---

## 0. 官方思路基准（为什么这样设计）

**官方桌面 = 「外壳层负责多开，web 层零感知」。** 取证：

- 官方 web-apps 层（`apps/common/main/lib/controller/Desktop.js`，本仓库 rawfile 内置，
  966 行）：只有本实例命令——`file:close`（关闭当前文档）、`go:folder`（返回列表），
  **没有任何**「打开第二个文档/多窗口/文档列表」管理逻辑。单窗口内部，web-apps
  只认「自己这一个文档」。
- 多文档并存是**外层壳的事**：官方桌面 C++ 层每文档 = 一个独立 browser 实例/窗口
  （欢迎页也是其一），各有完整生命周期；web 层对多个实例完全无感知。
- 因此「按官方思路」= **在 ArkTS 外层实现「文档实例管理器」**，web-apps/ascshim
  页面脚本（每实例独立执行一次）**零感知、零改动**（除 1 处小钩子，见 §6）。

我们的 B 架构里，外层壳 = ArkTS（EditorPage + 系统 WebView），页面层 = 官方 web-apps
+ ascshim。方案 A 就是把 ArkTS 层改造成官方外壳。

## 1. 目标形态

```
┌────────────────────────────────────────────────────────────┐
│ [主页] [未命名的文档.docx] [会议纪要.docx] [×]  [销售表.xlsx] │  ← tab 条（长于屏宽可横滑）
├────────────────────────────────────────────────────────────┤
│        激活 tab 的页面（主页欢迎页 或 文档编辑器）             │
└────────────────────────────────────────────────────────────┘
```

- **主页 tab**：现有欢迎页（loginpage），永远第一个、无 ×、不可关。
- **文档 tab**：每个打开/新建的文档一个。点 tab=切换（**引擎实例存活，切回零重建**——
  与官方桌面「每文档一窗口」同构，只是容器从窗口换成 tab）。
- 所有文档 tab + 主页 tab **并存挂载**（每个都是活 WebView 实例）——官方桌面多窗口
  同样全存活；绝不做「快照/重建」（那是方案 B）。

## 2. 顶层架构

```
EditorPage（@Entry，容器化）
├─ DocTabsModel（@State）：tab 数组 + onTab* 动作（打开/切换/关闭）
│    · 每元素 DocTabItem：{ id, kind:'home'|'doc', title,
│        docState: DocTabState（见 §3）, url, nodeCtrl: DocWebViewNode }
├─ Tabs({ barPosition: BarPosition.Start, index: focusIndex, controller })
│    .scrollable(false).barHeight(0)            ← 只做内容切换容器
│    └─ ForEach(tabArray) → TabContent
│         └─ NodeContainer(item.nodeCtrl)      ← NodeController 对接（§5/Harmonix 模式）
│              内 = 该 tab 的 Web 组件（controller 唯一绑定，节点复用=状态保持）
├─ TabBar（自绘 Row/Scroll，HomeSheets 同型 TabSheets）—— 主页 chip + 每文档 chip（名 + ×）
└─ 每 Web 组件独立装配（onControllerAttached 内新建 per-instance 桥）——见 §4
```

关键不变式：

- **每个文档 tab 持有独立 `WebviewController`**（ArkWeb 多 Web 组件天然支持；
  每实例独立页面、独立 JS 上下文、独立 onConsole/onInterceptRequest 回调）。
- **节点复用 = 状态保持**：NodeController 的 BuilderNode 缓存使切 tab 时 Web
  组件不重建、不销毁（引擎继续跑）——切回零重建的来源（§5）。
- **首页 tab 与文档 tab 并存挂载**：官方桌面「欢迎页窗口与文档窗口并存」同构。
- 超上限（§5 内存策略）拒绝新建并 toast，不静默降级。

## 3. 状态模型（把「单例字段」升级为「per-tab 状态」）

### 3.1 下沉到 DocTabState（原 EditorPage 单例字段 → 每文档一份）

| 原字段 | 迁移去向 | 说明 |
|---|---|---|
| `currentOpenName` | DocTabState.name | 打开/另存为后更新；tab 标题同源 |
| `currentOpenExt` | DocTabState.ext | 保存链 save.<ext> 用 |
| `saveTarget` | DocTabState.saveTarget | 'none'/'sandbox'/'uri'（单一事实源不变） |
| `savePath` | DocTabState.savePath | |
| `pendingOpenFile` | DocTabState.pendingOpen | LocalStartOpen 注入守卫 |
| `m7DirectQueued` | 不迁移 | M7 直达只在 home 实例触发，行为不变 |
| `currentOpenName` 之后的 tab 标题 | — | @State 派生：标题=docState.name（变化即刷新） |

### 3.2 保持全局共享（产品级，单一实例，不 per-tab）

- `recents.json`（最近使用列表——产品级数据，与官方桌面一致）
- `hostFilesDir`、`web_console.txt`（日志单文件，前缀 `[T<tabId>]` 区分）
- 页面 localStorage（主题 `ui-theme-id`、`welcome` 首启标记等）——ArkWeb 多实例
  共享同一 user data dir，跨实例连通。**共享是语义正确的**（产品设置本就全局），
  P0 验证点仍列入（§9）。
- 沙箱工作副本 `hostFilesDir/<name>`（打开链的源文件固化）——保持全局；
  允许同一文件开两次（官方桌面同语义：两窗口保存互相覆盖，最后保存者赢）。
- 系统字体桥/ rawfile 资源 —— 只读共享，无状态。

### 3.3 临时文件必须 per-tab（本项目最大的隐形坑）

现状 `open-in.bin / in.bin / save.<ext> / saveas-in.bin / saveas-out.<ext>` 全是
**共享名、TRUNC 重写**。多实例下 A tab 转换写入时，B tab 的 XHR 拉取/保存回读
会拿到对方字节 → **内容错乱（必现级 bug）**。

修复：**后缀化**（不动 rawfileLoader——其 loadUserFile 禁止 `/`，目录方案会被
穿越校验拦截，改 loader 属不必要风险）：

- `open-in.<tabId>.bin`（ArkTS 写入；页面 XHR 拉取 URL 同步变，
  见 §6 页面侧改动）
- `in.<tabId>.bin` / `save.<tabId>.<ext>` / `saveas-in.<tabId>.bin` /
  `saveas-out.<tabId>.<ext>`
- 封装小工具 `tabPath(tabId, base)` 统一生成，saveBinRaw/doSaveAs/save:as 分支
  全部走它；临时文件不开目录。

## 4. 桥与命令路由（ascBridge 复用 + 装配参数化）

现状（EditorPage.build 的 onControllerAttached 内）：**每个 Web 实例触发一次
装配**（`new AscNativeDispatch + setHandler(new ShellCommandHandler(this)) +
setSaveTargetReader(() => this.saveTarget)` + registerJavaScriptProxy）。

这给了一个零架构改动的机会：**AscNativeDispatch 本来就是 per-controller 创建的**
——只要把装配里的依赖从「this（单例 EditorPage）」换成「per-tab 对象（DocTabItem /
TabDocView owner）」，桥自然 per-instance 隔离：

| 装配点 | 现状 | 改造后 |
|---|---|---|
| `new AscNativeDispatch(filesDir, log)` | 单例共用 | per-tab（参数不变，多实例而已） |
| `setHandler(ShellCommandHandler(owner))` | owner=this | **home 实例**：`HomeHandler(容器)`——`open:recent`/`create:new`/`open:folder` → 容器**新建 doc tab**（原 loadUrl 行为整段换成 `openInNewTab(...)`）；`go:folder`/`file:close`→ 激活 home。**doc 实例**：`DocHandler(tabItem)`——`save:bin`/`save:as` → 该 tab 的 saveBinRaw/doSaveAs（port 原 onShellCommand，this→tabState）；`go:folder`→ 激活 home 不销毁；`file:close`→ 关闭自身 tab |
| `setSaveTargetReader` | 读 this.saveTarget | 读该 tab 的 docState.saveTarget |
| `setLocalStartOpenHandler` | 触发 this.onEditorReadyForDoc | 该 tab 的 onDocReady（读 tabState.pendingOpen；注入脚本用**该 tab 的 controller**——原代码 runJavaScript 在这就改为闭包绑定 tab 的 controller） |
| registerJavaScriptProxy 的 ascNative | 单例 | per-tab new（缺省桥共享无状态，但独立更干净） |

ascBridge.ets 本体只需两处小改：`AscNativeDispatch` 构造签名不变；
`execCommand`/`save:type`/`LocalStartOpen` 逻辑已经走 handler/回调——**零改动，
仅装配方换 owner**。（唯一注意：`SaveQuestion` case 现返回 'false'，见 §7 关闭守卫。）

## 5. UI 组件（tab 条）

**对 ArkUI Tabs 原生 TabBar 与内容节流：不用 Tabs 的 TabBar / 不用 Tabs 的滑动手势
（`scrollable(false)`、`barHeight(0)`），但**容器用 Tabs**——内容切换容器与
Web 生命周期解耦后，Tabs 只剩「当前 index 显示哪个 NodeContainer」的职责，
无黑盒；NodeController 节点缓存保证后台 tab 的 Web 组件常驻。

TabBar 元素：

- 主页 chip：`主页`（图标可选，文字即可）；激活态高亮（主题色）。
- 文档 chip：`标题（docState.name，截断 maxLines=1）` + 空格 + `×`（点击=关闭）。
- 溢出：Scroll 横向滚动；新 tab 创建后 `scrollTo` 最右（当前 tab 可见）。
- 关闭当前 tab 后激活邻居：取「右邻 → 左邻 → home」顺序（与主流浏览器一致）。
- **关闭 = 从数组移除 + Stack 组件卸载**（Web 实例销毁，官方「关窗口=销毁」同构）。

## 6. 页面侧（ascshim）改动清单——极少

### 6.0 ascshim 九段逐段多实例影响面（2026-09-08 逐段源码取证）

结论先行：**页面脚本 95% 零适配**——每个 Web 实例拥有独立 window/独立
AscNative 注册/独立 JS 上下文，ascshim 各段的防重守卫与等待循环都是
per-instance 的（天然落入官方「每实例一无所知」语义）。真正受多 tab 影响
的只有 4 处逻辑 + 1 处内存账目 + 1 处日志区分：

| 段（ascshim 生成段） | 多 tab（多实例）行为 | 结论 |
|---|---|---|
| 00_theme.js | `ui-theme-id` 读写 localStorage —— 跨实例**共享**（产品级主题设置，官方语义即全局） | ✅ 零适配 |
| 00_boot.js | `de/sse/pe-settings-autosave` 三键 localStorage 补默认 0（注释明言官方全局持久语义）；`__lsoB64` 工具；fetch hook 仅验收态（?m7auto=1 门控） | ✅ 零适配（fetch hook 属 m7 验收锁，见下） |
| 09_fonts.js | FONT 装填 per-instance（每实例约 20MB 级 XOR 装填**重复开销**——无共享路径，页面域无法跨实例） | ⚠️ 仅内存账目（§8）；零逻辑适配 |
| 10_engine.js | `__lsoU`/`__lsoKickWrapped` 守卫、踢闸——均 per-instance | ✅ 零适配 |
| 20_bridge.js | `installed`/`__ascDesktopEditorMethods`/obj 构造/AscDesktopEditor 占位——每页独立；3.7 web 语义 delete 段 per-instance | ✅ 零适配 |
| 30_open.js | DI 打开链/init 循环（等自己的 `Main.api`）/LocalStartOpen 链/ensureBgBtn（400 次插件兜底轮询）——全部 per-instance 自洽；**m7auto/m7open 是页面 URL 门控** | ⚠️ m7 两段纳入「验收锁」（见 §6.4）；其余零适配 |
| 40_save.js | asc_Save/asc_isOffline/asc_DownloadAs wrap、`_hookSave` 等 300 次等待守卫——per-instance；`welcome` 键仅在 loginpage 路径写（仅 home 实例，无争用） | ✅ 页面侧零适配（保存链会话文件在后缀化：§3.3，属 ArkTS 侧） |
| 50_init.js | 等自己的 AscNative → `_onReady` | ✅ 零适配 |
| 55_lic.js | 许可降级无状态，per-instance | ✅ 零适配 |
| EditorPage onPageEnd 注入 | `__ooh_installed` 错误采集 per-page；onConsole 落**单一** web_console.txt | ⚠️ onConsole 加 `[T<tabId>]` 前缀（§10 P2） |
| EditorPage onEditorReadyForDoc | XHR 拉 `userfile/open-in.bin` | ⚠️ 后缀化（§6.1 第 2 条） |
| AscNativeDispatch 装配 | per-controller 新建（onControllerAttached 内） | ⚠️ owner 参数化（§4） |

### 6.4 m7 验收锁（多 tab 与自动验收互斥——新适配点）

m7 验收态（`Smoke.enabled()` 即 m7Target 非空）下**禁用真多 tab**：容器
`openInNewTab` 前检查——验收态直接「关旧 doc tab、开新 doc tab」（单 tab
隧道语义，与现状同构）。理由：

- editorUrl 在 m7 态会为每个 doc tab 拼 `m7auto=1` → 多实例同时自动插入文本
  + 序列化 + save:bin 风暴（验收样本互相污染）。
- prof-snap（10s）/ai_fetch_test（15s）探针按实例触发 → 多实例重复跑。
- 产品态（m7Target 空）不受影响，真多 tab。

实现 = `openInNewTab` 入口一行判断 + m7 态关闭现 tab；验收矩阵与旧行为完全罗列化对比。

1. **URL 参数**：`editorUrl` 的 `sid=Date.now()` 改为 `sid=<tabId>`（tabId 单调递增，
   比毫秒更保证唯一；语义同步变为「tab 标识」）。页面侧 0 感知（sid 当前仅做
   cache-bust 防复用，读不读值都行）。
2. **XHR 拉取路径**（EditorPage.onEditorReadyForDoc 的注入 JS 字符串内）：
   `userfile/open-in.bin` → `userfile/open-in.<tabId>.bin`。30_open.js 页面侧
   若有同型 XHR 拉取（检查后同步）——实际在 EditorPage 注入串，见 §7 接口表。
3. **未保存标记（关闭守卫依赖）——零页面改动（官方态位已取证）**：
   官方编辑器自身维护未保存状态于 `Main._state.isDocModified`
   （`apps/common/main/lib/controller/Main.js:2057` 注册
   `asc_onDocumentModifiedChanged` 回调 → `this._state.isDocModified =
   isModified`，`isModified = this.api.asc_isDocumentCanSave()`）。
   且 30_open.js 已持有访问句柄（`window[DE|SSE|PE].controllers.Main`，
   line 17-18/230 同型）。
   **关闭守卫 = ArkTS runJavaScript 异步读官方态位**：
   `window.DE.controllers.Main._state.isDocModified`（editor 名按当前 tab ext
   取 DE/SSE/PE）→ 回调到达后弹对话框。零 bridge 改动、零页面 hook。
   （备选：官方 Gateway 事件 `setDocumentModified`（同文件 2577 行链路）——
   若实现时发现 _state 字段不稳（跨版本私有字段风险），改走 Gateway 事件
 + 页面标记 `window.__lsoModified`，代价 = 40_save 增约 6 行。）
   → ascBridge.ets **0 改动**；守卫经 runJavaScript 一回调完成。
4. **其余全部零改动**（每实例 ascshim 天然独立执行：hook 面/字体装填/主题/自动
   保存开关均 per-instance 自洽）。

## 7. 核心流程（改后行为定义）

| 场景 | 行为 |
|---|---|
| 欢迎页点「最近文件/新建卡片/打开文件」 | HomeHandler → 转换链（不变）→ **新 doc tab**（不再 loadUrl 覆盖当前 Web） |
| 编辑器 FileMenu「返回」go:folder | 激活 home tab（**文档 tab 存活**）——官方桌面语义「返回列表」；文件仍开着=可点 tab 回 |
| FileMenu「关闭文件」file:close / chip 的 × | **关闭守卫**：先查 `__lsoGetModified`；有未保存 → promptAction 三键对话框（「保存并关闭 / 不保存 / 取消」，官方 SaveQuestion 语义）；保存=走该 tab 保存链后关；无改动 → 直接关 |
| tab 切换 | activeTabId 变化 → Stack visibility 切换（0 重建） |
| 保存（菜单 ctrl+s / 自动保存链） | DocHandler → 该 tab saveBinRaw（tabPath 后缀化）→ saveTarget/name/recents 全 per-tab |
| 另存为 | 该 tab doSaveAs（uri 写 + name/ext/saveTarget 演进 + tab 标题刷新）|
| 同一文件两个 tab | 允许；工作副本独立（沙箱<name>共享——后保存者覆盖，官方桌面同语义） |
| 超过 MAX_DOC_TABS | toast「文档数量已达上限」+ 拒绝新建（不静默降级） |
| 主页 tab × | 无（不渲染） |

**兼容保留**：EditorPage 现有 `onShellCommand` 的 open:*/save:* 逻辑整体平移为
`HomeHandler`/`DocHandler` 两个处理类方法；convertAndOpen 尾部
`loadUrl(editorUrl)` 改为 `container.openInNewTab(converted, name, ext, state...)`。

## 8. 内存与性能策略

参考基线（无实测，P0 测出后校准）：单文档实例 ≈ 引擎 JS 堆几百 MB + 字体缓存
（per-instance 页面各自装字体——**每实例 FONT_XOR 装填重复 ~20MB 级**，因
localStorage 是全局但字体装填走 window 变量 per-instance）。

- `MAX_DOC_TABS = 5`（可调常量；Pad 8GB 档合理；官方桌面无上限，我们内存受限，
  **限制数显性**——用户决策点）。
- 隐藏 tab 保持 alive（官方语义）；**若真机证明内存压力大**，升级路径：
  关闭非活跃 tab（最近最少使用）而非降级为快照——保持 A 语义，宁可提示用户。
- autosave 保持默认关（isLight 语义不受多 tab 影响：每实例独立开关状态，
  设置面板改的是本实例 localStorage——**注意**：autosave 开关存页面 localStorage
  全局连通（§3.2），改一次=全局生效，与官方「产品设置全局」一致，不修）。

## 9. P0 关键验证（先冒烟再改造——风险集中在这 4 点）

1. **NodeContainer/NodeController 节点复用保活**（Harmonix 模式落地性）：两 tab
   （Tabs+ForEach+NodeContainer）切换，runJavaScript 回到后台 tab 实例 → 页面/
   引擎状态仍在（切回零重建）；确认 NodeContainer 复用不触发
   onControllerAttached 二次装配（桥注册不重复）。
2. **多实例内存实测**：双文档实例 → `hdc shell dumpsys meminfo <pkg>` 前后对比
   （2 实例峰值 vs 1 实例基线；估算 MAX_DOC_TABS 合理值）。
3. **localStorage/缓存跨实例语义**：主题切换、`welcome` 标记在双实例下行为
   （预期全局一致；若互斥排他性异常→日志取证，可能需 per-instance 域）。
4. **onInterceptRequest 多实例并发**：双实例同时拉字体/资源无互踩
   （rawfile 只读共享，预期通过）。

P0 实现 = 最小补丁：P0TabsProbe 组件（`p0tabs=1` 启动参数门控——产品态零变化）
按 §5 Harmonix 骨架造「主页/文档两节点 + 自绘 tab 条」，复用现有 Web 装配
（onInterceptRequest/桥注册原样 per-node）→ 真机验证 → 通过后进入正式改造
（P1 把现有 Web 隧道整体搬进该骨架）；失败点回来改设计
（降级路线=方案 B，但**不预解锁**，先证 A）。

### 9.1 P0 执行记录（2026-09-08 1.8 真机 ✅ 全过）

验证形态：`P0TabsProbe`（p0tabs=1 门控，Tabs+ForEach+NodeContainer 双节点 =
主页实例（loginpage）+ 编辑器实例（word 空模板）。取证键（web_console.txt）：

| 点 | 证据 |
|---|---|
| a 节点复用保活 | T2 实例仅 **1 次** ASC_BOOT（T1788865514917），切回后再 probe
  `P0_ALIVE_T2 rd=complete mod=CLEAN`（T1788865557854）——**无二次 ASC_BOOT
  = 页面未重载**；切换两次 T1 均 rd=complete |
| b 内存实测 | 主进程 411MB + render#1（主页）303MB + render#2(编辑器) 131MB ≈
  **845MB 常驻（双实例）**；后端 stable 后再校（P2 定 MAX：初判 3-5 合理，
  §8 上限暂按 **3** 起） |
| c localStorage 跨实例 | 两实例 `ls_ui=theme-classic-light` **一致**（共享正确——主题/autosave 是
  产品级语义） |
| d onInterceptRequest 并发 | T2 加载期字体 XHR 11 种全部 200 + T1 同步拉 loginpage 缩略图
  pass-through——**无互踩/无 miss** |
| 附 | T2 全链就绪（FONT_XHR→LSO_MENUMODE isDesktopApp/offline 档位正确）
  —— per-node 桥装配全链在 NodeContainer 形态下工作 |
| 附 | `Main._state.isDocModified` 读取成功（mod=CLEAN）——关闭守卫零页面
  改动方案成立（§6.3） |

**结论：P0 通过，A 方案可行性实锤；Harmonix 模式在 1.8 ArkWeb 落地无坑。**
转向 P1（容器化：现有单实例隧道整体搬进该骨架）。

### 9.2 P1a 执行记录（2026-09-08 1.8 真机 ✅）

容器骨架化（`DocTabHost.ets`：Tabs+ForEach+NodeContainer 通用容器，
`EditorPage.onInstanceReady` 承载 per-node 完整装配；业务状态仍单例）：
P1A_TABS_INIT home0 → 新建卡 → P1A_OPEN_TAB id=1（doc 节点懒构建）→
INSTANCE_READY kind=doc → 编辑器全链（LSO_OPEN_DOCUMENT_OK/GW_BIN/FONT/
KICK_SERVERID/LSO_MENUMODE 桌面离线档）→ 切主页 P1A_ALIVE doc1 rd=complete
（后台保活）→ × 关闭 P1A_CLOSE_TAB id=1 → 回主页 → 保存链回归
（SAVE_BIN_X2T rc=0 → 24742B zipok → SAVE_AS_DIALOG 弹系统保存框）。
教训一则：tab chip 的 × 独立成节点并放大触区（标题文本承载切换、
× 独立 onCloseDoc）——兄弟节点无冒泡干扰，一击即中。

## 10. 实施阶段（每阶段一次构建 + 真机冒烟）

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | 双实例并存最小补丁（§9 四点） | 四点全过，内存基线数据落记录 |
| P1 | 容器化改造：DocTabsModel/DocTabState/tabPath 后缀化/HomeHandler+DocHandler 拆分/临时文件 per-tab | 冷启动→主页；单一文档全链回归（打开/编辑/保存/另存为） |
| P2 | tab 条 UI + 切换 + 关闭守卫 + 上限 | 切 tab 零重建；×/file:close 守卫三键；超限 toast |
| P3 | 多文档矩阵：2 文档同开/交替保存/同名双开/AI 插件 in doc tab/关闭后重开 | §11 矩阵全绿 |
| P4 | 稳定化：日志前缀、旧验证工具链适配、文档更新 | 构建可复现（build 链重跑一次） |

## 11. 验收矩阵（P3 执行）

1. 新建 2 文档（word+cell）→ 交替编辑/保存 → 两个 tab 内容各自正确
2. 打开 + 新建混开 3 tab → 逐一切回状态保留（光标/编辑内容）
3. A tab 保存 → B tab 另存为 → 无串写（临时文件隔离验证）
4. 同一文件开两次 → 分别修改保存 → 后者覆盖前者（声明语义）
5. 关闭有修改 tab → 三键对话框每键行为正确（保存/丢弃/取消）
6. 关闭时系统 picker 打开再取消（未保存态保留）
7. tab 上限：6 次打开 → 第 6 次 toast 拒绝
8. 主页返回：go:folder 后点 tab 回文档（状态在）
9. 自动验收链（m7accept）回归（单 tab 行为不变）
10. 内存：3 文档常驻 + 轮询 dumpsys meminfo 无泄漏式增长（5 分钟）

## 12. 风险与回退

- 多 Web 组件存在异常（P0 挡板）：真机证明不兼容 → A 方案不可行，**回退讨论
  （方案 B）**——P0 就是为此设的门。
- ArkWeb 后台实例被系统整理（内存压力）：即官方桌面「系统 OOM 关窗口」同款，
  可接受；观察期若严重 → 上限调低 + 关闭守卫补「已恢复」提示。
- EditorPage 拆分改动面大（879 行单文件）→ P1 务必小步：先只拆状态不拆 UI，
  每小步真机冒烟。
- 日志噪音：多实例 onConsole 双倍 + 桥日志 → tabId 前缀区分，归档期保留。

## 13. 需要用户拍板的决策点（默认值已给，可在审查中改动）

1. **tab 上限 MAX_DOC_TABS=5**（内存策略见 §8；官方桌面无上限，我们显性限制 + toast）
2. **关闭守卫对话框**：官方三键「保存并关闭/不保存/取消」——确认不做简化版（仅「取消/忽略」两键）
3. **go:folder 语义 = 激活主页、文档保留**（与官方桌面「返回列表」一致；另一种是关闭 tab——不推荐，建议保留）
4. **容器 = 自定义 Stack**（不用 ArkUI Tabs，理由 §5）

## 附：改动文件清单

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/pages/EditorPage.ets` | 容器化主体（§2/§4/§7）；原字段→DocTabState；convertAndOpen/onShellCommand 迁移；tabPath 工具 |
| `entry/src/main/ets/common/ascBridge.ets` | **0 改动**（per-instance 装配参数化在 EditorPage；守卫读官方态位不经桥） |
| `entry/src/main/ets/pages/editor_*/`（新） | DocTabItem/DocTabState/HomeHandler/DocHandler/TabBar 拆出 1-2 个新文件（EditorPage 瘦身） |
| `scripts/onlyoffice/desktop/src/40_save.js` | **0 改动**（守卫读官方 `Main._state.isDocModified`；仅当备选方案落地才 +6 行） |
| `scripts/onlyoffice/desktop/src/30_open.js` | 0 改动（XHR 注入串在 EditorPage 侧；`Main` 句柄复用现有模式，仅 EditorPage 侧读） |
| 构建链 | 0 改动（纯 ArkTS + ascshim 段内小改，ascshim 由 make_ascshim.py 重跑生成） |
