# 用户自导入字体（User Font Import）设计

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户从设备里选一个字体文件（.ttf/.otf）导入应用；导入后该字体出现在编辑器字体下拉中并可用于排版渲染，重启应用或新开文档后依然可用。

**Architecture:** 三段式。① **导入段（ArkTS，一次性）**：picker 选文件 → 解析 sfnt/name 表得到字体族名与样式 → 落沙箱 `filesDir/userFonts/` 并更新清单 `index.json`。② **注册段（页面加载时，ascshim）**：编辑器页 URL 携带清单（base64 参数）→ `20_bridge.js` 在注入 `__fonts_files`/`__fonts_infos` 时把用户字体行**追加**进去，`09_fonts.js` 把用户字体并入装填清单。③ **供给段（拦截层）**：字体字节走新前缀 `onlyoffice/userfonts/<id>`，由 `rawfileLoader.ets` 读沙箱供给，XOR 前 32B 与既有系统字体桥同构。注册行名**直接采用字体内部 name 表的 family 名**，天然满足引擎「注册行名 == face 内部名」契约。

**Tech Stack:** ArkTS（`@kit.CoreFileKit` picker / fileIo）、ascshim 注入层（JS 段）、ArkWeb `onInterceptRequest`、ONLYOFFICE sdkjs 字体链（`__fonts_files` / `__fonts_infos` / `g_font_files` / `g_fonts_streams`）。

---

## 1. 背景

### 1.1 现有字体链（事实，含证据）

| 环节 | 事实 | 证据 |
|---|---|---|
| 字体注册表 | `__fonts_files`（文件名数组）、`__fonts_infos`（注册行 `[行名, idxR,0, idxI,0, idxB,0, idxBI,0]`）、`__fonts_ranges`（字符回退表）由 ascshim **在页面加载早期注入**，sdk-all.js 的 `checkAllFonts()` 消费后**删表** | `20_bridge.js:1-14`；`build_editors_ohos.py:203-287` |
| 字节供给 | 装填式：XHR 取字节 → XOR 前 32B 还原 → 等 `AscFonts.g_font_files` 就绪后 push `g_fonts_streams` + `SetStreamIndex` + `Status=0` + `CreateNativeStreamByIndex` | `09_fonts.js:38-108` |
| 系统字体桥 | `http://localhost/onlyoffice/systemfonts/<name>` → NAPI 读 `/system/fonts/<name>` → ArkTS 侧 XOR 前 32B | `rawfileLoader.ets:22-47`、`convertershell.cpp:185-259` |
| 随包字体 | `rawfile/onlyoffice/fonts/*.ttf`，构建期 `pre_xor_font` 加密；清单与元数据全部构建期静态生成 | `build_editors_ohos.py:92-145, 555-565` |
| **名称契约** | 引擎 wasm libfont 取 face 内部 name 表 ID1/ID16 作为 family，**必须等于注册行名**，否则渲染槽匹配失败 → **整 run 空白**（连拉丁一起） | `build_editors_ohos.py:354-358, 389-408` |
| UI 数据源 | 字体下拉经 `sync_InitEditorFonts`（已 wrap：去重/族归一/剔内部行） | `30_open.js:806-883` |
| 文件选择器范本 | 「选任意文件 → 读字节 → 写沙箱」现成 | `EditorPage.ets:926-969`（`doPickFile`） |
| 同步桥 | `window.AscNative._call(name, args)` 同步返回 string（`registerJavaScriptProxy`） | `ascBridge.ets:2-46` |
| 欢迎页侧栏 | `.tool-menu` 下 `.menu-item > a[action=...]`；已有 DOM 注入范式（隐藏/改写） | `40_save.js:419-464` |

### 1.2 由此得出的三个结论

1. **元数据必须早于 sdk 加载就位**（`checkAllFonts()` 消费后删表，事后无法追加）→ 用户字体清单必须走**页面加载时就同步可得**的通道。选 **URL 参数**（`editorUrl()` 已用同法传 `m7auto`/`m7key` 等，机制确定、零新依赖、不依赖同步 XHR 或桥的注入时机）。
2. **字节可以异步**（装填链本身就是异步的：预取 + 轮询装填）→ 走既有装填模式即可。
3. **行名取自字体内部名 → 契约自动满足**，无需构建期的 `rewrite_font_name` 同款重写。

