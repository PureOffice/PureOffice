# 未保存关闭守卫（Unsaved-Close Guard）设计

> 2026-09-09。现状代码实证 + 实现方案。目标问题：文档被编辑过（新建或打开已有）
> 且未保存时，关闭 tab / 关闭窗口是否有「文件未保存」提示与保存动作？

## 0. 现状（逐入口实测结论，file:line 均为 rawfile/webapps 实际代码）

| 关闭入口 | 现状 | 判定 |
|---|---|---|
| 自绘 tab 条 × | `DocTabHost.ets:283` → `EditorPage.closeDocTab`（EditorPage.ets:950）——直接 splice 删节点 | ❌ **无提示**，未保存内容丢弃 |
| 文件菜单「退出」（桌面档 miExit → `file:exit`） | Desktop.js:643 `native.execCommand('editor:event', file:close)` → EditorPage.ets:210-213 `closeDocTab(ctx.id)` | ❌ **无提示** |
| 官方 Header 右上 X | Header.js:383 `NotificationCenter.trigger('close')` → Main.js:250 `closeEditor` → Main.js:693 `onRequestClose` → **官方 web 弹框**（`asc_isDocumentModified()` 为真时，语言包 msg=leavePageTextOnClose 中文词条在；按钮=「确定(放弃修改并离开)/取消」——**无「保存」项**，web 语义假设服务器已自动保存）| ⚠️ 有提示但语义不符（离线单机 autosave=false，点「确定」=丢数据） |
| 页面卸载（onbeforeunload） | Main.js:2498 `onBeforeUnload`，未保存时 `return`（浏览器原生确认）；但 ArkTS 关闭路径（删节点/退出应用）不经浏览器卸载 | ⚠️ 理论生效、实际不触发 |
| 系统返回键/后退手势 | EditorPage 为 @Entry 但**未实现 onBackPress** → 默认直接退出应用 | ❌ **无提示** |
| 系统 ✕（PC 三键区） | WindowStage.on('windowStageClose')（@since 14）——系统 ✕ 点击事件，回调 return true=不关窗；WPS 同款拦截正路（2026-09-10 修正初稿「无可拦截 API」的错误结论：当时只查了 onWindowStageDestroy 等事后回调） | ✅ **可守卫**（2026-09-10 实施——恒拦→requestBackExit） |
| Alt+F4 / 多任务滑掉 | 平台级窗口关闭，无可拦截 API | ❌ 不可守卫（平台限制） |

**结论：除官方 Header X 有一个「放弃/取消」两按钮 web 提示外，其余入口全部无提示。**

## 1. 目标行为（官方桌面版语义——三段式）

未保存时关闭 → 弹框三按钮：

1. **保存**：走官方保存链（新建首次=系统另存为框）；保存成功 → 关闭；用户取消另存为 → 不关闭（数据没存住就不走）。
2. **不保存**：丢弃修改，关闭。
3. **取消**：留在文档。

## 2. 关键机制（全部来自官方权威源，零猜测）

- **未保存判定**：`window.editor.asc_isDocumentModified()`（sdkjs/cell/sdk-all-min.js 定义；官方自用点 Main.js:695/:1154/:2502）。**关闭瞬间点查**（1 次 runJavaScript），不维护镜像状态（零竞态、零事件接线）。
- **保存触发**：`window.editor.asc_Save()`（40_save.js:101 已覆写原型 → save:bin → ArkTS x2t → 落盘/另存为）。保存完成信号的落点位在 ArkTS 侧（save:bin 同步链尾 / doSaveAs 完成后），见 §3.4。
- **官方 X 链关闭入口**：`window.SSE/DE/PE.Controllers.Main.closeEditor`（三编辑器均为 `(function(){...})(), <NS>.Controllers.Main` 模式，已实锤）。

## 3. 方案：统一守卫 + 三按钮弹框

