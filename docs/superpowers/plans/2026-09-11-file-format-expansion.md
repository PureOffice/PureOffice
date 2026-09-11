# 文件格式扩展（打开 3→9 种）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让应用能打开 doc/xls/ppt/rtf/txt/csv（共 9 种），并把散落在五处的扩展名硬编码收敛为单一数据源，消灭「未知格式静默走 docx 分支」的隐患。

**Architecture:** 新建 `entry/src/main/ets/common/formats.ets` 作为唯一数据源（9 行格式表 + `specOf()` 唯一判定入口，返回 `null` = 不支持）。打开链/保存链/recents/主题色/验收白名单全部改为查表；不能原地保存的格式（doc/xls/ppt/txt）走「提示 → 另存为」并禁止回写原文件。

**Tech Stack:** ArkTS（HarmonyOS SDK 6.1.0 / API 23）、ascshim 页面 JS、x2t 转换器（native）、hvigor 构建、hdc 真机部署。

**设计依据：** `docs/superpowers/specs/2026-09-11-file-format-expansion-design.md`（能力边界来自 x2t `GetConvertType` 实测：打开宽、保存窄）。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `entry/src/main/ets/common/formats.ets` | 格式表 + 判定/派生/校验函数（唯一数据源） | **新建** |
| `entry/src/main/ets/pages/EditorPage.ets` | 打开链查表化、保存链产物后缀与校验、格式提示覆盖层、另存身份演进 | 改 6 处 |
| `entry/src/main/ets/pages/DocTabHost.ets` | tab 主题色按 family 派生 | 改 1 处 |
| `entry/src/main/ets/common/smoke.ets` | 验收样本白名单由表派生 | 改 1 处 |
| `scripts/onlyoffice/desktop/src/30_open.js` | m7open 验收段的 type 改由 URL 传入 | 改 1 处 |
| `scripts/onlyoffice/build_editors_ohos.py` | smoke 样本存在性断言 | 改 1 处 |
| `scripts/onlyoffice/smoke/samples/` | 新增 6 个样本（doc/xls/ppt/rtf/txt/csv） | **新增文件** |
| `scripts/onlyoffice/tests/cases.tsv` | 新增 9 个回归 case | 改 |
| `scripts/onlyoffice/tests/README.md` | 覆盖表更新 | 改 |

## 通用约定

- **构建部署**（每个 Task 的验证起点；**禁止 hvigor clean**——会毁 core3d 产物）：
  ```bash
  OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh
  ```
- **单次手工验证**（拉一份干净日志）：
  ```bash
  HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
  DEV=192.168.1.6:33363
  LOG=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt
  $HDC -t $DEV shell aa force-stop app.fuqidian.pureoffice
  $HDC -t $DEV shell ": > $LOG"
  $HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args 'm7accept=1;m7file=sample.doc'"
  sleep 25
  $HDC -t $DEV shell "grep -E 'OPEN_|FMT_|SAVE_BIN|LSO_' $LOG"
  ```
  注意：设备侧 `grep` 不支持 `\|`，必须用 `grep -E` + `|`。
- **回归**：`OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/tests/regression.sh [--case <id> | --record --case <id>]`
- 每个 Task 结束时 commit（中文 message，不带 Co-Authored-By）。

---

### Task 1: formats.ets 数据模型

**Files:**
- Create: `entry/src/main/ets/common/formats.ets`

- [ ] **Step 1: 写 formats.ets（完整内容）**

```typescript
/**
 * formats.ets —— 可打开文件格式的唯一数据源（2026-09-11 格式扩展）。
 *
 * 为什么要有这张表：扩展前「扩展名 → 格式属性」在五处各写一遍，且都以「三元兜底
 * 到 docx」收尾（editorApp / recents type / 页面 fileType 映射 / picker 过滤 /
 * 保存目标）。放开白名单后未知格式会静默走进 docx 分支（如 .xls 被当 word 打开
 * → 白屏且无报错）。此处收敛为单表 + 唯一判定入口 specOf()——返回 null = 不支持，
 * 调用方必须显式处理（弹提示或拒绝），不允许再出现三元兜底。
 *
 * 能力边界来自 x2t GetConvertType（third_party/core/X2tConverter/src/
 * cextracttools.cpp）：打开方向宽（doc/rtf/txt/csv 等都能转 doct_bin），保存方向
 * 窄（bin 只能出 OOXML 与 rtf/csv——没有 bin→doc/odt/txt 通路）。
 *
 * recentType 取官方 FileFormat 枚举（third_party/core/Test/Applications/FilesSort/
 * FilesSort/CodeFile1.cs:126-150：DOCUMENT=0x40 / PRESENTATION=0x80 /
 * SPREADSHEET=0x100 为基址 + 序号）。loginpage 的 parseFileFormat（utils.js:252）
 * 据此选「最近使用」列表图标（res/img/generated/formats.svg 含全部符号）。
 */

/** 格式规格 */
export interface FormatSpec {
  /** 源扩展名（小写、不含点） */
  ext: string;
  /** 编辑器族：'word' | 'cell' | 'slide'（决定编辑器应用页与 docType） */
  family: string;
  /** 传给编辑器页的 fileType = 家族代表名（docx/xlsx/pptx）——x2t 产出的 doct_bin
   *  签名即 DOCY/XLSY/PPTY，页面与引擎只认家族；源格式只在 ArkTS 侧有意义
   *  （.doc 也传 docx） */
  fileType: string;
  /** loginpage FileFormat 枚举值（「最近使用」图标） */
  recentType: number;
  /** 保存产物后缀；saveExt ≠ ext ⇒ 不能原地保存（需提示后另存） */
  saveExt: string;
  /** 保存产物校验方式：'zip' = PK 头 / 'rtf' = {\rtf 头 / 'size' = 仅非空 */
  check: string;
}

/** 可打开格式表（新增格式 = 此处加一行 + 备样本 + 回归 case） */
const FORMATS: FormatSpec[] = [
  { ext: 'docx', family: 'word', fileType: 'docx', recentType: 0x41, saveExt: 'docx', check: 'zip' },
  { ext: 'doc', family: 'word', fileType: 'docx', recentType: 0x42, saveExt: 'docx', check: 'zip' },
  { ext: 'rtf', family: 'word', fileType: 'docx', recentType: 0x44, saveExt: 'rtf', check: 'rtf' },
  { ext: 'txt', family: 'word', fileType: 'docx', recentType: 0x45, saveExt: 'docx', check: 'zip' },
  { ext: 'xlsx', family: 'cell', fileType: 'xlsx', recentType: 0x101, saveExt: 'xlsx', check: 'zip' },
  { ext: 'xls', family: 'cell', fileType: 'xlsx', recentType: 0x102, saveExt: 'xlsx', check: 'zip' },
  { ext: 'csv', family: 'cell', fileType: 'xlsx', recentType: 0x104, saveExt: 'csv', check: 'size' },
  { ext: 'pptx', family: 'slide', fileType: 'pptx', recentType: 0x81, saveExt: 'pptx', check: 'zip' },
  { ext: 'ppt', family: 'slide', fileType: 'pptx', recentType: 0x82, saveExt: 'pptx', check: 'zip' }
];

/** 扩展名（可带点/大小写）→ 格式规格；未支持返回 null（唯一判定入口） */
export function specOf(ext: string): FormatSpec | null {
  let e = ext.toLowerCase();
  if (e.length > 0 && e.charAt(0) === '.') {
    e = e.substring(1);
  }
  for (const f of FORMATS) {
    if (f.ext === e) {
      return f;
    }
  }
  return null;
}

/** 系统文件选择器过滤后缀（含点；顺序 = 表序） */
export function pickerSuffixes(): string[] {
  const out: string[] = [];
  for (const f of FORMATS) {
    out.push('.' + f.ext);
  }
  return out;
}

/** 编辑器应用页名（webapps/apps/<name>/main/index.html） */
export function editorAppOf(family: string): string {
  if (family === 'cell') {
    return 'spreadsheeteditor';
  }
  if (family === 'slide') {
    return 'presentationeditor';
  }
  return 'documenteditor';
}

/** 保存是否需「提示 → 另存」（不能原地保存的格式） */
export function needsSaveAsPrompt(ext: string): boolean {
  const f = specOf(ext);
  return f !== null && f.saveExt !== f.ext;
}

/** RTF 头「{\rtf」的字节 */
const RTF_HEAD: number[] = [0x7B, 0x5C, 0x72, 0x74, 0x66];

/**
 * 保存产物校验（按 check 分派）：null = 通过；否则返回失败标签（调用方打日志）。
 * 'size'（csv 纯文本无稳定魔数）只拦空产物——内容正确性由真机回读验证。
 */
export function checkSaveOut(buf: Uint8Array, check: string): string | null {
  if (buf.byteLength === 0) {
    return 'EMPTY';
  }
  if (check === 'zip') {
    if (buf.byteLength < 2 || buf[0] !== 0x50 || buf[1] !== 0x4B) {
      return 'ZIPBAD';
    }
    return null;
  }
  if (check === 'rtf') {
    if (buf.byteLength < RTF_HEAD.length) {
      return 'RTFBAD';
    }
    for (let i = 0; i < RTF_HEAD.length; i++) {
      if (buf[i] !== RTF_HEAD[i]) {
        return 'RTFBAD';
      }
    }
    return null;
  }
  return null;
}
```