### 1.3 引擎约束（实施中实测确认，限定 1.2 结论 1 的适用范围）

1.2 的结论 1 只覆盖**后半程**。字体真正生效要接通两段，各有独立的表与时机：

| 段落 | 表 / 对象 | 时机 | 由谁接通 |
|---|---|---|---|
| 名字 → 文件 | `g_fontSelections.List`（构建期内嵌的字体名字典） | **运行时**，须在 `CFontSelectList.Init()` 之后追加 | 20_bridge 字典段（§4.5） |
| 文件 → 字节 | **预装填**：并入 `__fonts_files` / `g_fonts_streams` 清单 | 页面加载期，`g_font_files` 建好后轮询触发 | 09_fonts 装填段（字节走 `userfonts/` 前缀=**加密态**，`xorDecode` 还原） |
| 字形 → 渲染 | 引擎按 run 的 fontName 取字体 | — | — |

- **字体名解析不查 `__fonts_infos`**：`g_fontApplication.GetFontFileWeb` → `FD_FontDictionary.GetFontIndex(oSelect, g_fontSelections.List, ...)` 遍历的是 `g_fontSelections.List`，该表由 `CFontSelectList.Init()` 从构建期静态数据（类内嵌 base64 字典）建立。用户字体名不在其中 → **静默落到默认 Arial**。真机探针实证：`FontPicker: LXGW WenKai => Arial`。修法 = 等 `IsInit` 后补条目（从表内现成对象复制、只改 `m_wsFontName`——`GetPenalty` 要读 Panose/CodePage）+ 清 `FontPickerMap`（解析结果按名缓存，失败会一直沿用）。
- **字节走预装填、与随包字体同批**：引擎按 run 取字形时就需要有流；只留引擎按需链时其请求（`userfont(fonts) hit`）晚于选字 → 整段中文落回宋体。故并入装填清单（§4.5）。字节形态：装填链要**加密态**（`userfonts/` 前缀返回，`xorDecode` 异或前 32B 还原）；而 `fonts/` 前缀回退给的是**明文**（FreeType 直接吃）——**两者相反，取错即毁字体头且日志无异常**（`FONT_WARM_FILLED status=0` 照常打印）。曾据"三轮对比"（无用户字体 PASS 17s｜仅 297KB PASS 20s｜+24.7MB 超时）把 open-ppt 超时归因于装填阻塞并改为按需——2026-09-18 复测**证伪**（立即装填 + 24.7MB：open-ppt PASS 27s，`FONT_WARM_FILLED ... bytes=24744500` 确实发生、耗约 14ms）。
- **判据只能是引擎的答案**：`FONT_WARM_FILLED` 只证明"字节喂进去了"，下拉里有名字只证明"注册表有这一行"。要证明字体真被用上，用引擎自带探针 `window.onLogPickFont`（`m7auto=1` 时安装，打印 `FontPicker: <请求名> => <命中名>`），或做像素级字形对比（同一段文字换字体对照——不同大小的文字"对比"会得出错误结论）。

## 2. 目标与非目标

**目标（本次）**
- 欢迎页侧栏新增「导入字体」入口；点选设备上的 `.ttf` / `.otf` 文件完成导入。
- 导入后**新打开的文档**（含新建）中，字体下拉出现该字体，可用于排版且**渲染正确**（非方块、非空白）。
- 导入结果持久化：重启应用后仍可用。

**非目标（本次不做，YAGNI）**
- 字体管理界面（列表/删除/重命名）——用户已明确只要「导入 + 可用 + 持久化」。
- 已打开文档的**热生效**（改注册表需重走页面初始化；见 §7 风险 4）。
- `.ttc`（字体集合）——需要 face 索引选择交互，v1 拒绝并如实提示。
- 把用户字体设为默认字体、或注入 `__fonts_ranges` 参与 CJK 回退（用户字体是**被显式选用**的字体，不是回退目标）。

## 3. 数据流