```
任何关闭入口
   │
   ├─ 页面查询 asc_isDocumentModified()
   ├─ '1'（未保存）→ ArkTS AlertDialog 三按钮
   │     ├─ 保存   → window.editor.asc_Save() → 保存链完成 → closeDocTab
   │     │                                        （另存为取消/保存失败 → 不关）
   │     ├─ 不保存 → closeDocTab（直关，无守卫递归）
   │     └─ 取消   → 不动
   ├─ '0'（干净/无文档）→ closeDocTab 直关
   └─ 查询失败（'2'：页面异常；或 runJavaScript err：页面死/组件销毁）→ 直关（日志）
         —— 数据已不可救（引擎死），守卫只会死锁，不阻拦
```

### 3.1 新方法 `requestCloseDoc(ctx)`（EditorPage.ets，守卫包装器）

`closeDocTab(id)` 保持原样（=权威关闭，无守卫）；新增 `requestCloseDoc(ctx)` 只做查询与弹框，**决策后的关闭动作仍走 closeDocTab(id)**——职责分离，不碰现有逻辑。

查询脚本（返回值语义化：'1' 未保存 / '0' 干净 / '2' 无法判定）：

```js
(function(){
  try {
    var e = window.editor;
    if (e && typeof e.asc_isDocumentModified === 'function') {
      return e.asc_isDocumentModified() ? '1' : '0';
    }
    return '0';   // editor 未就绪（加载中）= 无已编辑内容，视同干净
  } catch (e2) { return '2'; }
})()
```

runJavaScript 回调：
- err（页面死/节点已分离）→ `closeDocTab` 直关 + 日志 `CLOSE_GUARD_QUERY_ERR`。
- '1' → 弹三按钮框；'0' → 直关；'2' → 直关 + 日志。

### 3.2 三按钮弹框（ArkTS 侧，非页面）

`arkUI AlertDialog.show`（EditorPage 直调，与 files:explore 的 promptAction toast 同侧；ArkTS 文案直写中文——单语言产品，项目惯例 home 侧栏文案同）：

- title：`未保存的文档`；message：`文档「<tab 标题>.ext」有未保存的修改，要保存更改吗？`
- 保存 → 按钮：AlertDialog primaryButton `保存`（AlertDialog 支持 primaryButton/secondaryButton + mask 点击 cancel；**取消**= secondaryButton `取消`？三按钮在 AlertDialog 只有两个 button 位——**实现选择**：primary=保存、secondary=不保存、mask 点击=取消（开启 autoCancel=true）——或自定义 @Builder 弹层。**两个方案**：
  - **方案 A（推荐，零新组件）**：primaryButton「保存」+ secondaryButton「不保存」+ autoCancel true（点空白=取消）。三语义齐全，键盘/触屏皆可。
  - 方案 B：自绘 @State 面板（样式完全自主）——成本高、与系统弹框不一致，仅当用户要求绝不让使用者误点时才做。
- 保存危险提示不在此框（弹窗语义明确）；「取消」按钮文案用 `取消`。

### 3.3 保存后关闭状态机（唯一在途，勿多）

`EditorPage.closeGuardDefer: DocTabCtx | null`（至多一个在途——弹框是模态的，天然互斥）：

- 「保存」按下 → `closeGuardDefer = ctx` → `ctx.js(asc_Save 触发)`：
  - 页面 asc_Save → save:bin → `onTabCommand`（EditorPage.ets:172）返回前：`saveBinRaw` 同步完成（saveTarget='uri'/'sandbox'）→ **消费点**：onTabCommand save:bin 分支返回值后 `if (this.closeGuardDefer === ctx) { this.closeGuardDefer = null; this.closeDocTab(ctx.id); }`。
  - saveTarget='none'（新建首次保存）→ saveBinRaw 内部走 `doSaveAs`（异步系统框）→ **消费点**：`doSaveAs` 尾部（EditorPage.ets:470 前）：
    - 另存为保存成功 → `if (this.closeGuardDefer === ctx) { 清 defer; closeDocTab; }`
    - 用户取消另存为 / 写盘失败 → 清 defer，**不关**（日志）。
- 清理兜底：`save:bin` 返回 'false'（x2t/zip 失败）→ handler 清 defer 不关。

### 3.4 入口接线（5 处 → requestCloseDoc）

