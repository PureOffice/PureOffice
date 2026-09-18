# tab 条「+」新建按钮设计

**Goal:** tab 条上有文档时，旁边显示 + 按钮；点击弹出类型菜单（文档 / 电子表格 / 演示），选中即开对应类型的新文档——不必切回首页。

**Architecture:** 纯 UI 增量。tab 条是 ArkTS 自绘的 `DocTabHost`，+ 是 `Row` 内 `ForEach` 之后的一个 `SymbolGlyph` 节点，用 ArkUI 官方 `bindMenu` 挂三项 `MenuElement`；回调直接接现成的 `EditorPage.openNewFile(ext)`（欢迎页新建卡片走的同一条路），**不新增任何新建业务逻辑**。

**Tech Stack:** ArkTS（`DocTabHost` 组件）、ArkUI `bindMenu` / `MenuElement`（**本项目首次使用**）、既有 `openNewFile` 通路。

---

## 1. 背景

### 1.1 现状（事实）

- tab 条自绘在 `DocTabHost.ets`：`Row` + `ForEach(this.tabs)`，每个 chip = 标题 + ×（doc tab）；主页 chip 恒第一且无 ×。
- 新建通路**现成**：`EditorPage.onTabCommand` 的 `create:new` 分支 → `openNewFile(ext)`（`EditorPage.ets:523`）→ 读空模板 `onlyoffice/templates/empty.<ext>` → `openNewTabEntry`（开新 tab 并自动聚焦）。欢迎页「新建卡片」、文件菜单「新建」（`30_open.js` 3.9 段的 `desktop://create.new` 短路）都汇到这一处。
- **缺口**：只有在主页才能新建。文档开着时想再建一个，必须先切回主页 tab。

### 1.2 形态约束（决定实现，非选项）

- **弹层**：本项目 `CustomDialog` 真机点击失效（自定义内容里的按钮 `onClick` 不触发、事件到不了 ArkTS）、`AlertDialog` 只有两 action 键且无取消 → 既有 4 个弹层全是页面层 `Stack` 自绘覆盖层。
- **本次用户选系统菜单**（ArkUI `bindMenu`）：`MenuElement` 是**数据描述**（`{value, action}`），由系统渲染并回调，不经过组件树事件分发——机制上不同于 CustomDialog 那个坑。但**本项目首次使用**，须按 §6 前置验证。

## 2. 目标与非目标

**目标**
- 有 doc tab 时条上显示 +；只有主页时不显示；
- 点击 + 弹出三项菜单；选中开新 tab 并聚焦；
- 放映全屏时随 tab 条一起消失（零额外代码）。

**非目标**
- 菜单项图标（`MenuElement.symbolIcon` 存在，v1 不加——首次用系统菜单不同时引入第二个未知数）；
- 「打开文件」等其它入口进菜单（用户要的是"创建文档"）；
- 菜单观感定制（字号/宽度/圆角由系统决定）；
- UI 文案本地化（既有 4 个自绘弹层同样硬编码中文，是全局待办，不在本次范围）。

## 3. 交互设计

### 3.1 位置与显示条件

```
┌────────────────────────────────────────────────────────┐
│ [ 主页 ] [ 未命名的文档 ×] [ 报告.docx ×] [ + ]         │  ← tab 条（自绘 Row）
└────────────────────────────────────────────────────────┘
```

- **位置**：`Row` 内 `ForEach` **之后**——紧跟最后一个 chip（浏览器 tab 条同款）。不固定到条右端：PC 的条右侧有 150vp 系统三键避让内衬（`DocTabHost.ets` 的 `padding.right`），固定右端会与 chips 割裂。
- **显示条件**：`tabs` 中存在 `kind === 'doc'` 的项。只有主页时不存在。
- **放映全屏**：`fsMode` 已让整条 tab 条 `Visibility.None`（`DocTabHost.ets:443`），+ 随之消失。
- **尺寸与行为**：触区 36vp × 条高——宽由左右内衬各 10 + 字号 16 撑出，高 = `TAB_BAR_H`（Pad 32 / PC 37）；**不参与 flexShrink**——tab 多时仍由 chips 先收缩（既有语义，`minWidth` 下限兜底），+ 不被挤扁；`HoverEffect.Scale` 与 × 一致（PC 鼠标反馈）。
- **图标**：`SymbolGlyph($r('sys.symbol.plus'))`——与 × 的 `sys.symbol.xmark` 同族（`DocTabHost.ets:365`）。

### 3.2 菜单

| 菜单项 | 传入 ext | 新 tab 默认名 |
|---|---|---|
| 文档 | `docx` | 未命名的文档.docx |
| 电子表格 | `xlsx` | 未命名的电子表格.xlsx |
| 演示 | `pptx` | 未命名的演示.pptx |

- **措辞来源**：官方中文语言包同族词条（`Controllers/LeftMenu.newDocumentTitle` = 未命名的文档 / 未命名的电子表格 / 未命名的演示，已核对 `zh.json`），去掉"未命名的"。硬编码——与既有 4 个自绘弹层一致。
- **行为**：任一项 → `onNewDoc(ext)` → `EditorPage.openNewFile(ext)` → 新 tab + 自动聚焦 + 默认名按上表（全部是既有行为）。
- **options 用默认**：触发方式 = 点击（`bindMenu` 语义）；`placement` 默认 BottomLeft，超出屏幕由系统自动避让。

## 4. 组件设计

### 4.1 `pages/DocTabHost.ets`（改）