```
【导入】欢迎页侧栏「导入字体」
   AscNative._call('execCommand', ['font:import'])          ← 40_save.js 注入项点击
   → EditorPage.onTabCommand('font:import')
   → userFonts.importViaPicker(ctx)                         ← common/userFonts.ets
        DocumentViewPicker.select('字体文件|.ttf,.otf')       ← 单元素+逗号分隔（picker 坑）
        → readFileBuf(uri) → sfnt.parse(u8)                 ← common/sfnt.ets
        → 校验（见 §5）→ sha1 去重
        → 写 filesDir/userFonts/<id>.<ext> + 更新 index.json
   → 结果以页面提示回执（成功 N 个 / 失败原因）

【使用】打开任意文档（含新建）
   EditorPage.editorUrl() 拼 &lsofonts=<base64(清单)>
   → 20_bridge.js：解析参数 → __fonts_files.push(id)
                            → __fonts_infos.push([family, idx,0, idx,0, idx,0, idx,0])
   → 09_fonts.js：装填清单 = 静态 IDS + 用户字体 id
        XHR http://localhost/onlyoffice/userfonts/<id>
   → rawfileLoader.ets：userfonts/ 前缀 → 读沙箱 → XOR 前 32B → font/ttf
   → XOR 还原 → g_fonts_streams 装填 → 下拉可选、渲染命中
```

## 4. 组件设计

### 4.1 `entry/src/main/ets/common/sfnt.ets`（新增）

**职责**：纯函数解析 sfnt 容器，输出引擎注册所需的元数据。无 IO、无 ArkTS 状态。

**接口**
```ts
export interface SfntInfo {
  family: string;      // name 表 ID16 > ID1，首选 Windows(3,1,0x409)，回退 Unicode(0,*) / Mac(1,0)
  subfamily: string;   // name 表 ID17 > ID2，同优先级
  weight: number;      // OS/2.usWeightClass；缺失 → 400
  italic: boolean;     // head.macStyle bit1 或 OS/2.fsSelection bit0
  isVariable: boolean; // 存在 'fvar' 表
  isCff: boolean;      // sfntVersion == 'OTTO'
}
export function parseSfnt(u8: Uint8Array): SfntInfo | null;  // null = 非 sfnt / 结构非法
```
解析要点：tag（`0x00010000` / `OTTO` / `true` / `ttcf`）→ 表目录 → `name`/`OS/2`/`head`/`fvar` 表切片；所有偏移读取前做边界检查（长度不足即返回 null，不抛异常）。

### 4.2 `entry/src/main/ets/common/userFonts.ets`（新增）

**职责**：导入流程、清单读写、URL 参数编码。

**接口**
```ts
export interface UserFont { id: string; file: string; family: string; subfamily: string; weight: number; italic: boolean; }
export function listFonts(): UserFont[];            // 读 filesDir/userFonts/index.json；损坏 → 空数组
export function importViaPicker(ctx: common.UIAbilityContext): Promise<ImportResult>;
export function encodeUrlParam(): string;           // 清单 → URL 参数值；空清单返回 ''
```
**落点**：`filesDir/userFonts/`，`index.json` 顶层 `{"v":1,"fonts":[...]}`；字体文件 `<id>.ttf|.otf`，`id` = 文件字节 SHA-256 前 16 位十六进制（同一文件重复导入视为"已存在"，直接返回成功不重复写）。
**URL 编码**：URL 参数 `lsofonts` = `base64(JSON.stringify(数组))`，元素为紧凑数组 `[id, family, weight, italic?1:0, subfamily]`。上限 **32 项**（超出截断 + 控制台告警，不静默）。

### 4.3 `entry/src/main/ets/pages/EditorPage.ets`（改）

1. `editorUrl()`（:244-279）：末尾追加 `+ (u.length > 0 ? '&lsofonts=' + u : '')`，`u = userFonts.encodeUrlParam()`（与 `m7key` 等既有参数并列）。
2. `onTabCommand()`（:292 起）：新增分支 `if (cmd === 'font:import') { this.importUserFonts(ctx); return 'true'; }`——**欢迎页与文档页都可达**（入口在欢迎页，命令由 ctxtab 路由）。
3. 新增私有方法 `importUserFonts(ctx: DocTabCtx)`：调 `userFonts.importViaPicker`，完成后把结果写回页面（`ctx.controller.runJavaScript`，`DocTabCtx.controller: webview.WebviewController`）触发页面提示；失败原因映射为中文文案。
4. 导入成功后**不做任何 tab 重载**（避免未保存内容风险）：提示文案固定为「已导入 N 个字体，新打开的文档生效」。