1. **tab ×**：DocTabHost.onCloseDoc 不动；`EditorPage.closeDocTab` 改判——**不动 closeDocTab**（权威），改在调用处：DocTabHost 的 onCloseDoc 回调（EditorPage.ets:1041）改为 `this.requestCloseDoc(this.findCtx(id))`；file:close 同。
   - `findCtx(id)`：从 docTabs 找 DocTabCtx（loop）。
2. **文件菜单「退出」**：onTabCommand `editor:event` file:close 分支（:210-213）→ `requestCloseDoc(ctx)`。
3. **官方 Header X**：ascshim 40_save.js 新增 `_hookCloseEditor`（与 _hookSave 同模式：pageGate `/main/index.html` + waitN<300 重试）——拿 `window.SSE || window.DE || window.PE` 的 `.Controllers.Main` 实例，覆写实例方法 `closeEditor`（官方链 250 行唯一入口）为：上报 ArkTS 关闭意图，**不再进官方 onRequestClose（两按钮框）**：

```js
var _ns = window.SSE || window.DE || window.PE;
var _m = _ns && _ns.Controllers && _ns.Controllers.Main;
if (_m && _m.closeEditor && !_m.__lsoCloseGuard) {
  _m.__lsoCloseGuard = true;
  _m.closeEditor = function () {
    try { window.AscNative._call('execCommand', ['editor:event', JSON.stringify({action:'close-request'})]); }
    catch (e) { console.error('LSO_CLOSEREQ_ERR ' + String(e)); }
  };
}
```

ArkTS onTabCommand 增加 `close-request` 分支 → `requestCloseDoc(ctx)`。官方 onRequestClose 不再被触发（专 X 关闭语义由我们接管——一致性：与 tab × 同框）。
   注意：`close_editor` URL 参数/`customization.close` 的 web 菜单项（canRequestClose && !isDesktopApp）本就不显示（isDesktopApp=true），无重复入口。
4. **系统返回键**：EditorPage（@Entry）新增 `onBackPress()` 守卫（§3.5）。
5. **onbeforeunload** 不动（ArkTS 路径不触发；JS 内部跳转 welcome 时官方行为保留，无重复弹框风险——跳转欢迎页走 goback 官方链（onRequestClose? goback.js:704——是：goback.requestClose 时也走 onRequestClose）…… 注：goback 链 now 也会被 onRequestClose 官方弹框拦（未保存时）——**实测待定项**：goback（返回主页）行为不在本次范围（回主页=关文档语义一致，建议同接 close-request——记入验证清单）。

### 3.5 窗口级守卫 `onBackPress()`

- @Entry 组件专属回调，返回 true=拦截系统返回键。
- 流程（**队列**，避免多文档时一屏多框）：
  1. 收集未保存候选队列：`docTabs` 中 kind='doc' 全部（从 focus 起、不含 home）。
  2. 队列逐个 `requestCloseDoc`（复用弹框）；每个完成（关/不关清零）继续下一个。
  3. 队列空 → `getContext(this).terminateSelf()` 退出应用（返回键=关闭窗口语义）。
  4. 若任一弹框选择「取消」→ **终止队列、保持应用**（返回键拦截）。
  5. home tab 无文档/队列空（所有 doc 已保存）→ 直接 `terminateSelf()`。
- 保存动作的 defer 状态下（另存为框弹出中）返回键再按：defer 非空 → 返回 true 忽略（模态互斥，应用内已有系统框）。

### 3.6 平台限制与「关闭窗口」实体

- **PC 系统 ✕ / Alt+F4 / 多任务滑掉**：HarmonyOS 平台无「窗口关闭前拦截」API（`onWindowStageDestroy`/`onDestroy` 均事后）。已隐藏系统标题栏（EntryAbility `setWindowDecorVisible(false)`+decorHeight 37）——**系统 ✕ 随 decor 一并隐藏，UI 上本就不存在**（2026-09-09 实测截图确认右上角无系统按钮）。
- **「点击关闭窗口」实体 = 自绘窗口 ✕**（2026-09-09 实施，goal 正解）：tab 条最右（Row 尾部、右 padding 150 避让区之前）新增 `SymbolGlyph(xmark)`——点击 → `EditorPage.requestBackExit()`（与返回键 `onBackPress` 同语义：未保存逐个询问→队列全处置完 `terminateSelf`）。**这是替代不可拦截系统 ✕ 的唯一可守途径**，已真机实证（弹框截图+不保存退出 pid 消失+取消存活）。**2026-09-10 用户决策：自绘 ✕ 移除**（三键组只留 −□ 最小化/最大化还原；关闭窗口交还系统途径——返回键守卫保留：onBackPress=requestBackExit）。
- 仍不可守：任务栏/多任务滑掉、Alt+F4（平台级，无 API）。