- [ ] **Step 2: 构建验证（编译通过）**

Run: `OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh`
Expected: 构建成功、部署到设备（`BUILD SUCCESSFUL` / 安装成功提示）。本 Task 纯新增文件，无行为变化。

- [ ] **Step 3: Commit**

```bash
git add entry/src/main/ets/common/formats.ets
git commit -m "feat: formats.ets 格式表——可打开格式的唯一数据源（9 种）"
```

---

### Task 2: 测试样本入库

**Files:**
- Create: `scripts/onlyoffice/smoke/samples/sample.doc`（复制）
- Create: `scripts/onlyoffice/smoke/samples/sample.xls`（复制）
- Create: `scripts/onlyoffice/smoke/samples/sample.ppt`（复制）
- Create: `scripts/onlyoffice/smoke/samples/sample.rtf` / `sample.txt` / `sample.csv`（手写）
- Modify: `scripts/onlyoffice/build_editors_ohos.py`（`install_smoke` 末尾加断言）

- [ ] **Step 1: 复制三个真实旧格式样本（二进制，用 cp）**

```bash
cd /data/share/office
cp third_party/core/DesktopEditor/raster/Jp2/openjpeg/openjpeg-2.4.0/src/bin/mj2/mj2_to_metadata_Notes.doc scripts/onlyoffice/smoke/samples/sample.doc
cp "third_party/core/Test/Applications/AVSOfficeEWSEditorTest/AVSOfficeEWSEditorTest/TestFiles/Auto_color_as_index.xls" scripts/onlyoffice/smoke/samples/sample.xls
cp third_party/core/Common/cfcpp/test/data/src/ex.ppt scripts/onlyoffice/smoke/samples/sample.ppt
```

- [ ] **Step 2: 验证复制结果是真格式**

Run: `file scripts/onlyoffice/smoke/samples/sample.doc scripts/onlyoffice/smoke/samples/sample.xls scripts/onlyoffice/smoke/samples/sample.ppt`
Expected（三条都要是 Composite Document File V2）：
```
sample.doc: Composite Document File V2 Document, ... Microsoft Word 10.0 ...
sample.xls: Composite Document File V2 Document, ...
sample.ppt: Composite Document File V2 Document, ... Microsoft PowerPoint ...
```
若 `sample.doc` 显示 `ISO-8859 text` 等非 OLE2 结果 → 路径取错文件，回到 Step 1 重取。

- [ ] **Step 3: 手写三个文本样本**

`scripts/onlyoffice/smoke/samples/sample.txt`：
```
Pure Office 纯文本样本
Line 2: regression sample for .txt import.
第三行：中文内容（验证 txt 导入编码）。
```

`scripts/onlyoffice/smoke/samples/sample.csv`：
```
姓名,部门,金额,日期
张三,研发,1200.50,2026-01-15
李四,市场,880.00,2026-02-20
```

`scripts/onlyoffice/smoke/samples/sample.rtf`：
```
{\rtf1\ansi\deff0
{\fonttbl{\f0\fnil\fcharset0 Times New Roman;}}
\viewkind4\uc1\pard\f0\fs24 Pure Office RTF sample.\par
Line 2: regression sample for .rtf open/save.\par
}
```

- [ ] **Step 4: 构建脚本加样本存在性断言**

在 `scripts/onlyoffice/build_editors_ohos.py` 的 `install_smoke()` 函数**末尾**（`print('  smoke 脚本 → ...')` 之后）追加：

```python
    # 格式扩展样本存在性断言：缺失 = 回归 case 必失败，构建期拦下
    # （依据：docs/superpowers/specs/2026-09-11-file-format-expansion-design.md §9.1）
    for name in ('sample.doc', 'sample.xls', 'sample.ppt',
                 'sample.rtf', 'sample.txt', 'sample.csv'):
        if not os.path.isfile(os.path.join(SMOKE_DST, 'samples', name)):
            raise SystemExit('smoke 样本缺失：samples/%s（格式扩展回归依赖）' % name)
```

