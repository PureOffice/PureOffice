# 字体管理弹层（Font Manager）设计

**Goal:** 欢迎页侧栏的「导入字体」升级为「字体管理」——点击弹出弹层，可查看已导入字体清单、导入新字体、删除已有字体。

**Architecture:** 弹层是**页面层 Stack 自绘覆盖层**（第四个，与关闭守卫框/密码框/格式框同构）。欢迎页 web 只把点击转成 `execCommand`（现状机制），其余全在 ArkTS 侧：直接读沙箱 `userFonts/index.json` 渲染列表，删除走新增的 `removeFont()`。不改 `index.json` 格式，不新增 web↔ArkTS 数据通道。

**Tech Stack:** ArkTS（`@kit.CoreFileKit` picker / fileIo）、EditorPage 页面级 `@State` 驱动的覆盖层、既有 `common/userFonts.ets`。

---

## 1. 背景

### 1.1 现状（事实）

- 入口：欢迎页侧栏 `40_save.js:469` 的 3.11 段注入，clone 官方「模板」项，文案「导入字体」，点击 → `AscNative._call('execCommand', ['font:import'])`。
- 处理：`EditorPage.onTabCommand` → `importUserFonts()` → 起系统 picker → `userFonts.importViaPicker()` → 落沙箱 `filesDir/userFonts/` + 写 `index.json`，结果用 toast 回报。
- 中间**没有任何界面**：用户看不到已导入什么，也无从删除（删了字体只能卸载应用）。

### 1.2 形态约束（决定实现，非选项）

ArkUI 弹层在本项目**不可用**，已两次踩坑（`EditorPage.ets:2038` 注释为证）：

- `AlertDialog`：只有两 action 键，**没有取消键**；
- `CustomDialog`：**真机点击失效** —— 按钮 `onClick` 不触发、事件未达 ArkTS（uinput + 手指双证）。

故项目内所有弹层都是页面层 `Stack` 覆盖层全量自绘，`onClick` 全在自己手里、零系统弹层依赖。本设计沿用该形态。

### 1.3 生效时机（既有语义，本设计继承）

用户字体的名字表在**页面加载时**经 URL 参数（`lsofonts`，`EditorPage.editorUrl` → `encodeUrlParam`）注册进引擎，之后表即被删。故：

- 导入 → **新打开的文档**可见该字体；
- 删除 → **新打开的文档**不再带该字体；**已打开的文档不受影响**（其页面早已完成注册，字体字节也已装填）。

删除的后果需要向用户讲清：字体文件没了，但文档里的字体名还在 → 再打开时该 run 回退成宋体（静默回退，与 [[onlyoffice-fandol-fangsong-fix]] 同一失效模式）。

## 2. 目标与非目标

**目标**
- 弹层内看到已导入字体的**清单**（家族名、样式、文件大小）；
- 弹层内完成**导入**（并入原入口行为）；
- 可**删除**单个字体（就地二次确认）；
- 空态、满额（32 个）有明确提示。

**非目标**
- 字形预览（每项用该字体渲染示例文字）—— v1 不做；
- 重命名、排序、分组；
- 管理内置/系统字体（内置字体不可删，列进来只会误导）；
- 导入时间戳（需改 `index.json` 格式，YAGNI）。

## 3. 交互设计

### 3.1 入口

- 侧栏项文案「导入字体」→「**字体管理**」，action 属性保持 `lsofonts`、注入 id 保持 `lso-import-font`（仅文本与点击回调的命令名变化，clone/替换文本逻辑不动）。
- **位置：插到「关于」项之前**（官方项 `a[action="about"]`，`panels.js:85`）；找不到该项则退回追加到 `.tool-menu` 末尾（位置是观感问题，不值得为它中断注入）。
- 点击 → `AscNative._call('execCommand', ['font:manage'])`。
- `EditorPage.onTabCommand`：`'font:import'` 分支替换为 `'font:manage'` → `openFontManager()`（原 `importUserFonts()` 保留，改为由弹层内的导入按钮调用）。

### 3.2 弹层布局