## 4. 文件改动清单

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/pages/EditorPage.ets` | 新增 `requestCloseDoc`/`findCtx`/`closeGuardDefer`/`onBackPress`；`onTabCommand` file:close 分支改守卫 + 新增 close-request 分支；`save:bin` handler 尾部消费 defer；`doSaveAs` 尾部消费 defer；build 处 onCloseDoc 改守卫 |
| `scripts/onlyoffice/desktop/src/40_save.js` | 新增 `_hookCloseEditor` 段（官方 X 链重定向 editor:event close-request） |
| `scripts/onlyoffice/desktop/src/assemble.txt`（build 列表） | 40_save.js 已含（部件清单不变——40_save 已在 assemble：确认 parts 行含 40_save.js ✓ 无需动） |
| `docs/ONLYOFFICE_MULTITAB_DESIGN.md`?? 否 | 本次设计即本文档 |

ascshim 更改无需动 build（40_save 已在 assemble 列表——确认：assemble parts 输出「00_theme.js, 09_fonts.js, 00_boot.js, 10_engine.js, 20_bridge.js, 30_open.js, 40_save.js, 50_init.js, 55_lic.js」✓）。

## 4.5 实现修正记录（2026-09-09 真机实证——与初稿的三处偏差）

1. **未保存查询 API ≠ asc_isDocumentModified**：asc_isDocumentModified **仅 cell 引擎
   存在**（word/slide 的 sdk-all-min 无——grep 实锤）；三引擎均有
   `asc_isDocumentCanSave`（DE 官方自身以它做 onDocumentModifiedChanged 的
   isModified——Main.js:2575）。查询脚本=CanSave 优先 / Modified 兜底。
2. **API 句柄 = `window.<SSE|DE|PE>.controllers.Main.api`**（**controllers 小写**——
   源码写 `.Controllers` 大写但运行时不存在；实证=10_engine LSO_KICK 链同句柄
   + 真机 LSO_EDITOR_DIAG mainApi=true）。window.editor/window.Asc.editor 均非实例。
3. **ArkWeb runJavaScript 返回 JSON 编码字符串**（res=`"1"` 带引号——直接 ==='1'
   永假落进直关分支，曾致守卫「形同虚设」）；所有 res 必须先 JSON.parse。
4. **canSave 复位缝隙（真 bug）**：asc_Save 触发即复位引擎 canSave——「保存→另存为
   取消→再 ×」时页面返回 v=0 → 直关丢数据。修复=ArkTS 侧记忆
   `DocTabState.saveAborted`（clearCloseGuard(false) 置位 / ok 清位），守卫查询
   忽略页面 '0' 按未保存弹框。
5. **官方 Header X / 文件菜单「退出」在 UI 上不可达**（isDesktopApp=true →
   Header.js:969 canCloseEditor=false 不渲染 btnClose；Desktop.isActive()=false →
   FileMenu.js:505 不注入 fm-btn-exit）——closeEditor 重定向与 close-request 分支
   留作未来 web 关闭档的一致性（休眠无副作用）。
6. **诊断段已删**（3.8.6 临时轮询——结论固化进注释，不留探针）。
7. **「点击关闭窗口」= 自绘 tab 条最右 ✕**（§3.6）：系统 ✕ 随 decor 隐藏不存在，
   返回键（onBackPress）uinput 无法注入（该设备键码通道被 hium VM 截断，
   KEYCODE_BACK=2 等 5 个码均无效果）——自绘 ✕ 是可用且可注入实证的关闭窗口入口。
   onBackPress 与窗口 ✕ 共用 `requestBackExit()`（队列+terminateSelf）。
   **2026-09-10 用户决策：自绘 ✕ 移除**——改走 WPS 同款系统拦截：系统三键常驻
   （decor 只藏标题栏，1.4 UI dump [2370,297]-[2560,335] 实证；此前「三键随 decor
   隐藏」结论错误——取证样本 1.8 为 tablet 沉浸窗口，本无三键），`WindowStage.on
   ('windowStageClose')`（@since 14，return true=不关窗）拦截系统 ✕ → 同一
   `requestBackExit()`。守卫入口：tab × / 返回键手势 / 系统 ✕（Alt+F4 与多任务
   滑掉平台不可守，同 WPS）。
8. **真机实证（1.4 MOR-M1）**：tab ×（弹框/取消/不保存/保存落盘自动关/另存为取消
   不关/干净直关）✅；窗口 ✕（未保存→弹框截图）✅、「不保存」→ terminateSelf 退出
   （pid 消失）✅、「取消」→ 应用存活 ✅。
9. **真机实证（2026-09-10，系统 ✕ 拦截链）**：无文档 → 点系统 ✕ → 直接退出 ✅；
   新建+编辑（正文输入 guardtest）→ 点系统 ✕ → 弹「未保存的文档」三按钮框 ✅
   （截图 .temp/1.4-close-guard.png）→「不保存」→ 应用退出（pid 消失）✅。
   自绘键组（−□✕）已全删：右上角仅剩系统三键（1.4 截图+UI dump 双证）。

## 5. 验证清单（✅=2026-09-09/10 真机 1.4（MOR-M1）已验；✳=当前 UI 不可达
   （休眠守卫，逻辑已接、无触发点）；⏳=待验）

1. ✅ 新建文档 → 输入文字（未保存）→ 点 tab × → 弹三按钮框；「取消」留在文档；「不保存」关闭（内容不落盘）；「保存」→ 新建=系统另存为框 → 存好自动关（recents 出现）。
2. ✅ 打开已有文档 → 编辑 → tab × → 「保存」→ 覆写原文件（或沙箱）后关。
3. ✳ 官方 X → 同一三按钮框（无官方两按钮框）——isDesktopApp=true 官方 btnClose 不渲染，UI 不可达（40_save 3.8.5 休眠守卫）。
4. ✳ 文件菜单「退出」→ 三按钮框——Desktop.isActive()=false 不注入 fm-btn-exit，UI 不可达（file:close 分支已改守卫，可达性恢复时自动生效）。
5. ✅ 返回键（焦点 doc 修改中）→ 三按钮框 → 不保存 → 应用退出；取消 → 不退出（2026-09-09 矩阵；物理键 uinput 无法注入，经自绘 ✕ 同链验证）。
6. ✅ 多文档：两 tab 未保存 → 返回键 → 逐个询问（先焦点）→ 全决定后退出；中途取消 → 停。
7. ✅ 干净文档（未编辑）关闭 → 直接关（无框）。
8. ✅ 保存链回退：新建→「保存」→ 另存为框取消 → 不关闭。
9. ⏳ 查询失败路径：引擎卡死/页面死 → 直接关不弹（日志 CLOSE_GUARD_QUERY_ERR）——逻辑简单且走防御分支，未构造触发。
10. ✅ 系统 ✕（2026-09-10 新增入口）：无文档直退；未保存弹框→不保存→退出（§4.5.9）。

## 6. 已知取舍（记录）

- 关闭瞬间点查（1 次 RTT）代替实时镜像：省事件接线、无竞态；代价=点击×到弹框间有 ~10ms 级延迟（不可感知）。
- 「保存」失败无重试 UI：失败=不关（日志）——用户可手动重存。
- 官方 Header X 的「放弃修改并离开」两按钮框被替换为三按钮框（重定向 closeEditor）：官方 web 语义（服务器自动保存）不适用于离线单机——语义校正必要。
- 页面跳转欢迎页（goback 链）挂 onRequestClose 的官方框路径：本次不接管（回到欢迎页=doc 实例保活，数据仍在进程内，不丢——多 tab 语义下「返回主页」不销毁文档）——**正确**，不需要守卫。
