# 文件格式扩展设计（打开格式从 3 种扩到 9 种）

**日期**：2026-09-11
**状态**：待实施
**目标**：应用作为一个「Office」，打开能力不能只有 docx/xlsx/pptx 三种。本次扩展
旧 Office 二进制（doc/xls/ppt）与轻量文本（rtf/txt/csv），并把散落在各处的扩展名
硬编码收敛为单一数据源；同时消灭「未知格式静默走 docx 分支」这一类隐性 bug。

---

## 1. 背景

### 1.1 现状

应用当前**只能打开** `.docx` / `.xlsx` / `.pptx`，由四处独立白名单共同保证：

| 位置 | 作用 |
|---|---|
| `EditorPage.ets:419` | 系统选择器 `fileSuffixFilters` |
| `EditorPage.ets:439` | 本地打开硬校验（`OPEN_LOCAL_EXTBAD`） |
| `EditorPage.ets:459-475` | recents 点击打开（type 映射 + 后缀白名单） |
| `smoke.ets:31` | 验收态样本白名单 |

另有一批**枚举/映射**同样是三分支硬编码，且都以「兜底到 docx」收尾：
`EditorPage.ets:185-186`（editorApp）、`:556-557`（recents type）、`30_open.js:138`
（fileType→docType）、`30_open.js:101`（验收态 type）、`DocTabHost.ets:148-160`
（主题色）。

### 1.2 为什么现在必须收敛

现状下这些兜底分支从产品路径进不去（外层闸门挡住），**没有实际 bug**。但一旦放开
白名单，故障形态是**静默**的——例如 `.xls` 会被 `30_open.js:138` 判成 `word` 家族，
把 cell 的二进制喂给 word 编辑器，全程不报错、用户只看到白屏。

本次扩展要求：**未支持的格式必须要么进不来、要么明确提示，不允许静默兜底**。

## 2. 能力边界（x2t 实测矩阵）

来源：`third_party/core/X2tConverter/src/cextracttools.cpp` 的 `GetConvertType`。

### 2.1 打开方向（任意格式 → `*.bin`）

| 家族 | 可打开 |
|---|---|
| word | docx/docm/dotx/dotm/oform、doc、rtf、txt、odt/ott/FODT |
| cell | xlsx/xlsm/xltx、xls、csv/tsv/scsv、ods/ots/FODS |
| slide | pptx/pptm/potx/ppsx、ppt、odp/otp/FODP |
| 其他 | vsdx/vssx、pdf（独立链） |

格式识别按**文件内容**（`OfficeFileFormatChecker`），扩展名仅用于消歧（ODF vs
FODT、csv/tsv）。因此**打开链必须保留原扩展名**传给 x2t（现有行为，不得改）。

### 2.2 保存方向（`*.bin` → 目标）—— 真正的边界

| 家族 | 可保存为 | 不可保存为 |
|---|---|---|
| word | docx / docm / dotx / rtf | doc、odt、txt |
| cell | xlsx / xlsm / xltx / csv | xls、ods |
| slide | pptx / pptm / potx | ppt、odp |

**结论**：旧格式与 ODF 可以「打开」，但不能「原地保存」——保存只能产出 OOXML
（或 rtf/csv）。这与官方 ONLYOFFICE 语义一致。

## 3. 范围

### 3.1 本次纳入（新增 6 种，共 9 种）

| 格式 | 家族 | 可原地保存 | 备注 |
|---|---|---|---|
| docx / xlsx / pptx | word/cell/slide | ✓ | 现有 |
| **doc** / **xls** / **ppt** | word/cell/slide | ✗ | 保存转 OOXML |
| **rtf** | word | ✓ | |
| **csv** | cell | ✓ | 保存丢格式（见 §8） |
| **txt** | word | ✗ | 保存转 docx |

### 3.2 本次不做（YAGNI）