```
┌────────────────────────────────────────────┐   ← 蒙层：半透明黑，点击=关闭
│  ┌──────────────────────────────────────┐  │
│  │  字体管理                         ✕  │  │   ← 标题栏
│  ├──────────────────────────────────────┤  │
│  │  LXGW WenKai                 [ 删除 ]│  │   ← 列表项（可滚动）
│  │  Regular · 24.7 MB                   │  │
│  │  ──────────────────────────────────  │  │
│  │  NotoSansCFF                 [ 删除 ]│  │
│  │  Regular · 290 KB                    │  │
│  ├──────────────────────────────────────┤  │
│  │            [   导入字体   ]          │  │   ← 主按钮
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘
```

- 标题行：左「字体管理」+ **右上角 ✕ 关闭**（与蒙层点击同效）。显式出口不能省——只靠点空白处关闭是常见疑惑点。
- 列表项主行 = `family`；副行 = `subfamily · <大小>`（`subfamily` 为空时只显示大小）。
- 文件大小现取：`fs.statSync(dir + '/' + file).size`。格式化规则（**1024 进制**）：`< 1024` → `N B`；`< 1 MB` → `N KB`（整数）；否则 → `N.N MB`（一位小数）。例：297428 → `290 KB`；24744500 → `23.6 MB`。stat 失败（文件缺失）显示 `—`，不阻断渲染。
- 列表超出高度可滚动（`List` + `Scroll`）；上限 32 项，不做分页。
- 空态：列表区居中显示「还没有导入字体」。
- 满额（32）：导入按钮禁用 + 下方小字「已达上限 32 个」。禁用态判定在打开弹层与每次导入后刷新。

### 3.3 删除交互（系统原生 AlertDialog）

点「删除」→ **系统原生 `AlertDialog`**：标题「删除字体」、正文「将删除「<family>」。用该字体排版的文档再打开时会回退为宋体。」、主键「取消」、次键「删除」（红字）。

- **为什么用原生弹窗而不是列表内确认条**：删除是不可逆动作，值得一个明确的模态确认；而且这里**正好只要两个键**，落在 `AlertDialog` 的能力内。项目里"原生弹层别用"的记录只针对 `CustomDialog` 的**自定义按钮**（真机点击失效）和 `AlertDialog` 的**键数上限**（三键场景才不够）——不等于原生弹窗整体不可用。
- 取消 → `FONT_MGR_DEL_CANCEL`（无副作用）；确认 → `removeFont()`。
- 删除成功 → 重新 `listFontItems()` 刷新、toast「已删除「<family>」，新打开的文档将不再包含该字体」。
- 删除失败 → toast 报错，列表不变。

### 3.4 导入

- 点「导入字体」→ **两段分明**：`pickFontFile()`（系统 picker 在途，按钮文案「选择字体文件…」）→ 选定后 `importFontFile()`（读+校验+落盘，文案「导入中…」）→ 完成后清态、`refreshFontRows()` 刷新、toast 结果。
  拆两段是为了**按钮文案如实**：合成一段时按钮只能一路显示「导入中」，而那段里用户其实还停在系统选择器里，什么都没开始导。取消选择 → toast「已取消导入」。
- picker 是系统模态，弹层留在其后，返回后继续。

## 4. 组件设计

### 4.1 `common/userFonts.ets`（改）

新增导出：

```ts
/**
 * 删除一个已导入字体：删文件 + 从清单移除 + 写回。
 * 文件已不存在视为删除成功（清单与磁盘以清单为准收敛，避免"删不掉的幽灵条目"）。
 * 清单写回失败 → 返回失败且**不删文件**（先写清单后删文件，保证任一步失败都可重试）。
 */
export function removeFont(filesDir: string, id: string): ImportResult
```

实现要点：
- 先 `listFonts()` 找到条目（找不到 → 失败「字体不存在」）；
- 写回移除后的清单（`writeIndex`），成功后才 `fs.unlinkSync` 文件；
- `unlinkSync` 抛错时忽略「文件不存在」（`ENOENT`），其余错误 → 失败并回报。

### 4.2 `pages/EditorPage.ets`（改）