- [ ] **Step 5: 构建验证（样本进包）**

Run: `OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh`
Expected: 构建成功。若断言报 `smoke 样本缺失` → 回到 Step 1/3 补文件。

验证样本确实进了设备沙箱（应用启动后）：
```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
$HDC -t 192.168.1.6:33363 shell "ls -la /data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/ | grep -E 'sample\.(doc|xls|ppt|rtf|txt|csv)'"
```
（样本由 EditorPage 启动时从 rawfile 拷到沙箱；若为空，先启动一次应用 `aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args 'm7accept=1;m7file=sample.doc'`）

- [ ] **Step 6: Commit**

```bash
git add scripts/onlyoffice/smoke/samples/ scripts/onlyoffice/build_editors_ohos.py
git commit -m "test: 格式扩展回归样本入库（doc/xls/ppt 取仓库真实文件 + txt/csv/rtf 手写）"
```

---

### Task 3: 打开链查表化

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets`（`openLocalFile` :413-449、`openRecent` :451-494、`editorUrl` :184-206、`homeUrl` :169-175）

- [ ] **Step 1: 加 import**

在 `EditorPage.ets` 顶部 import 区（现有 `import { ... } from '../common/recents'` 附近）加：

```typescript
import { specOf, pickerSuffixes, editorAppOf, needsSaveAsPrompt, checkSaveOut } from '../common/formats';
```

（`needsSaveAsPrompt`/`checkSaveOut` 本 Task 未用，Task 4/5 用——一次导入完，避免多次改 import 块。）

- [ ] **Step 2: `openLocalFile` 的 picker 过滤与硬校验**

把 `:417-419` 的
```typescript
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.docx', '.xlsx', '.pptx'];
```
改为
```typescript
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      // 可打开格式由 formats 表派生（新增格式自动进入选择器过滤）
      opts.fileSuffixFilters = pickerSuffixes();
```

把 `:439-442` 的
```typescript
      if (ext !== 'docx' && ext !== 'xlsx' && ext !== 'pptx') {
        this.arkLog('OPEN_LOCAL_EXTBAD label=' + label + ' ext=' + ext);
        return;
      }
```
改为
```typescript
      if (specOf(ext) === null) {
        // 未支持格式：显式提示（不再静默 return——用户须知道发生了什么）
        this.arkLog('OPEN_LOCAL_EXTBAD label=' + label + ' ext=' + ext);
        this.showFormatNotice('暂不支持该格式：' + label);
        return;
      }
```

（`showFormatNotice` 在 Task 6 实现；本 Task 先留调用——构建前若报未定义，把 Task 6 的 Step 1/2 提前执行。）

- [ ] **Step 3: `openRecent` 改为按后缀查表**

把 `:457-475` 的
```typescript
      const typeNum = Number(o['type'] ?? 0);
      let ext = '';
      if (typeNum === RECENT_TYPE_XLSX) {
        ext = 'xlsx';
      } else if (typeNum === RECENT_TYPE_PPTX) {
        ext = 'pptx';
      } else {
        ext = 'docx';
      }
      // 扩展名兜底（recents 模型缺 type 时从文件名后缀采信白名单）
      if (name.length > 0) {
        const i = name.lastIndexOf('.');
        if (i > 0) {
          const sfx = name.substring(i + 1);
          if (sfx === 'xlsx' || sfx === 'pptx' || sfx === 'docx') {
            ext = sfx;
          }
        }
      }
      if (path.length === 0) {
        this.arkLog('OPEN_RECENT_NOPATH ' + param);
        return 'false';
      }
      // 文件名以 path 尾部为准（loginpage recents 的 name 字段可能被截断/缺失）
      const base = path.substring(path.lastIndexOf('/') + 1);
```
改为
```typescript
      if (path.length === 0) {
        this.arkLog('OPEN_RECENT_NOPATH ' + param);
        return 'false';
      }
      // 文件名以 path 尾部为准（loginpage recents 的 name 字段可能被截断/缺失）
      const base = path.substring(path.lastIndexOf('/') + 1);
      const label = base.length > 0 ? base : name;
      // 源格式以**文件名后缀**为准（recents.type 是展示枚举、非格式判据）；后缀缺失
      // 或不支持 → 显式提示（不得兜底 docx：静默按 docx 打开 = 静默错误）
      let ext = '';
      const i = label.lastIndexOf('.');
      if (i > 0) {
        ext = label.substring(i + 1).toLowerCase();
      }
      if (ext.length === 0 || specOf(ext) === null) {
        this.arkLog('OPEN_RECENT_EXTBAD label=' + label + ' ext=' + ext);
        this.showFormatNotice('暂不支持该格式：' + label);
        return 'false';
      }