- **ODF（odt/ods/odp）**：打开可行但保存只能转 OOXML（x2t 无 `bin→ODF` 直接通路），
  体验上"打开了却存不回"，留待后续评估
- **Visio / PDF / HTML**：收益面窄或需另一条链
- **宏格式（docm/xlsm/pptm）**：x2t 转换会丢宏，不开放
- **「下载为/导出为其他格式」**（把 docx 另存成 rtf/csv）：本次只做"打开"，不做导出
- **新建旧格式**：新建保持 docx/xlsx/pptx 三种（新文档没有理由用旧格式，且空模板
  只有这三份）

## 4. 架构：单一数据源

新建 `entry/src/main/ets/common/formats.ets`：

```typescript
export type DocFamily = 'word' | 'cell' | 'slide';
export type SaveCheck = 'zip' | 'rtf' | 'size';

export interface FormatSpec {
  ext: string;        // 源扩展名（小写）
  family: DocFamily;  // 编辑器族 → 决定 editorApp / docType
  fileType: string;   // 传给页面的 fileType：家族代表名（与 doct_bin 签名一致）
  recentType: number; // FileFormat 枚举（官方值；loginpage 据此选图标）
  saveExt: string;    // 保存产物后缀；saveExt ≠ ext ⇒ 不能原地保存
  check: SaveCheck;   // 保存产物校验：zip 头 / {\rtf 头 / 仅非空
}

const FORMATS: FormatSpec[] = [
  { ext: 'docx', family: 'word',  fileType: 'docx', recentType: 0x41,  saveExt: 'docx', check: 'zip'  },
  { ext: 'doc',  family: 'word',  fileType: 'docx', recentType: 0x42,  saveExt: 'docx', check: 'zip'  },
  { ext: 'rtf',  family: 'word',  fileType: 'docx', recentType: 0x44,  saveExt: 'rtf',  check: 'rtf'  },
  { ext: 'txt',  family: 'word',  fileType: 'docx', recentType: 0x45,  saveExt: 'docx', check: 'zip'  },
  { ext: 'xlsx', family: 'cell',  fileType: 'xlsx', recentType: 0x101, saveExt: 'xlsx', check: 'zip'  },
  { ext: 'xls',  family: 'cell',  fileType: 'xlsx', recentType: 0x102, saveExt: 'xlsx', check: 'zip'  },
  { ext: 'csv',  family: 'cell',  fileType: 'xlsx', recentType: 0x104, saveExt: 'csv',  check: 'size' },
  { ext: 'pptx', family: 'slide', fileType: 'pptx', recentType: 0x81,  saveExt: 'pptx', check: 'zip'  },
  { ext: 'ppt',  family: 'slide', fileType: 'pptx', recentType: 0x82,  saveExt: 'pptx', check: 'zip'  },
];

export function specOf(ext: string): FormatSpec | null     // 唯一判定入口；null = 不支持
export function pickerSuffixes(): string[]                 // ['.docx','.doc',...]
export function editorAppOf(family: DocFamily): string     // documenteditor / spreadsheeteditor / presentationeditor
export function needsSaveAsPrompt(ext: string): boolean    // saveExt !== ext
```

**两条设计约束**：

1. **`specOf` 返回 `null` 是不支持的唯一信号**——所有调用点必须显式处理。类型系统
   层面杜绝了"三元兜底到 docx"的写法。
2. **`check` 是三态而非布尔**：rtf 产物以 `{\rtf` 开头、csv 是纯文本，ZIP 头校验会把
   它们误判为坏产物。

### 4.1 枚举与图标依据（已核实）

- `recentType` 取官方 FileFormat 枚举值：`AVS_OFFICESTUDIO_FILE_DOCUMENT = 0x40`、
  `PRESENTATION = 0x80`、`SPREADSHEET = 0x100`（定义见
  `third_party/core/Test/Applications/FilesSort/FilesSort/CodeFile1.cs:126-150`）