- **状态字段**：`fontMgrOn: boolean`、`fontMgrRows: FontRow[]`、`fontMgrConfirmId: string`、`fontMgrBusy: boolean`。
  `FontRow` = `{ id: string; family: string; sub: string; size: string }`（**尺寸已格式化**，ArkTS 侧格式化一次，UI 只渲染字符串）。
- **方法**：`openFontManager()`（刷新列表 + 置 `fontMgrOn`）、`closeFontManager()`、`refreshFontRows()`、`fontMgrDelete(id)`、`fontMgrImport()`。
- **UI**：顶层 `Stack` 末尾追加条件渲染 `if (this.fontMgrOn) { ... }`，与既有关闭守卫/密码/格式覆盖层同一层级、同一写法。
- 日志：`FONT_MGR_OPEN n=<项数>`、`FONT_MGR_DEL id=<id> ok=<bool>`、`FONT_MGR_CLOSE`（`arkLog`，落 `web_console.txt`）。
- 弹层在**欢迎页**触发（唯一入口）；技术上页面级状态驱动，与 tab 无关。

### 4.3 `desktop/src/40_save.js`（改）

3.11 段两处：文案 `'导入字体'` → `'字体管理'`；`execCommand` 命令名 `'font:import'` → `'font:manage'`。其余（clone 模板项、递归找文本节点、图标保留）不动。

## 5. 边界与错误处理

| 场景 | 行为 |
|---|---|
| 清单缺失/损坏 | `listFonts` 返回 `[]` → 空态（既有语义） |
| 字体文件被外部删掉（hdc rm 等） | 列表显示 `—` 大小；删除时 ENOENT 视为成功，清掉清单项 |
| 删除清单写回失败 | 报错、不删文件、列表不变（可重试） |
| 导入中重复点按钮 | `fontMgrBusy` 期间按钮禁用 |
| 已达上限 32 | 导入按钮禁用 + 提示行；已有字体的删除不受影响 |
| 删除后立刻新建文档 | 新文档不带该字体（URL 参数在打开文档时重新编码） |

## 6. 验证方案

真机 1.6（MatePad 11.5 S / tablet）。判据取自 `web_console.txt`（`arkLog` 出口）。

1. 导入 2 个字体（`LXGWWenKai-Regular.ttf` 24744500 B + `zz-noto-cff.otf` 297428 B）→ 打开「字体管理」：`FONT_MGR_OPEN n=2`，列表两项、大小分别显示 `23.6 MB` / `290 KB`。
2. 删除其中一个 → 就地确认条出现 → 取消：列表不变；再删除 → 确认：`FONT_MGR_DEL id=<id> ok=true`，列表剩 1 项。
3. 删除后新建文档 → 字体下拉**无**被删字体、**有**剩下的那个。
4. 全删 → 空态「还没有导入字体」；再导入 → 列表恢复。
5. 边界：`hdc shell rm` 掉沙箱字体文件后打开弹层 → 该项大小显示 `—`，删除成功（清单收敛）。
6. 回归：`tests/regression.sh` 全量（确认弹层没影响打开/保存链）。

## 7. 风险

- **低**。弹层是纯 UI + 两个文件系统调用，不触碰字体注册与渲染链；`removeFont` 的写序（先清单后文件）保证失败可重试。
- 观感与官方 web 风格不同 —— 既有三个弹层同样如此，属既有取舍。

## 8. 交付物清单

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/common/userFonts.ets` | 新增 `removeFont()` |
| `entry/src/main/ets/pages/EditorPage.ets` | 弹层 UI + 状态字段 + 4 个方法；`font:manage` 命令分支 |
| `scripts/onlyoffice/desktop/src/40_save.js` | 入口文案与命令名 |
| `scripts/onlyoffice/tests/cases.tsv` | 不加 case（弹层需手指交互，回归框架判不了；验收按 §6 手工走） |

相关：[[onlyoffice-user-font-import]]（字体链三段契约与判据）、[[onlyoffice-fandol-fangsong-fix]]（静默回退宋体的同一失效模式）。