### 4.4 `entry/src/main/ets/common/rawfileLoader.ets`（改）

新增前缀 `const USER_FONT_PREFIX = 'onlyoffice/userfonts/';` 与函数 `loadUserFont(rel, log)`，**逐句照搬 `loadSystemFont`（:30-47）**，差别仅在数据源：读 `filesDir/userFonts/<rel>`（fileIo），XOR 前 32B 用同一 `FONT_GUID`。分发处（:234-245 一类的 if 链）加分支，MIME 用 `font/ttf`。文件名仅纯名（含 `/`、`\`、`..` 一律拒绝），与系统字体同款防穿越。

### 4.5 ascshim（改 3 个段）

| 段 | 改动 |
|---|---|
| `20_bridge.js` | 在 `window["__fonts_files"] = ...` / `__fonts_infos` 注入**之后**（同名 IIFE 内、sdk 加载前），解析 URL 参数 `lsofonts`：逐项 `__fonts_files.push(id)` + `__fonts_infos.push([family, idx, 0, idx, 0, idx, 0, idx, 0])`（四槽同索引 = 单文件通吃，先例 `OpenSymbol` 行）。base64/JSON 解析包 try/catch，失败仅告警不影响启动。 |
| `09_fonts.js` | `IDS` 由「静态常量」改为「静态 8 项 + URL 参数中的用户字体 id」；`IS_SYS` 不含用户字体；预取 URL 三分支：用户字体 → `http://localhost/onlyoffice/userfonts/<id>`（`../../../../fonts/` 兜底对用户字体不适用，直接不给兜底）。装填逻辑（`try_fill`/轮询/XOR）**一字不改**。 |
| `40_save.js` | 新增段「欢迎页侧栏『导入字体』」：`MutationObserver` + 幂等注入，**clone** 已隐藏的 `.tool-menu a[action="templates"]` 的父 `.menu-item`（保官方样式），改 `a` 的文本为「导入字体」、`action="lsofonts"`、清除 `display:none` 后插入 `.tool-menu` 末尾；点击处理（事件委托，`preventDefault`）→ `AscNative._call('execCommand', ['font:import'])`。自检登记 `__lsoShim.push('userfonts')`。 |

### 4.6 构建与自检

- `make_ascshim.py`：段顺序不变（新增逻辑在既有段内，不新增段文件）。
- `00_boot.js` 的 `EXPECT` 自检表加 `userfonts: 'home'`。
- 无需改 `build_editors_ohos.py`（用户字体不参与构建期生成）。

## 5. 边界与拒绝策略

| 情形 | 行为 |
|---|---|
| 非 sfnt 文件（魔数不符） | 拒绝，提示「不是有效的字体文件」 |
| `.ttc` 集合 | 拒绝，提示「暂不支持字体集合（.ttc），请使用单个 .ttf/.otf」 |
| `fvar`（可变字体） | 拒绝，提示「暂不支持可变字体」——引擎对 VF 无静态实例化路径 |
| `family` 名与**现有注册行**重名（含随包/系统/已导入） | 拒绝，提示「字体『X』已存在」——重名将导致渲染槽抢占 |
| 同一文件（id 相同）重复导入 | 视为成功，提示「已存在，跳过」 |
| 清单超 32 项 | 导入仍成功，但超出部分不注册；提示「已达上限 32，多余的字体本次不生效」 |
| name 表缺失 family（如仅有 ID4 全名） | 用 ID4 兜底；仍无 → 用文件名（去扩展名） |
| 沙箱写入失败 / 磁盘满 | 提示「导入失败（写入错误）」，控制台 `LSO_UFONT_ERR` |

## 6. 错误处理与日志

- **JS 侧**：`LSO_UFONT_IDS n=<总数> user=<个数>`（09_fonts 解析 URL 参数）、`LSO_UFONT_REG n=<个数> ok`、`LSO_UFONT_DICT added=<n> total=<n>`（20_bridge 注册 / 补字典）、装填沿用既有 `FONT_WARM_BYTES` / `FONT_WARM_FILLED id=<id> bytes=<n>` 标签（不另造）。
- **ArkTS 侧**：`LSO_UFONT_IMPORT ok=<n> skip=<n> err=<原因>`；`arkLog` 统一出口（落 `web_console.txt`）。
- 任一环节失败**不得阻断**页面加载与既有字体：桥解析失败 → 跳过用户字体；单字体读取失败 → 该字体不装填，其余照常。