- `loginpage/src/utils.js:252-297` 的 `parseFileFormat` 对 doc/xls/ppt/rtf/txt/csv
  **全有映射**（`FILE_DOCUMENT_RTF → 'rtf'` 等）
- 图标 `third_party/desktop-apps/common/loginpage/res/img/generated/formats.svg`
  含 `doc`/`xls`/`ppt`/`rtf`/`txt`/`csv` 全部符号

## 5. 打开链改动

| 改动点 | 现状 | 改为 |
|---|---|---|
| `openLocalFile` picker 过滤 | 硬编码 3 项 | `pickerSuffixes()` |
| `openLocalFile` EXTBAD 校验 | 硬编码三条件 → 静默 return | `specOf(ext) === null` → 弹提示（§7） |
| `openRecent` type→ext | 硬编码映射 + 后缀白名单 | 查表（后缀优先，type 作参考） |
| `editorUrl` 的 app/fileType | 三分支三元 | 由 `family` 派生 |
| `DocTabHost.accentColor` | 按 ext 三分支 | 按 `family` |
| `smoke.ets` 白名单 | 独立硬编码数组 | 表派生 |
| `30_open.js` m7open 验收段 | 页面自己从文件名推 type | ArkTS 拼参数时带上 type |

**关键点**：`.doc` 传给页面的是 `fileType=docx`——x2t 转出的 bin 就是 DOCY 签名，
页面/引擎只认家族；源格式只在 ArkTS 侧有意义。这样页面侧不再需要第二份格式表。

**保留不动**：打开链把源文件按**原扩展名**写入临时文件
（`EditorPage.ets:1002` 的 `open-in.<ext>`）——x2t 靠扩展名消歧（ODF/CSV 等）。

## 6. 保存链改动

`saveBinRaw`（`EditorPage.ets:862-896`）四处改动：

1. **产物后缀**：`ctx.state.ext` → `specOf(ext).saveExt`
2. **产物校验**：ZIP 硬编码 → 按 `check` 分派
3. **格式提示**：`needsSaveAsPrompt(ext)` 为真 → 写盘前弹自绘覆盖层
   「`.doc` 格式不支持保存，将以 `.docx` 格式另存」→「继续 / 取消」；取消=不保存、
   留在文档（`SAVE_BIN_AS_CANCEL`）
4. **身份演进（关键）**：`saveExt ≠ ext` 时**禁止回写原文件**——`.doc` 的 `savePath`
   指向原 `.doc`，直接覆盖会把 docx 字节写进 `.doc` 文件。所以强制走**另存为**：

```
打开 .doc → 编辑 → 保存
  → 提示「将以 .docx 另存」（首次）
  → 系统保存框（默认名 <原名>.docx，fileSuffixFilters 限定 .docx）
  → 落盘 .docx → ctx.state 演进（name/ext/savePath/saveTarget）→ tab 标题变 .docx
  → recents 补录
  → 后续保存 = 普通原地保存（提示只出现一次）
```

**另存为对话框后缀限制**：`doSaveAs`（`:497-560`）现有实现未设 `fileSuffixFilters`，
用户手改后缀会产生"名实不符"文件（叫 `.doc` 实为 docx 字节）→ 按 `saveExt` 限定。

**异步受理模式**：提示弹框需等待用户输入，而 `save:bin` handler 是同步返回
（`EditorPage.ets:240-244`）——沿用现有 `awaitingSaveAs` 的成熟模式：弹框在途时
`save:bin` 先返回 `'true'`（受理），用户确认后异步继续转换/另存；新增状态字段
`awaitingFormatConfirm`，并在守卫超时兜底（`:1517`，现豁免 `awaitingSaveAs`）
里同等豁免。

**守卫路径**：未保存关闭守卫的「保存」也走 `asc_Save → save:bin → saveBinRaw`，
自动继承同一逻辑（含提示与豁免），无需单独处理。