- 新增回调字段（与既有 `onSwitch` / `onCloseDoc` 同款注入）：
  ```ts
  onNewDoc: (ext: string) => void = () => {
  };
  ```
- `Row` 内 `ForEach` 之后追加：
  ```ts
  if (this.hasDocTab()) {
    SymbolGlyph($r('sys.symbol.plus'))
      .fontSize(16)
      .fontColor('#2B3B4D')
      // 触区：宽 = 16 + 10×2 = 36vp，高给满条高（SymbolGlyph 无 textAlign，
      // 宽度由左右内衬撑出——与 × 同款做法）
      .padding({ left: 10, right: 10 })
      .height(TAB_BAR_H)
      .hoverEffect(HoverEffect.Scale)
      .bindMenu(this.newMenuItems())
  }
  ```
- 两个私有方法：
  ```ts
  /** 是否已有文档 tab（+ 的显示条件；只有主页时不显示） */
  private hasDocTab(): boolean {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].ctx.kind === 'doc') { return true; }
    }
    return false;
  }

  /** + 菜单项（数据驱动：系统渲染并回调 action） */
  private newMenuItems(): MenuElement[] {
    return [
      { value: '文档', action: () => { this.onNewDoc('docx'); } },
      { value: '电子表格', action: () => { this.onNewDoc('xlsx'); } },
      { value: '演示', action: () => { this.onNewDoc('pptx'); } }
    ];
  }
  ```
- `bindMenu` 在每次 build 时求值新数组，无状态残留；菜单的开合由系统管理，我们侧无状态。

### 4.2 `pages/EditorPage.ets`（改）

`DocTabHost({...})` 注入（`build()` 的 `DocTabHost` 调用处，`EditorPage.ets:2584`）：

```ts
onNewDoc: (ext: string) => {
  this.arkLog('TAB_NEW_MENU ext=' + ext);
  this.openNewFile(ext);
}
```

（`openNewFile` 返回 `string`，此处忽略——与 `create:new` 分支同样不依赖返回值。）

## 5. 边界与错误处理

| 场景 | 行为 |
|---|---|
| 只有主页（冷启动） | 无 +（显示条件） |
| 放映全屏 | 无 +（整条 tab 条 `Visibility.None`，既有机制） |
| tab 极多 | chips 先收缩（`flexShrink` + `minWidth` 下限），+ 保持 36vp |
| 空模板缺失/读取失败 | 落既有 `CREATE_NEW_ERR` 分支（日志有记录）——本次不新增错误处理 |
| 连点多项 / 连开多 tab | 与连点欢迎页新建卡一致：每次开一个 tab，不设上限（既有语义） |
| 菜单弹出时切 tab / 关闭 tab | 菜单由系统关闭（点菜单外即关），我们侧无状态需维护 |

## 6. 验证方案

真机 **1.6**（MatePad 11.5 S / tablet）+ **1.5**（PC 形态）。判据取自 `web_console.txt`（`arkLog` 出口）。

**前置验证（实施第一步，不通过即停）**：只加 + 按钮 + 三项菜单 + 打点，真机点一遍确认 `action` 回调触发。这是本设计唯一的未知数（§7），先证伪再往下做。

1. 打开一个 docx → tab 条出现 +；
2. 点 + → 菜单弹出三项；
3. 点「电子表格」→ 日志 `TAB_NEW_MENU ext=xlsx` + `CREATE_NEW empty.xlsx len=…`；新 tab 出现且聚焦过去，标题「未命名的电子表格.xlsx」；
4. 三种类型各点一遍（`ext` 与产物一一对应）；
5. 冷启动（只有主页）→ 无 +；
6. 放映 pptx 全屏 → 无 +（退出放映后 + 回来）；
7. PC（1.5）：鼠标点击弹出、hover 反馈正常；
8. 回归：`tests/regression.sh` 全量（确认 tab 条改动没影响打开/保存/关闭链）。

## 7. 风险

- **高（已隔离）**：`bindMenu` 的 `action` 回调真机是否触发——本项目首次用系统菜单。CustomDialog 的前科是"自定义内容里的按钮 `onClick` 不触发"（事件经组件树分发），`bindMenu` 走系统菜单回调，机制不同、风险应低于前者，但**未实测**。→ 实施第一步即验证（§6），**不通过即停**。
  - **降级预案**：自绘居中弹层（蒙层 + 居中卡片 + 三个选项，与既有 4 个弹层同构）。届时 §3.2 的菜单部分改为覆盖层实现，其余（位置、显示条件、回调、文案、验证）不变。
- **低**：`sys.symbol.plus` 若在本设备缺失（项目只用过 `sys.symbol.xmark`）→ 构建期 hvigor 校验 sys 资源名会报错，届时查正确的符号名（**不改用文本**——用户已定用 plus 图标）。
- **低**：菜单观感由系统决定、不随我们的主题走——选系统菜单的固有代价（好处：自动适配深浅色与系统动效）。

## 8. 交付物清单

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/pages/DocTabHost.ets` | + 按钮节点、`onNewDoc` 回调字段、`hasDocTab()` / `newMenuItems()` |
| `entry/src/main/ets/pages/EditorPage.ets` | `onNewDoc` 注入 + `TAB_NEW_MENU` 打点 |
| `scripts/onlyoffice/tests/cases.tsv` | 不加 case（菜单需点击交互，回归框架判不了；验收按 §6 手工走） |

相关：[[onlyoffice-immersive-head-icons]]（tab 条与窗口形态）、[[onlyoffice-user-font-import]]（页面层自绘弹层形态的由来）