## 7. 验证方案

**真机（1.6:33363 / tablet；PC 形态另在 1.5 复验一次入口可见性）**

1. 准备样本：一个中文 `.ttf`（如 Noto Sans SC Regular）、一个拉丁 `.otf`（glyf 或 CFF 各一）、一个 `.ttc`、一个非字体文件（.txt 改名）。
2. 欢迎页侧栏出现「导入字体」；点击 → 系统 picker 只列 `.ttf/.otf`（后缀过滤坑：必须是单元素 `'描述|.a,.b'`）。
3. 导入中文 ttf → 提示成功；**新开**新建文档 → 字体下拉出现该字体名 → 选中 → 输入中文 → 截图确认**渲染正确**（非方块/非空白）。
4. 拉丁 otf → 同上；若 CFF 轮廓字体渲染异常，按 §5 升级为拒绝（记录实测结论）。
5. `.ttc` 与非字体文件 → 明确被拒 + 提示正确。
6. 杀掉应用重开 → 字体仍在（持久化）。
7. 重复导入同一文件 → 「已存在，跳过」，不产生重复文件（`ls filesDir/userFonts` 核对）。
8. 回归：既有随包字体（宋体/黑体/仿宋/楷体/OpenSymbol）与系统字体桥渲染不变；三格式打开/保存/打印链不受影响。
9. 日志判据：`LSO_UFONT_REG`、`LSO_UFONT_FILLED`、字体下拉可见性靠截图与 `FONT_PICK` 探针（`09_fontpick.js`，`m7auto=1` 门控）。

**判定"渲染正确"的硬标准**：文档里该 run 的字符**有字形**（非空白/非方块），且与字体设计字形一致（截图比对字形特征，不只看有没有字）。

## 8. 风险与未决

1. **URL 长度**：32 项 × ~45B ≈ 1.5KB + base64 膨胀 → ~2KB。ArkWeb 对 URL 长度的实际上限未实测；超过 8KB 时应改为「URL 只带清单版本号 + 同步 XHR 或桥取数」的二级方案（本轮不实现，触发再评估）。
2. **内存**：装填链是**全量预取**（每个中文字体约 10MB 进 wasm 内存）。用户导入多个大字体将线性抬升内存；v1 不设硬上限，文档记录代价，异常时按需加限制。
3. **字体下拉缩略图**：官方为随包字体生成精灵图（`make_fonts_sprites`），用户字体无预览 → 该行缩略图可能空白或回退默认。**可接受**（不影响选用与渲染），如实测显示异常再处理。
4. **热生效**：`checkAllFonts()` 消费后删表，运行中追加注册行需重建引擎字体索引（`g_map_font_index` 等内部结构），风险高、收益低（用户导入是低频操作）→ 本轮明确不做；导入后提示「新打开的文档生效」。
5. **CFF 轮廓**：`.otf`（`OTTO`）在精简 wasm FreeType 下的支持度未实测；验证矩阵已含该用例，实测失败则收窄为仅 `.ttf`（§5 加一行拒绝理由）。

## 9. 交付物清单

| 文件 | 类型 |
|---|---|
| `entry/src/main/ets/common/sfnt.ets` | 新增 |
| `entry/src/main/ets/common/userFonts.ets` | 新增 |
| `entry/src/main/ets/common/rawfileLoader.ets` | 改（新前缀分支） |
| `entry/src/main/ets/pages/EditorPage.ets` | 改（URL 参数 + `font:import` 命令 + 提示回写） |
| `entry/src/main/ets/common/ascBridge.ets` | 改（`font:import` 分派） |
| `scripts/onlyoffice/desktop/src/20_bridge.js` | 改（注册行追加） |
| `scripts/onlyoffice/desktop/src/09_fonts.js` | 改（装填清单并入用户字体） |
| `scripts/onlyoffice/desktop/src/40_save.js` | 改（欢迎页入口注入） |
| `scripts/onlyoffice/desktop/src/00_boot.js` | 改（自检清单登记） |

验证脚本（可选，若纳入回归框架）：`tests/regression.sh` 增用户字体 case（导入后字体下拉含目标名）。