**打印链不受影响**：`bin2pdf` 与源格式无关。

## 7. 显式拒绝路径

| 场景 | 处理 |
|---|---|
| picker 选文件 | 过滤列表不含不支持格式 → 用户看不到 |
| 后缀缺失 / 畸形 uri | `specOf` 返回 null → 弹「暂不支持该格式：<文件名>」 |
| recents 历史记录 | 同上，走同一函数 |

形态：新增通用 `showFormatNotice(text)` **自绘覆盖层**（单按钮「知道了」）——复用
关闭守卫弹框的 Stack 模式（系统 `CustomDialog` 真机点击失效，已有先例
`EditorPage.ets:1456-1483`），与守卫弹框互斥（不叠加）。

## 8. 已知限制（随包文档需注明）

- **csv 保存丢格式**：cell 的合并单元格/颜色/列宽无法写入纯文本 CSV（官方同样如此）
- **txt 打开为纯文本导入**：无格式概念，保存只能转 docx
- **doc/xls/ppt 保存转格式**：用户确认后另存为 OOXML，原文件不动
- **旧格式保真度**：取决于 x2t 转换质量，复杂排版/宏/嵌入对象可能有差异——验收时
  以样本文件如实记录

## 9. 测试与验证

### 9.1 样本入库

| 格式 | 来源（仓库现成真实文件） | 体积 |
|---|---|---|
| doc | `third_party/core/DesktopEditor/raster/Jp2/openjpeg/openjpeg-2.4.0/src/bin/mj2/mj2_to_metadata_Notes.doc`（Word 10.0 生成） | 34KB |
| xls | `third_party/core/Test/Applications/AVSOfficeEWSEditorTest/AVSOfficeEWSEditorTest/TestFiles/Auto_color_as_index.xls` | 14KB |
| ppt | `third_party/core/Common/cfcpp/test/data/src/ex.ppt` | 8KB |
| rtf / txt / csv | 自造小样本 | <1KB |

落地：`entry/src/main/resources/rawfile/onlyoffice/smoke/samples/`，由
`build_editors_ohos.py` 的 smoke 段拷贝。

### 9.2 回归 case（`tests/cases.tsv` 追加）

- 打开 ×6：`open-doc` / `open-xls` / `open-ppt` / `open-rtf` / `open-txt` / `open-csv`
- 保存 ×3：`save-doc`（验提示+另存 docx）/ `save-rtf`（原地）/ `save-csv`（原地）
- **现有 10 case 必须全绿**（docx/xlsx/pptx 打开保存不得退化）

### 9.3 真机矩阵（1.6:33363）

1. 9 种格式逐个打开：渲染正确、编辑器族正确（不出现白屏/错编辑器）
2. doc/xls/ppt/txt：编辑 → 保存 → 提示 → 另存 → tab 标题更新 → 再保存不再提示
3. rtf/csv：编辑 → 保存 → 原地回写 → 重开内容正确
4. recents 列表：新格式条目图标正确
5. 打印：抽验 1 个新格式（bin2pdf 与源格式无关）
6. 不支持格式：构造一个 `.odt` 直塞沙箱 → 确认弹出提示而非静默

## 10. 风险

| 风险 | 等级 | 应对 |
|---|---|---|
| 旧格式转换保真度差 | 中 | 验收时逐样本记录差异，如实上报；不做超出 x2t 能力范围的承诺 |
| `.doc` 保存路径（提示+另存+身份演进）逻辑复杂 | 中 | 单测式真机矩阵（§9.3-2）覆盖首次/二次保存、取消、守卫路径 |
| rtf/csv 产物校验放宽导致坏产物漏过 | 低 | `check` 三态仍做头校验（rtf）；csv 仅判非空（纯文本无稳定头） |
| 回归时间增长（10 → 19 case） | 低 | 新 case 用 `terminal` 判据提前结束；必要时按组跑 |