```
同时删除该函数内已无用的 `const typeNum = ...` 行（避免未使用变量）。

- [ ] **Step 4: `editorUrl` 按 family 派生**

把 `:184-187` 的
```typescript
  private editorUrl(type: string, title: string, sidVal?: number): string {
    const app = type === 'xlsx' ? 'spreadsheeteditor'
      : type === 'pptx' ? 'presentationeditor' : 'documenteditor';
```
改为
```typescript
  private editorUrl(type: string, title: string, sidVal?: number): string {
    // type = 源扩展名或家族代表名——页面与引擎只认家族（doct_bin 签名 DOCY/XLSY/
    // PPTY），.doc/.rtf 等一律按 word 家族打开；查不到（防御）按 word 兜底
    const spec = specOf(type);
    const family = spec !== null ? spec.family : 'word';
    const fileType = spec !== null ? spec.fileType : 'docx';
    const app = editorAppOf(family);
```
并把 `:188` 的 URL 拼接中两处 `type` 改为 `fileType`：
```typescript
      + '&fileType=' + fileType + '&isDesktop=false&docType=' + fileType + '&lang=zh-CN&title=' + encodeURIComponent(title)
```

- [ ] **Step 5: `homeUrl` 的 m7open 带 type（消除页面侧第二份格式表）**

把 `:174` 的
```typescript
      + (this.m7Target.length > 0 ? '&m7open=' + encodeURIComponent(this.m7Target) : '');
```
改为
```typescript
      + (this.m7Target.length > 0 ? '&m7open=' + encodeURIComponent(this.m7Target) : '')
      // m7type = 该样本的 FileFormat 枚举（页面侧不再自持格式表——见 30_open.js 3.55b）
      + (this.m7Target.length > 0
        ? '&m7type=' + (specOf(this.m7Target.substring(this.m7Target.lastIndexOf('.') + 1))?.recentType ?? 0x41).toString(16)
        : '');
```

同时改 `scripts/onlyoffice/desktop/src/30_open.js:100-101`：

把
```javascript
              var _ext2 = (_m7f.match(/\.([a-z0-9]+)$/i) || [])[1] || 'docx';
              var _type2 = _ext2 === 'xlsx' ? 0x101 : _ext2 === 'pptx' ? 0x81 : 0x41;
```
改为
```javascript
              // type 由壳层给定（EditorPage 按 formats 表推导并拼 m7type=<hex>）——
              // 页面不再自持第二份格式表；无参数（旧 URL）兜底 docx 仅供兼容
              var _tq2 = String(window.location.search).match(/[?&]m7type=([0-9a-fA-F]+)/);
              var _type2 = _tq2 ? parseInt(_tq2[1], 16) : 0x41;
```

- [ ] **Step 6: 重新生成 ascshim 并构建**

Run:
```bash
python3 scripts/onlyoffice/desktop/make_ascshim.py
OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh
```
Expected: `node --check: OK` + 构建成功。

- [ ] **Step 7: 真机验证打开链（doc/xls/ppt/rtf/txt/csv 逐个）**

对 `sample.doc` / `sample.xls` / `sample.ppt` / `sample.rtf` / `sample.txt` / `sample.csv` 各跑一次（把下面命令的 `sample.doc` 替换为目标样本）：

```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
DEV=192.168.1.6:33363
LOG=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt
$HDC -t $DEV shell aa force-stop app.fuqidian.pureoffice
$HDC -t $DEV shell ": > $LOG"
$HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args 'm7accept=1;m7file=sample.doc'"
sleep 30
$HDC -t $DEV shell "grep -E 'OPEN_X2T|LSO_OPEN_DOCUMENT_OK|LSO_DIOPEN_OK|LSO_LOAD_ERR|OPEN_BIN_MISS' $LOG"
```
Expected（每种格式）：`OPEN_X2T rc=0x0 (0)`（x2t 转换成功，**不得**出现 `OPEN_X2T_FAIL`），且出现打开链成功标签（word 族 `LSO_OPEN_DOCUMENT_OK` / cell/slide 族 `LSO_DIOPEN_OK` 或 `LSO_KICK_SERVERID`）。
doc/xls/ppt 若 rc≠0 → x2t 不支持该样本，需换样本；若 rc=0 但无成功标签 → 记录实际日志，作为 Task 8 的排查输入。
截图（`snapshot_display`）人工确认渲染正确（不白屏、编辑器族正确：xls/csv 必须是表格编辑器、ppt 必须是演示编辑器）。

- [ ] **Step 8: Commit**

```bash
git add entry/src/main/ets/pages/EditorPage.ets scripts/onlyoffice/desktop/src/30_open.js
python3 scripts/onlyoffice/desktop/make_ascshim.py  # 产物同步（若上一步已跑可跳过）
git add entry/src/main/resources/rawfile/onlyoffice/ascshim.js
git commit -m "feat: 打开链查表化（picker/硬校验/editorUrl/recents 全部由 formats 表派生）"
```

---

### Task 4: 保存链产物后缀与校验分派

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets`（`saveBinRaw` :862-955、`doSaveAs` :497-574）

- [ ] **Step 1: `saveBinRaw` 的产物后缀与校验按表分派**

把 `:869-872` 的
```typescript
      // M7 三格式：目标后缀决定 x2t 转换器（doct_bin2docx / xlst_bin2xlsx / pptt_bin2pptx）
      const extU = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const inP = ctx.tabPath('in.bin');
      const outP = ctx.tabPath('save.' + extU);
```
改为
```typescript
      // 目标后缀取自 formats 表：不能原地保存的格式（doc/xls/ppt/txt）saveExt 指向
      // 家族代表名（.doc → .docx）——x2t 无 bin→doc 通路（见 formats.ets 表头注释）
      const srcExt = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const srcSpec = specOf(srcExt);
      const extU = srcSpec !== null ? srcSpec.saveExt : 'docx';
      const outCheck = srcSpec !== null ? srcSpec.check : 'zip';
      const inP = ctx.tabPath('in.bin');
      const outP = ctx.tabPath('save.' + extU);
```

把 `:883-896` 的
```typescript
      // zip 头校验 0x50 0x4b（校验比 exist 更严：x2t 产物必须是合法 ZIP）
      const outBuf = readFileBuf(outP);
      if (outBuf === null) {
        this.arkLog('SAVE_BIN_SUBMISS ' + outP);
        return 'false';
      }
      const mk = new Uint8Array(outBuf.slice(0, 2));
      const zipOk = mk[0] === 0x50 && mk[1] === 0x4b;
      this.arkLog('SAVE_BIN_OUT size=' + outBuf.byteLength + ' mk=0x'
        + mk[0].toString(16).padStart(2, '0') + mk[1].toString(16).padStart(2, '0')
        + (zipOk ? ' zipok' : ' ZIPBAD'));
      if (!zipOk) {
        return 'false';
      }
```
改为
```typescript
      // 产物校验按表分派（zip/rtf/size）——原硬编码 ZIP 头会把 rtf/csv 误判为坏产物
      const outBuf = readFileBuf(outP);
      if (outBuf === null) {
        this.arkLog('SAVE_BIN_SUBMISS ' + outP);
        return 'false';
      }
      const bad = checkSaveOut(new Uint8Array(outBuf), outCheck);
      this.arkLog('SAVE_BIN_OUT size=' + outBuf.byteLength + ' check=' + outCheck
        + (bad === null ? ' ok' : ' BAD:' + bad));
      if (bad !== null) {
        return 'false';
      }
```

- [ ] **Step 2: `saveBinRaw` 的 recents type 查表**

把 `:937-938` 的
```typescript
          const saveType = ctx.state.ext === 'xlsx' ? RECENT_TYPE_XLSX
            : ctx.state.ext === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
```
改为
```typescript
          const specR = specOf(ctx.state.ext);
          const saveType = specR !== null ? specR.recentType : RECENT_TYPE_DOCX;
```

- [ ] **Step 3: `doSaveAs` 支持强制后缀（`forceExt`）**

把 `:501` 的签名
```typescript
  private async doSaveAs(ctx: DocTabCtx, outBuf: ArrayBuffer): Promise<void> {
```
改为
```typescript
  private async doSaveAs(ctx: DocTabCtx, outBuf: ArrayBuffer, forceExt?: string): Promise<void> {
```

把 `:505-510` 的
```typescript
      const opts = new picker.DocumentSaveOptions();
      // 默认名：已保存文档=当前名；新建=语言包中文未命名（defaultDocName——
      // 2026-09-08 补：doSaveAs 兜底名原写死 Unnamed.，与 openNewFile 语言包驱动对齐）
      const defName = ctx.state.name.length > 0 ? ctx.state.name : this.defaultDocName(ctx.state.ext);
      opts.newFileNames = [defName];
```
改为
```typescript
      const opts = new picker.DocumentSaveOptions();
      // 目标后缀：forceExt 优先（不能原地保存的格式：.doc → .docx），否则同格式
      const targetExt = (forceExt !== undefined && forceExt.length > 0) ? forceExt : ctx.state.ext;
      // 默认名：已保存文档=当前名**换目标后缀**（.doc → .docx；原名直接带上会把
      // docx 字节写成 .doc 名）；新建=语言包中文未命名（defaultDocName）
      let defName = '';
      if (ctx.state.name.length > 0) {
        const dn = ctx.state.name.lastIndexOf('.');
        defName = (dn > 0 ? ctx.state.name.substring(0, dn) : ctx.state.name) + '.' + targetExt;
      } else {
        defName = this.defaultDocName(targetExt);
      }
      opts.newFileNames = [defName];
      // 后缀限定（DocumentSaveOptions.fileSuffixChoices，**不是** SelectOptions 的
      // fileSuffixFilters——字段名不同）：防用户手改扩展名产生「名实不符」文件
      opts.fileSuffixChoices = ['.' + targetExt];
```

- [ ] **Step 4: `doSaveAs` 的落盘后身份演进与 recents 查表**

把 `:536-541` 的
```typescript
        const dot = base.lastIndexOf('.');
        if (dot > 0) {
          const e2 = base.substring(dot + 1).toLowerCase();
          if (e2 === 'docx' || e2 === 'xlsx' || e2 === 'pptx') {
            ctx.state.ext = e2;
          }
        }
```
改为
```typescript
        const dot = base.lastIndexOf('.');
        if (dot > 0) {
          const e2 = base.substring(dot + 1).toLowerCase();
          if (specOf(e2) !== null) {
            ctx.state.ext = e2;
          }
        }
```

把 `:556-557` 的
```typescript
        const typeNum = ctx.state.ext === 'xlsx' ? RECENT_TYPE_XLSX
          : ctx.state.ext === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
```
改为
```typescript
        const specA = specOf(ctx.state.ext);
        const typeNum = specA !== null ? specA.recentType : RECENT_TYPE_DOCX;
```

- [ ] **Step 5: 构建 + 真机验证「能原地保存的格式」**

Run:
```bash
OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh
```
验证 rtf/csv 原地保存（rtf 头校验 / csv 非空校验是否放行）：
```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
DEV=192.168.1.6:33363
LOG=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt
for F in sample.rtf sample.csv; do
  $HDC -t $DEV shell aa force-stop app.fuqidian.pureoffice
  $HDC -t $DEV shell ": > $LOG"
  $HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args 'm7accept=1;m7file=$F;m7auto=1'"
  sleep 40
  echo "== $F =="
  $HDC -t $DEV shell "grep -E 'SAVE_BIN_X2T|SAVE_BIN_OUT|SAVE_BIN_BACK|SAVE_BIN_URI|BAD:' $LOG"
done
```
Expected: 每种格式 `SAVE_BIN_X2T rc=0x0`、`SAVE_BIN_OUT ... ok`（**不得** `BAD:`）、并出现 `SAVE_BIN_BACK`（沙箱回写）；未命名文档首存会走另存为（`SAVE_AS_DIALOG`），亦算通过。
同时确认现有 docx/xlsx/pptx 保存未退化：`OHOS_DEV=... bash scripts/onlyoffice/tests/regression.sh --case save-word`（PASS）。

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/pages/EditorPage.ets
git commit -m "feat: 保存链按表分派产物后缀与校验（rtf/csv 不再被 ZIP 头误判）"
```

---

### Task 5: 格式提示覆盖层 + 另存身份演进

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets`（字段区 :153-164、`saveBinRaw` :862-955、`onTabCommand` :240-251、`saveAndClose` 超时兜底 :1517-1525、`build()` :1864-1910）

- [ ] **Step 1: 加状态字段**

在 `:161-164` 的守卫字段块**之后**加：

```typescript
  /** 格式提示覆盖层（不能原地保存的格式：提示 → 另存；与守卫框互斥） */
  @State fmtDialogOn: boolean = false;
  @State fmtDialogText: string = '';
  private fmtDialogCtx: DocTabCtx | null = null;
  private fmtDialogOut: ArrayBuffer | null = null;
```

- [ ] **Step 2: 加提示覆盖层 UI（`build()` 内、守卫覆盖层之后）**

在 `:1910`（守卫覆盖层 `if (this.guardDialogOn) { ... }` 块结束）之后、`}` 闭合 Stack 之前加：

```typescript
      // —— 格式提示覆盖层（不能原地保存的格式：确认后另存；单按钮 notice 时仅告知）——
      if (this.fmtDialogOn) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            this.fmtDialogAction('cancel');
          })
        Column({ space: 4 }) {
          Text('格式不支持保存')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2B3B4D')
          Text(this.fmtDialogText)
            .fontSize(14).fontColor('#5A6572').textAlign(TextAlign.Center)
            .margin({ top: 12 })
          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .backgroundColor('#F7F7F7').fontColor('#2B3B4D')
              .onClick(() => {
                this.fmtDialogAction('cancel');
              })
            Button('继续')
              .layoutWeight(1)
              .backgroundColor('#0064E7').fontColor(Color.White)
              .onClick(() => {
                this.fmtDialogAction('ok');
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .padding(24)
        .width(420)
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层取消）
        })
      }
```

- [ ] **Step 3: 加动作分发（放在 `guardDialogAction` 之后）**

```typescript
  /**
   * 格式提示动作（自绘层唯一出口）：ok=继续（走另存，强制 saveExt 后缀）；
   * cancel/蒙层=不保存（数据未落盘，同另存为取消语义——守卫在途则不关）。
   * 禁止回写原文件：原 savePath 指向 .doc/.rtf 等源文件，覆盖会把新格式字节
   * 写进旧扩展名文件（名实不符）。
   */
  private fmtDialogAction(act: string): void {
    if (!this.fmtDialogOn) {
      return;
    }
    const ctx = this.fmtDialogCtx;
    const out = this.fmtDialogOut;
    this.fmtDialogOn = false;
    this.fmtDialogCtx = null;
    this.fmtDialogOut = null;
    this.fmtDialogText = '';
    if (ctx === null) {
      this.arkLog('FMT_DIALOG_CTX_NULL act=' + act);
      return;
    }
    if (act !== 'ok' || out === null) {
      this.arkLog('FMT_DIALOG_CANCEL ext=' + ctx.state.ext + ' tab=' + ctx.id);
      ctx.state.saveAborted = true;
      this.clearCloseGuard(ctx, false);
      return;
    }
    const spec = specOf(ctx.state.ext);
    const targetExt = spec !== null ? spec.saveExt : 'docx';
    this.arkLog('FMT_DIALOG_CONFIRM ext=' + ctx.state.ext + ' to=' + targetExt + ' tab=' + ctx.id);
    this.doSaveAs(ctx, out, targetExt);
  }
```

- [ ] **Step 4: `saveBinRaw` 插入提示分支（在写盘/回写之前）**

在 `:903` 的 `if (userSaved && ctx.state.saveTarget === 'none') { ... }` 块**之前**插入：

```typescript
      // 不能原地保存的格式（doc/xls/ppt/txt）：产物已生成但不落盘——先弹提示，
      // 确认后走 doSaveAs（强制 saveExt）。禁止回写：savePath 指向源 .doc，覆盖
      // 会把 docx 字节写进 .doc 文件。新建（saveTarget='none'）本就走另存为，跳过。
      if (userSaved && ctx.state.saveTarget !== 'none' && needsSaveAsPrompt(ctx.state.ext)) {
        this.fmtDialogCtx = ctx;
        this.fmtDialogOut = outBuf;
        this.fmtDialogText = '「.' + ctx.state.ext + '」格式不支持保存，将以「.'
          + extU + '」格式另存。';
        this.fmtDialogOn = true;
        // 守卫「保存」在途：复用 awaitingSaveAs 语义（本段不消费 defer，成功由
        // doSaveAs 尾消费 / 取消走 fmtDialogAction 的 clearCloseGuard）
        if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx) {
          this.closeGuardDefer.awaitingSaveAs = true;
        }
        this.arkLog('FMT_DIALOG_ON ext=' + ctx.state.ext + ' to=' + extU + ' tab=' + ctx.id);
        // 对话框异步期间先回 'true'（保存受理）——与 doSaveAs 同一模式
        return 'true';
      }
```

- [ ] **Step 5: 守卫消费条件补 `fmtDialogOn` 检查**

把 `:246-249` 的
```typescript
      if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx
        && !this.closeGuardDefer.awaitingSaveAs) {
        this.clearCloseGuard(ctx, r === 'true');
      }
```
改为
```typescript
      if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx
        && !this.closeGuardDefer.awaitingSaveAs && !this.fmtDialogOn) {
        this.clearCloseGuard(ctx, r === 'true');
      }
```

- [ ] **Step 6: 守卫超时兜底补同一条件**

把 `:1518-1519` 的
```typescript
      if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx
        && !this.closeGuardDefer.awaitingSaveAs) {
```
改为
```typescript
      if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx
        && !this.closeGuardDefer.awaitingSaveAs && !this.fmtDialogOn) {
```

- [ ] **Step 7: 构建 + 真机验证「提示 → 另存」**

Run: `OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh`

验证 doc 的保存被提示拦下且**不回写原文件**：
```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
DEV=192.168.1.6:33363
LOG=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt
$HDC -t $DEV shell aa force-stop app.fuqidian.pureoffice
$HDC -t $DEV shell ": > $LOG"
$HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args 'm7accept=1;m7file=sample.doc;m7auto=1'"
sleep 45
$HDC -t $DEV shell "grep -E 'SAVE_BIN_X2T|SAVE_BIN_OUT|FMT_DIALOG_ON|SAVE_BIN_URI|SAVE_BIN_BACK' $LOG"
```
Expected: `SAVE_BIN_X2T rc=0x0`、`SAVE_BIN_OUT ... ok`、`FMT_DIALOG_ON ext=doc to=docx`；**必须没有** `SAVE_BIN_URI`/`SAVE_BIN_BACK`（证明没回写源文件）。
截图确认提示框文案与按钮显示正常。
手指验证完整链路：点「继续」→ 系统保存框默认名 `sample.docx`（后缀已换）→ 落盘 → tab 标题变 `.docx` → 再次保存**不再弹提示**（普通原地保存）。点「取消」→ 文档留在原地、无落盘。

- [ ] **Step 8: Commit**

```bash
git add entry/src/main/ets/pages/EditorPage.ets
git commit -m "feat: 不能原地保存的格式走「提示 → 另存」（禁止回写原文件）"
```

---

### Task 6: 残留硬编码清理 + 显式拒绝路径

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets`（新增 `showFormatNotice`）
- Modify: `entry/src/main/ets/pages/DocTabHost.ets`（`accentColor` :148-160）
- Modify: `entry/src/main/ets/common/smoke.ets`（白名单 :31）

- [ ] **Step 1: `EditorPage` 加 `showFormatNotice`（单按钮告知层）**

在 `fmtDialogAction` 之后加：

```typescript
  /** 不支持格式的告知层（单按钮；复用格式覆盖层 UI——文案由调用方给定，
   *  按钮语义为「知道了」=取消路径：清态、不落盘） */
  private showFormatNotice(text: string): void {
    this.fmtDialogCtx = null;
    this.fmtDialogOut = null;
    this.fmtDialogText = text;
    this.fmtDialogOn = true;
    this.arkLog('FMT_NOTICE ' + text);
  }
```

- [ ] **Step 2: `DocTabHost.accentColor` 按 family 派生**

把 `DocTabHost.ets:148-160` 的
```typescript
function accentColor(state: DocTabState): string {
  const e = state.ext;
  if (e === 'xlsx') {
    return '#3E8D5F';
  }
  if (e === 'pptx') {
    return '#8E5EB8';
  }
  return '#4B71A5';
}
```
改为
```typescript
function accentColor(state: DocTabState): string {
  // 按族取色（新增格式自动归族——.xls 与 .xlsx 同色、.doc 与 .docx 同色）
  const spec = specOf(state.ext);
  const family = spec !== null ? spec.family : 'word';
  if (family === 'cell') {
    return '#3E8D5F';
  }
  if (family === 'slide') {
    return '#8E5EB8';
  }
  return '#4B71A5';
}
```
并在 `DocTabHost.ets` 顶部 import 区加：
```typescript
import { specOf } from '../common/formats';
```

- [ ] **Step 3: `smoke.ets` 白名单由表派生**

把 `smoke.ets:30-31` 的
```typescript
  /** 白名单后缀（m7file 只允许三类样本；dev-only 参数，防路径越界） */
  protected static readonly EXT_WHITELIST = ['docx', 'xlsx', 'pptx'];
```
改为
```typescript
  /** 白名单后缀（m7file 只允许验收样本；dev-only 参数，防路径越界）——
   *  与 formats 表同源（新增可打开格式自动放行其样本名） */
  protected static readonly EXT_WHITELIST: string[] =
    pickerSuffixes().map((s: string) => s.substring(1));
```
并在 `smoke.ets` 顶部加：
```typescript
import { pickerSuffixes } from './formats';
```

- [ ] **Step 4: 静态检查「无残留三元兜底」**

Run:
```bash
grep -rnE "=== *'(docx|xlsx|pptx)'" entry/src/main/ets/ --include=*.ets | grep -v "formats.ets"
```
Expected（允许的残留，逐条确认语义）：
- `EditorPage.ets` 的 `openNewFile`/`create:new`（新建恒三格式，与表无关）
- `EditorPage.ets:383-384` `defaultDocName` 的兜底名（新建/另存为目标名，输入恒为 docx/xlsx/pptx）
- `DocTabHost.ets` 无命中（已改为按 family）
- 其余命中 = 漏改，逐处改掉

再查页面侧：
```bash
grep -rnE "=== *'(docx|xlsx|pptx|doc|xls|ppt|rtf|txt|csv)'" scripts/onlyoffice/desktop/src/*.js
```
Expected：无命中（30_open.js 已改为读 URL 的 m7type）。

- [ ] **Step 5: 构建 + 真机验证「不支持格式显式提示」**

Run: `OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh`

构造一个不支持格式进沙箱（`.odt`），用 recents 路径触发：
```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
DEV=192.168.1.6:33363
BASE=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files
LOG=$BASE/web_console.txt
# 从仓库现有 odt 测试文件造一个样本（third_party/core/OdfFile/Test/Test/ExampleFiles/61364.odt）
$HDC -t $DEV file send /data/share/office/third_party/core/OdfFile/Test/Test/ExampleFiles/61364.odt $BASE/sample.odt
$HDC -t $DEV shell aa force-stop app.fuqidian.pureoffice
$HDC -t $DEV shell ": > $LOG"
$HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args 'm7accept=1;m7file=sample.odt'"
sleep 15
$HDC -t $DEV shell "grep -E 'FMT_NOTICE|OPEN_LOCAL_EXTBAD|OPEN_RECENT_EXTBAD' $LOG"
```
Expected: `FMT_NOTICE 暂不支持该格式：sample.odt`（证明不支持的格式被显式拦下、有用户可见提示，而非静默打开）。
注：`m7file` 白名单已含 odt？——`smoke.ets` 白名单由表派生，**不含 odt** → 该样本不会被 Smoke 接受（`Smoke.target` 为空 → 产品态启动）。因此本步的验证方式改为 **recents 路径**：先在沙箱写一条指向 `sample.odt` 的 recents 记录再启动：
```bash
# 宿主机写 JSON → hdc file send（避免多层引号在 hdc shell 里被吃）
cat > /tmp/recents-probe.json <<'EOF'
[{"id":1,"pin":0,"name":"sample.odt","path":"/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/sample.odt","type":66,"modifyed":"2026-09-11 00:00:00"}]
EOF
$HDC -t $DEV file send /tmp/recents-probe.json $BASE/recents.json
$HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice"   # 普通启动（非验收态）
# 在欢迎页点该 recents 条目（手指）
$HDC -t $DEV shell "grep -E 'FMT_NOTICE|OPEN_RECENT_EXTBAD' $LOG"
```
Expected: `OPEN_RECENT_EXTBAD label=sample.odt ext=odt` + `FMT_NOTICE 暂不支持该格式：sample.odt`。
（最后清理：`$HDC -t $DEV shell "rm -f $BASE/sample.odt $BASE/recents.json"`）

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/pages/EditorPage.ets entry/src/main/ets/pages/DocTabHost.ets entry/src/main/ets/common/smoke.ets
git commit -m "refactor: 残留扩展名硬编码清理（tab 主题色/验收白名单查表）+ 不支持格式显式提示"
```

---

### Task 7: 回归 case 与文档

**Files:**
- Modify: `scripts/onlyoffice/tests/cases.tsv`
- Modify: `scripts/onlyoffice/tests/README.md`

- [ ] **Step 1: 先采基线（不许凭想象写判据）**

对 9 个新 case 逐个采基线——参数取自 Step 2 表格，先跑一遍看**真实标签**：

```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
DEV=192.168.1.6:33363
BASE=/data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files
for ARGS in 'm7accept=1;m7file=sample.doc' 'm7accept=1;m7file=sample.xls' \
            'm7accept=1;m7file=sample.ppt' 'm7accept=1;m7file=sample.rtf' \
            'm7accept=1;m7file=sample.txt' 'm7accept=1;m7file=sample.csv' \
            'm7accept=1;m7file=sample.rtf;m7auto=1' 'm7accept=1;m7file=sample.csv;m7auto=1' \
            'm7accept=1;m7file=sample.doc;m7auto=1'; do
  echo "== $ARGS =="
  $HDC -t $DEV shell aa force-stop app.fuqidian.pureoffice
  $HDC -t $DEV shell ": > $BASE/web_console.txt"
  $HDC -t $DEV shell "aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7args '$ARGS'"
  sleep 45
  $HDC -t $DEV shell "grep -E 'OPEN_X2T|LSO_OPEN_DOCUMENT_OK|LSO_DIOPEN_OK|LSO_KICK_SERVERID|SAVE_BIN|FMT_DIALOG|SAVE_AS_DIALOG' $BASE/web_console.txt"
done
```

把每种格式实际出现的**成功标签**抄下来（word 族与 cell/slide 族的打开标签不同），作为 Step 2 判据的依据。

- [ ] **Step 2: 写 cases.tsv 新行**

在 `cases.tsv` 文件末尾追加（**标签以 Step 1 实采为准，下面为预期形态**）：

```
# —— 格式扩展（2026-09-11）：旧 Office 二进制 + 轻量文本 ——
#   打开链对全部格式同构（x2t 按扩展名自动选转换器 → doct_bin）；判据取各族成功标签
open-doc|m7accept=1;m7file=sample.doc|90|PROF_SNAP|LSO_OPEN_DOCUMENT_OK|OPEN_X2T_FAIL|doc 打开（旧二进制 → word 族 doct_bin）
open-xls|m7accept=1;m7file=sample.xls|180|PROF_SNAP|LSO_DIOPEN_OK|OPEN_X2T_FAIL|xlxs 打开（cell 族）
open-ppt|m7accept=1;m7file=sample.ppt|180|PROF_SNAP|LSO_DIOPEN_OK|OPEN_X2T_FAIL|ppt 打开（slide 族）
open-rtf|m7accept=1;m7file=sample.rtf|90|PROF_SNAP|LSO_OPEN_DOCUMENT_OK|OPEN_X2T_FAIL|rtf 打开
open-txt|m7accept=1;m7file=sample.txt|90|PROF_SNAP|LSO_OPEN_DOCUMENT_OK|OPEN_X2T_FAIL|txt 打开（纯文本导入）
open-csv|m7accept=1;m7file=sample.csv|180|PROF_SNAP|LSO_DIOPEN_OK|OPEN_X2T_FAIL|csv 打开
#   保存：rtf/csv 可原地回写；doc 不可 → 必须出现格式提示且**不得回写源文件**
save-rtf|m7accept=1;m7file=sample.rtf;m7auto=1|120|SAVE_BIN_BACK|SAVE_BIN_X2T,SAVE_BIN_OUT|BAD:|rtf 原地保存（{\rtf 头校验通过）
save-csv|m7accept=1;m7file=sample.csv;m7auto=1|180|SAVE_BIN_BACK|SAVE_BIN_X2T,SAVE_BIN_OUT|BAD:|csv 原地保存（非空校验通过）
save-doc|m7accept=1;m7file=sample.doc;m7auto=1|120|FMT_DIALOG_ON|SAVE_BIN_X2T,FMT_DIALOG_ON|SAVE_BIN_URI,SAVE_BIN_BACK|doc 保存被提示拦下（禁止回写原 .doc）
```

注意 `open-xls` 一行的说明列有 typo（`xlxs`）——写文件时写成 `xls`。

- [ ] **Step 3: 跑新 case 验证判据正确**

Run:
```bash
OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/tests/regression.sh --case open-doc
OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/tests/regression.sh --case save-doc
```
Expected: 均为 `PASS`。任一 FAIL → 看 `out/<runid>/<id>.log` 实际标签，修正 cases.tsv 判据（判据错）或回到对应 Task 修代码（真回归）。

- [ ] **Step 4: 更新 README 覆盖表**

在 `scripts/onlyoffice/tests/README.md` §2 覆盖表加一行：

```markdown
| 格式扩展 | `open-doc` / `open-xls` / `open-ppt` / `open-rtf` / `open-txt` / `open-csv`、`save-rtf` / `save-csv` / `save-doc` | 新格式打开链 + 原地保存 + 不可原地保存格式的提示拦截（`save-doc` 反向断言 `SAVE_BIN_URI` 必须不出现） |
```

并在 §3.3 目视类补一条：
```markdown
- **格式扩展**：`sample.doc`/`sample.xls`/`sample.ppt`/`sample.rtf`/`sample.txt`/`sample.csv` 逐个打开核对渲染；
  `.doc/.xls/.ppt/.txt` 保存须弹「格式不支持保存」→ 确认后系统保存框默认名换新后缀
```

- [ ] **Step 5: 跑全量回归**

Run: `OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/tests/regression.sh`
Expected: `总计：19/19 PASS`（原 10 + 新 9）。有 FAIL → 逐 case 看日志修复；**原有 10 case 必须全绿**（三格式不得退化）。

- [ ] **Step 6: Commit**

```bash
git add scripts/onlyoffice/tests/cases.tsv scripts/onlyoffice/tests/README.md
git commit -m "test: 格式扩展回归 case（打开 ×6 / 保存 ×3）+ README 覆盖表更新"
```

---

### Task 8: 收尾验证与文档

**Files:**
- Modify: `docs/ONLYOFFICE_OHOS_FEATURE_MATRIX.md`（若含格式支持描述）

- [ ] **Step 1: 手工矩阵（系统 UI 类，需手指）**

按 `tests/README.md` §3.1 逐项验证并在纸上记录结果：
1. 欢迎页「打开」→ 系统选择器能看到 9 种后缀（`.doc`/`.xls`/`.ppt` 出现在过滤列表）
2. `sample.doc` 编辑 → 保存 → 提示「继续」→ 系统保存框默认名 `sample.docx` → 落盘 → tab 标题变 `.docx` → **再保存不弹提示**
3. 同 2 验 `sample.xls`（默认名 `sample.xlsx`）、`sample.ppt`（`sample.pptx`）、`sample.txt`（`sample.docx`）
4. `sample.rtf` / `sample.csv` 编辑 → 保存 → **无提示**、直接回写成功；重开内容正确
5. 提示框点「取消」→ 不落盘、文档留在原地；随后关闭 tab 仍弹未保存守卫
6. recents 列表：新格式条目图标正确（`.doc` Word 图标 / `.xls` Excel 图标 / `.ppt` PPT 图标）
7. 打印：`sample.doc` 打开 → 打印 → 系统打印界面弹出（验证 bin2pdf 与源格式无关）

- [ ] **Step 2: 保真度记录（如实写，不粉饰）**

对 `sample.doc`/`sample.xls`/`sample.ppt` 三样本，逐项对比"x2t 转换渲染"与"原文件在其他软件中的样子"。把差异（字体替换、排版偏移、对象丢失等）**追加到本计划文档末尾**（新建 `## 实测记录（2026-09-11）` 一节）——没有差异也要写明"逐项一致"。

- [ ] **Step 3: 更新功能矩阵文档**

若 `docs/ONLYOFFICE_OHOS_FEATURE_MATRIX.md` 里有"支持格式：docx/xlsx/pptx"一类描述，改为九种并标注"旧格式/OOXML 之外保存时转为 OOXML"。

- [ ] **Step 4: 提交并汇报**

```bash
git add docs/
git commit -m "docs: 格式扩展实测记录与功能矩阵更新"
```
向用户汇报：19/19 回归结果、手工矩阵结果、保真度差异清单、已知限制（csv 丢格式 / txt 无格式 / 旧格式转存）。

---

## 自审记录

- **spec 覆盖**：§3 范围 → Task 1/2；§4 数据模型 → Task 1；§5 打开链 → Task 3；§6 保存链 → Task 4/5；§7 拒绝路径 → Task 6；§9 测试 → Task 2/7/8；§8 已知限制 → Task 8 Step 2/3 ✓
- **与 spec 的差异（有意）**：spec §6 提到的新字段 `awaitingFormatConfirm` 由现有 `closeGuardDefer.awaitingSaveAs` 复用替代（少一个状态、与守卫机制同源），已在 Task 5 Step 4/5/6 写明。
- **类型一致性**：`specOf` / `pickerSuffixes` / `editorAppOf` / `needsSaveAsPrompt` / `checkSaveOut` 五个函数在 Task 1 定义，Task 3/4/5/6 使用处名称一致；`doSaveAs(ctx, outBuf, forceExt?)` 在 Task 4 改签名、Task 5 调用处传三参 ✓
