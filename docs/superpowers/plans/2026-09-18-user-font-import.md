# 用户自导入字体 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户从欢迎页导入本机字体文件（.ttf/.otf），导入后新打开的文档里字体下拉出现该字体并可正常排版渲染，重启后仍可用。

**Architecture:** 导入段（ArkTS：picker → sfnt 解析 → 沙箱 `userFonts/` + 清单 JSON）→ 注册段（页面加载时 URL 参数携带清单，`20_bridge.js` 在注入 `__fonts_files`/`__fonts_infos` 时追加用户字体行）→ 供给段（`09_fonts.js` 并入装填清单，字节走新增的 `onlyoffice/userfonts/` 拦截前缀读沙箱）。注册行名 = 字体内部 name 表 family 名，自动满足引擎「行名 == face 内部名」契约。

**Tech Stack:** ArkTS（`@kit.CoreFileKit` picker/fileIo、`resourceManager`）、ascshim 注入层（JS）、ArkWeb `onInterceptRequest`、sdkjs 字体链。

**设计文档：** `docs/superpowers/specs/2026-09-18-user-font-import-design.md`（本计划实现它；下方「与设计文档的差异」列出计划阶段修正的三处）

---

## 与设计文档的差异（计划阶段核实后的修正）

1. **不需要改 `ascBridge.ets`**：`execCommand` 已由 `AscNativeDispatch.invoke`（`ascBridge.ets:180-186`）透传给 `ShellCommandHandler.onCommand` → `EditorPage.onTabCommand`（`EditorPage.ets:97-114, 292`）。新增 `font:import` 只需在 `onTabCommand` 加分支。设计文档 §9 的「改 ascBridge.ets」一行作废。
2. **URL 参数元素格式**：`[file, family, weight, italic]`（`file` 已含扩展名 `<id>.ttf|.otf`）。设计文档 §4.2 写的 `[id, family, weight, italic, subfamily]` 里的 `subfamily` 不参与引擎注册，去掉；`id` 由 `file` 蕴含。
3. **超限行为**：清单已达 32 项时**拒绝导入**并提示（设计文档 §5 原写"导入仍成功、超出不注册"——拒绝更简单且用户可预期；32 个是个人使用够不着的量）。

## 文件结构

| 文件 | 职责 | 类型 |
|---|---|---|
| `entry/src/main/ets/common/sfnt.ets` | sfnt/truetype 容器解析：family/字重/斜体/VF/CFF 判定（纯函数，无 IO） | 新建 |
| `entry/src/main/ets/common/userFonts.ets` | 导入流程、沙箱清单读写、URL 参数编码 | 新建 |
| `entry/src/main/ets/common/rawfileLoader.ets` | `onlyoffice/userfonts/<file>` → 沙箱读 + XOR | 改 |
| `entry/src/main/ets/pages/EditorPage.ets` | `font:import` 命令、`editorUrl()` 拼接清单参数 | 改 |
| `scripts/onlyoffice/build_editors_ohos.py` | 生成 `rawfile/onlyoffice/fontrows.json`（内置行名，重名检查数据源） | 改 |
| `scripts/onlyoffice/desktop/src/20_bridge.js` | 追加用户字体注册行 | 改 |
| `scripts/onlyoffice/desktop/src/09_fonts.js` | 装填清单并入用户字体 | 改 |
| `scripts/onlyoffice/desktop/src/40_save.js` | 欢迎页侧栏「导入字体」入口 | 改 |

**构建/装机（每个任务后如无特别说明，只用编译验证）：**

```bash
# 编译（严禁 clean——会删 build/core3d 的 libx2t.a）
/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -3
# 期望：BUILD SUCCESSFUL
```

**真机（Task 9 专用）：**

```bash
OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh
hdc -t 192.168.1.6:33363 shell "cat /data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt" | grep LSO_UFONT
```

---

## Task 1: sfnt 解析器（`common/sfnt.ets`）

**Files:** Create `entry/src/main/ets/common/sfnt.ets`

- [ ] **Step 1: 写解析器**

```ts
/**
 * sfnt.ets —— TrueType/OpenType 容器的最小解析（用户自导入字体用）。
 *
 * 为什么必须解析而不是用文件名：引擎契约（build_editors_ohos.make_cjk_subset 注释
 * 实证）——注册给引擎的行名必须等于字体 face 内部 name 表的 family 名，不一致时
 * 渲染槽匹配失败，**整 run 不绘制**（连拉丁字符一起消失）。所以家族名只能从文件里读。
 *
 * 越界/非法结构一律返回 null（调用方按"不是有效字体"拒绝），不抛异常。
 */

export interface SfntInfo {
  family: string;
  subfamily: string;
  weight: number;
  italic: boolean;
  /** 含 fvar 表（可变字体）——引擎无静态实例化路径，导入侧拒绝 */
  isVariable: boolean;
  /** OTTO 容器（CFF 轮廓）——记录用，渲染兼容性由真机验收判定 */
  isCff: boolean;
}

const TAG_NAME = 0x6e616d65;
const TAG_OS2 = 0x4f532f32;
const TAG_HEAD = 0x68656164;
const TAG_FVAR = 0x66766172;
const SFNT_TTF = 0x00010000;
const SFNT_OTTO = 0x4f54544f;
const SFNT_TRUE = 0x74727565;

function u16(dv: DataView, off: number): number {
  if (off < 0 || off + 2 > dv.byteLength) {
    return -1;
  }
  return dv.getUint16(off, false);
}

function u32(dv: DataView, off: number): number {
  if (off < 0 || off + 4 > dv.byteLength) {
    return -1;
  }
  return dv.getUint32(off, false);
}

/** name 记录优先级：Windows 英文 > Windows 其他语言 > Unicode > Mac Roman */
function nameScore(platformId: number, encodingId: number, languageId: number): number {
  if (platformId === 3 && encodingId === 1 && languageId === 0x0409) {
    return 100;
  }
  if (platformId === 3 && encodingId === 1) {
    return 90;
  }
  if (platformId === 3) {
    return 80;
  }
  if (platformId === 0) {
    return 70;
  }
  if (platformId === 1 && encodingId === 0) {
    return 60;
  }
  return 10;
}

function decodeName(u8: Uint8Array, dv: DataView, off: number, len: number,
  platformId: number): string {
  if (len <= 0 || off < 0 || off + len > dv.byteLength) {
    return '';
  }
  let s = '';
  if (platformId === 3 || platformId === 0) {
    // Windows / Unicode：UTF-16BE
    for (let i = 0; i + 1 < len; i += 2) {
      const c = dv.getUint16(off + i, false);
      if (c !== 0) {
        s += String.fromCharCode(c);
      }
    }
    return s;
  }
  // Mac Roman 等：字体名几乎全是 ASCII，按单字节取
  for (let i = 0; i < len; i++) {
    const c = u8[off + i];
    if (c !== 0) {
      s += String.fromCharCode(c);
    }
  }
  return s;
}

/** 解析 sfnt 容器；非字体/结构非法返回 null */
export function parseSfnt(u8: Uint8Array): SfntInfo | null {
  try {
    if (u8.length < 12) {
      return null;
    }
    const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const tag = u32(dv, 0);
    if (tag !== SFNT_TTF && tag !== SFNT_OTTO && tag !== SFNT_TRUE) {
      return null;
    }
    const numTables = u16(dv, 4);
    if (numTables <= 0 || numTables > 512) {
      return null;
    }
    let nameOff = -1;
    let os2Off = -1;
    let headOff = -1;
    let hasFvar = false;
    for (let i = 0; i < numTables; i++) {
      const rec = 12 + i * 16;
      if (rec + 16 > u8.length) {
        break;
      }
      const t = u32(dv, rec);
      const off = u32(dv, rec + 8);
      const len = u32(dv, rec + 12);
      if (off < 0 || len < 0) {
        continue;
      }
      if (t === TAG_NAME) {
        nameOff = off;
      } else if (t === TAG_OS2) {
        os2Off = off;
      } else if (t === TAG_HEAD) {
        headOff = off;
      } else if (t === TAG_FVAR) {
        hasFvar = true;
      }
    }
    if (nameOff < 0) {
      return null;
    }
    const cnt = u16(dv, nameOff + 2);
    const strBase = nameOff + u16(dv, nameOff + 4);
    if (cnt <= 0 || cnt > 4096) {
      return null;
    }
    let famScore = -1;
    let fam = '';
    let subScore = -1;
    let sub = '';
    let typoFamScore = -1;
    let typoFam = '';
    let typoSubScore = -1;
    let typoSub = '';
    for (let i = 0; i < cnt; i++) {
      const r = nameOff + 6 + i * 12;
      if (r + 12 > u8.length) {
        break;
      }
      const pid = u16(dv, r);
      const eid = u16(dv, r + 2);
      const lid = u16(dv, r + 4);
      const nid = u16(dv, r + 6);
      const nlen = u16(dv, r + 8);
      const noff = u16(dv, r + 10);
      if (nid !== 1 && nid !== 2 && nid !== 16 && nid !== 17) {
        continue;
      }
      const txt = decodeName(u8, dv, strBase + noff, nlen, pid);
      if (txt.length === 0) {
        continue;
      }
      const sc = nameScore(pid, eid, lid);
      if (nid === 1 && sc > famScore) {
        famScore = sc;
        fam = txt;
      } else if (nid === 2 && sc > subScore) {
        subScore = sc;
        sub = txt;
      } else if (nid === 16 && sc > typoFamScore) {
        typoFamScore = sc;
        typoFam = txt;
      } else if (nid === 17 && sc > typoSubScore) {
        typoSubScore = sc;
        typoSub = txt;
      }
    }
    const family = typoFam.length > 0 ? typoFam : fam;
    const subfamily = typoSub.length > 0 ? typoSub : sub;
    if (family.length === 0) {
      return null;
    }
    let weight = 400;
    let italic = false;
    if (os2Off >= 0) {
      const w = u16(dv, os2Off + 4);
      if (w > 0) {
        weight = w;
      }
      const fsSel = u16(dv, os2Off + 62);
      if (fsSel > 0 && (fsSel & 0x01) !== 0) {
        italic = true;
      }
    }
    if (headOff >= 0) {
      const ms = u16(dv, headOff + 44);
      if (ms > 0 && (ms & 0x02) !== 0) {
        italic = true;
      }
    }
    return {
      family: family,
      subfamily: subfamily,
      weight: weight,
      italic: italic,
      isVariable: hasFvar,
      isCff: tag === SFNT_OTTO
    };
  } catch (e) {
    return null;
  }
}
```

- [ ] **Step 2: 编译验证**

Run: `/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -3`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 3: 用 Python 侧对照值备好真机验收样本（不写文件，仅记录期望）**

```bash
python3 -c "
from fontTools.ttLib import TTFont
for p in ['entry/src/main/resources/rawfile/onlyoffice/fonts/FandolKai.ttf']:
    f = TTFont(p, fontNumber=0, lazy=True)
    n = f['name']
    print(p, '| family(ID1,3,1,0x409)=', n.getDebugName(1), '| sub(ID2)=', n.getDebugName(2),
          '| weight=', f['OS/2'].usWeightClass, '| italic=', bool(f['head'].macStyle & 2))
"
```
Expected: 打印 FandolKai 的家族名与字重（真机 Task 9 导入同名字体后，日志里的值应与之一致）

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/common/sfnt.ets
git commit -m "feat(font): sfnt 解析器（family/字重/斜体/VF 判定，用户字体导入前置）"
```

---

## Task 2: 构建期内置行名清单（`fontrows.json`）

**Files:** Modify `scripts/onlyoffice/build_editors_ohos.py`（`install_licenses` 定义处 ~:670 附近加函数，`main()` :1168 附近调用）

- [ ] **Step 1: 加生成函数与调用**

在 `install_licenses()` 定义之后新增：

```python
def write_font_rows():
    """内置字体行名清单 → rawfile/onlyoffice/fontrows.json。

    为什么单独出这份数据：引擎注册行名（FONT_INFOS 第 0 列）只在构建期知道，而
    ArkTS 导入侧要在用户选完文件的当下判断「这个家族名已被内置占用」——不导出
    就只能硬编码或漏检。含随包字体行与系统字体行。
    """
    out = os.path.join(DST, 'fontrows.json')
    names = [row[0] for row in FONT_INFOS]
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(names, f, ensure_ascii=False)
    print('fontrows.json: %d 行 → %s' % (len(names), out))
```

在 `main()` 里 `install_licenses()` 调用之后加一行：

```python
    # 7.56 内置字体行名清单（用户导入字体的重名检查数据源）
    write_font_rows()
```

（`json` 已在该文件导入——若未导入则加 `import json`。）

- [ ] **Step 2: 跑装配并验证产物**

Run: `python3 scripts/onlyoffice/build_editors_ohos.py 2>&1 | tail -5`
Expected: 输出含 `fontrows.json: <N> 行 →`

Run: `python3 -c "import json; d=json.load(open('entry/src/main/resources/rawfile/onlyoffice/fontrows.json')); print(len(d), d[:5])"`
Expected: 打印行数（应为 FONT_INFOS 行数）与含 `'Arial'`、`'宋体'` 等行名的前 5 项

- [ ] **Step 3: Commit**

```bash
git add scripts/onlyoffice/build_editors_ohos.py
git commit -m "feat(font): 构建期导出内置字体行名清单 fontrows.json（导入重名检查数据源）"
```

---

## Task 3: 清单与导入（`common/userFonts.ets`）

**Files:** Create `entry/src/main/ets/common/userFonts.ets`（依赖 Task 1 的 `sfnt.ets`、既有 `bytes.ets`、Task 2 的 `fontrows.json`）

- [ ] **Step 1: 写导入与清单模块**

```ts
/**
 * userFonts.ets —— 用户自导入字体：落盘、清单、URL 参数编码。
 *
 * 存储（沙箱 filesDir/userFonts/）：
 *   <id>.ttf|.otf   字体本体（id = 内容指纹，见 fontId）
 *   index.json      {"v":1,"fonts":[{id,file,family,subfamily,weight,italic}]}
 *
 * 本模块只管"把用户选中的字体变成沙箱里的一份声明"；注册进引擎字体表是页面侧的
 * 事（ascshim 20_bridge 读 URL 参数 lsofonts —— 注册表必须早于 sdk-all.js 的
 * checkAllFonts() 就位，页面加载时同步可得的通道只有 URL）。
 *
 * JSON 读写沿用 recents.ets 的 ArkTS 惯例（Object 取字段 + 显式转换）。
 */
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { readFileBuf, writeFileBuf, u8ToStr, bufToB64 } from './bytes';
import { parseSfnt } from './sfnt';

export interface UserFont {
  id: string;
  file: string;
  family: string;
  subfamily: string;
  weight: number;
  italic: boolean;
}

export interface ImportResult {
  ok: boolean;
  msg: string;
}

const SUB = 'userFonts';
const IDX = '/index.json';
const MAX_FONTS = 32;

function dirOf(filesDir: string): string {
  return filesDir + '/' + SUB;
}

/** 内容指纹：FNV-1a 32 位 + 字节长度（去重与文件名用，非安全用途） */
function fontId(u8: Uint8Array): string {
  let h = 0x811C9DC5;
  for (let i = 0; i < u8.length; i++) {
    h = (h ^ u8[i]) >>> 0;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return u8.length.toString(16) + '-' + h.toString(16);
}

/** 读清单；文件缺失/损坏 → [] */
export function listFonts(filesDir: string): UserFont[] {
  const out: UserFont[] = [];
  try {
    const ab = readFileBuf(dirOf(filesDir) + IDX);
    if (ab === null) {
      return out;
    }
    const parsed = JSON.parse(u8ToStr(new Uint8Array(ab))) as Record<string, Object>;
    const arr = parsed['fonts'] as Array<Record<string, Object>>;
    if (arr === undefined || arr === null) {
      return out;
    }
    for (const r of arr) {
      const fam = String(r['family'] ?? '');
      const file = String(r['file'] ?? '');
      if (fam.length === 0 || file.length === 0) {
        continue;
      }
      out.push({
        id: String(r['id'] ?? ''),
        file: file,
        family: fam,
        subfamily: String(r['subfamily'] ?? ''),
        weight: Number(r['weight'] ?? 400),
        italic: Number(r['italic'] ?? 0) !== 0
      });
    }
  } catch (e) {
    return out;
  }
  return out;
}

function writeIndex(filesDir: string, list: UserFont[]): boolean {
  try {
    const f = fs.openSync(dirOf(filesDir) + IDX,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, JSON.stringify({ v: 1, fonts: list }));
    fs.closeSync(f);
    return true;
  } catch (e) {
    return false;
  }
}

/** 内置字体行名（fontrows.json；读不到 → 空表=不做重名拦截，不阻断导入） */
function builtinRows(resMgr: resourceManager.ResourceManager): string[] {
  const out: string[] = [];
  try {
    const raw = resMgr.getRawFileContentSync('onlyoffice/fontrows.json') as Uint8Array;
    const arr = JSON.parse(u8ToStr(raw)) as Array<Object>;
    for (const s of arr) {
      out.push(String(s));
    }
  } catch (e) {
    return out;
  }
  return out;
}

/**
 * 导入一个字体（系统 picker 单选）。
 * 失败原因全部走返回值文案（调用方 toast），不做抛异常。
 */
export async function importViaPicker(ctx: common.UIAbilityContext, filesDir: string,
  resMgr: resourceManager.ResourceManager): Promise<ImportResult> {
  try {
    const dvp = new picker.DocumentViewPicker(ctx);
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    // 单元素 + 逗号分隔（多元素=下拉里多个选项且只默认选中第一个，用户看不到 .otf）
    opts.fileSuffixFilters = ['字体文件|.ttf,.otf'];
    const uris = await dvp.select(opts);
    if (uris.length === 0) {
      return { ok: false, msg: '已取消导入' };
    }
    const ab = readFileBuf(uris[0]);
    if (ab === null) {
      return { ok: false, msg: '读取文件失败' };
    }
    const u8 = new Uint8Array(ab);
    const info = parseSfnt(u8);
    if (info === null) {
      return { ok: false, msg: '不是有效的字体文件（仅支持 .ttf / .otf）' };
    }
    if (info.isVariable) {
      return { ok: false, msg: '暂不支持可变字体（Variable Font）' };
    }
    const fam = info.family.trim();
    if (fam.length === 0) {
      return { ok: false, msg: '字体内部缺少家族名，无法导入' };
    }
    if (builtinRows(resMgr).indexOf(fam) >= 0) {
      return { ok: false, msg: '字体「' + fam + '」已内置，无需导入' };
    }
    try {
      fs.mkdirSync(dirOf(filesDir));
    } catch (e) {
      // 目录已存在
    }
    const id = fontId(u8);
    const list = listFonts(filesDir);
    for (const f of list) {
      if (f.id === id) {
        return { ok: true, msg: '字体「' + f.family + '」之前已导入过' };
      }
      if (f.family === fam) {
        return { ok: false, msg: '字体「' + fam + '」已导入过（同名不同文件，请先移除旧文件）' };
      }
    }
    if (list.length >= MAX_FONTS) {
      return { ok: false, msg: '已达导入上限 ' + MAX_FONTS + ' 个' };
    }
    const file = id + (info.isCff ? '.otf' : '.ttf');
    if (!writeFileBuf(dirOf(filesDir) + '/' + file, u8)) {
      return { ok: false, msg: '写入失败（存储空间不足？）' };
    }
    list.push({
      id: id, file: file, family: fam, subfamily: info.subfamily,
      weight: info.weight, italic: info.italic
    });
    if (!writeIndex(filesDir, list)) {
      return { ok: false, msg: '清单写入失败' };
    }
    return { ok: true, msg: '已导入「' + fam + '」，新打开的文档即可使用' };
  } catch (e) {
    return { ok: false, msg: '导入失败：' + String(e) };
  }
}

/**
 * 清单 → URL 参数值（空清单返回 ''）。元素 [file, family, weight, italic]。
 * 编码链：JSON → encodeURIComponent（转纯 ASCII）→ base64；页面侧逆序解回。
 * base64 含 '+' '/' '='，调用方拼 URL 时需再 encodeURIComponent（见 EditorPage.editorUrl）。
 */
export function encodeUrlParam(filesDir: string): string {
  const list = listFonts(filesDir);
  if (list.length === 0) {
    return '';
  }
  const items: Object[][] = [];
  for (const f of list) {
    items.push([f.file, f.family, f.weight, f.italic ? 1 : 0]);
  }
  const ascii = encodeURIComponent(JSON.stringify(items));
  const u8 = new Uint8Array(ascii.length);
  for (let i = 0; i < ascii.length; i++) {
    u8[i] = ascii.charCodeAt(i) & 0x7f;
  }
  return bufToB64(u8);
}
```

- [ ] **Step 2: 编译验证**

Run: `/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -3`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 3: Commit**

```bash
git add entry/src/main/ets/common/userFonts.ets
git commit -m "feat(font): 用户字体导入与清单（picker→解析→沙箱落盘→URL 参数编码）"
```

---

## Task 4: 拦截层供给（`rawfileLoader.ets`）

**Files:** Modify `entry/src/main/ets/common/rawfileLoader.ets`（前缀常量与 `loadSystemFont` 之上加；`loadRaw` 的 `SYSTEM_FONT_PREFIX` 分支之后加）

- [ ] **Step 1: 加前缀常量与读取函数**

在 `SYSTEM_FONT_PREFIX` 常量定义之后加：

```ts
// 用户导入字体（2026-09-18）：http://localhost/onlyoffice/userfonts/<file>
// → 沙箱 filesDir/userFonts/<file>（导入段落盘，见 common/userFonts.ets）。
// 与系统字体桥同构：读出的字节在 ArkTS 侧 XOR 前 32B，页面 09_fonts 装填链
// 统一 xorDecode —— 装填链对"随包/系统/用户"三类字体零分支。
const USER_FONT_PREFIX = 'onlyoffice/userfonts/';
```

在 `loadSystemFont` 函数之后加：

```ts
/**
 * 用户导入字体：沙箱 filesDir/userFonts/<file> → ArrayBuffer（加密态）。
 * 文件名仅纯名（同 loadSystemFont 的防穿越校验）。
 */
function loadUserFont(filesDir: string, rel: string, log: (m: string) => void): ArrayBuffer | null {
  if (rel.length === 0 || rel.indexOf('/') >= 0 || rel.indexOf('\\') >= 0
    || rel.indexOf('..') >= 0) {
    log('userfont bad path: ' + rel);
    return null;
  }
  const fp = filesDir + '/userFonts/' + rel;
  try {
    const st = fs.statSync(fp);
    if (st.isDirectory()) {
      log('userfont dir: ' + fp);
      return null;
    }
    const o = fs.openSync(fp, fs.OpenMode.READ_ONLY);
    const ab = new ArrayBuffer(st.size);
    fs.readSync(o.fd, ab);
    fs.closeSync(o);
    const u8 = new Uint8Array(ab);
    const n = Math.min(32, u8.length);
    for (let i = 0; i < n; i++) {
      u8[i] ^= FONT_GUID[i % 16];
    }
    return ab;
  } catch (e) {
    log('userfont miss: ' + fp + ' ' + String(e));
    return null;
  }
}
```

- [ ] **Step 2: 分发处加分支**

在 `loadRaw` 的 `if (p.startsWith(SYSTEM_FONT_PREFIX)) { ... }` 整段之后加：

```ts
  if (p.startsWith(USER_FONT_PREFIX)) {
    const ab = loadUserFont(filesDir, p.substring(USER_FONT_PREFIX.length), _log);
    if (ab === null) {
      return notFoundResp(url);
    }
    _log('userfont hit: ' + p + ' bytes=' + ab.byteLength);
    const resp = new WebResourceResponse();
    resp.setResponseMimeType('font/ttf');
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(ab);
    return readyResp(resp);
  }
```

- [ ] **Step 3: 编译验证**

Run: `/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -3`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/common/rawfileLoader.ets
git commit -m "feat(font): 拦截层新增 userfonts 前缀（沙箱供给，XOR 与系统字体桥同构）"
```

---

## Task 5: 命令与 URL 参数（`EditorPage.ets`）

**Files:** Modify `entry/src/main/ets/pages/EditorPage.ets`（:244-279 `editorUrl`、:292 起 `onTabCommand`、新私有方法）

- [ ] **Step 1: `editorUrl()` 追加清单参数**

在 `editorUrl()` 的 `return url;` 之前（`if (this.m7Target.length > 0) { ... }` 块之后）插入：

```ts
    // 用户自导入字体清单（common/userFonts.encodeUrlParam；空清单不拼）。
    // 注册表必须在 sdk-all.js checkAllFonts() 之前就位（之后表被删），页面加载时
    // 同步可得的通道只有 URL——故走参数而非桥/异步请求（见 20_bridge 对应段）。
    const uf = encodeUrlParam(this.hostFilesDir);
    if (uf.length > 0) {
      url = url + '&lsofonts=' + encodeURIComponent(uf);
    }
```

文件顶部 import 区加：`import { encodeUrlParam, importViaPicker } from '../common/userFonts';`

- [ ] **Step 2: `onTabCommand` 加 `font:import` 分支**

在 `onTabCommand` 内（`if (cmd === 'open:folder') { ... }` 之前）加：

```ts
    if (cmd === 'font:import') {
      // 欢迎页侧栏「导入字体」（40_save 注入项 → AscNative.execCommand）。
      // 导入只落沙箱与清单；生效在**新打开的文档**（URL 参数注册，见 editorUrl）。
      this.importUserFonts();
      return 'true';
    }
```

- [ ] **Step 3: 加私有方法**

在 `pickFileForWeb`/`doPickFile` 附近加：

```ts
  /**
   * 导入用户字体（欢迎页「导入字体」入口）。结果用 toast 回报——导入是低频操作，
   * 不引入页面侧 UI 依赖（欢迎页/文档页都可发起，toast 与 ctx 无关）。
   */
  private async importUserFonts(): Promise<void> {
    const aCtx = getContext(this) as common.UIAbilityContext;
    const rm = this.resourceManager;
    if (rm === undefined) {
      promptAction.showToast({ message: '导入失败：资源未就绪', duration: 3000 });
      return;
    }
    const r = await importViaPicker(aCtx, this.hostFilesDir, rm);
    this.arkLog('LSO_UFONT_IMPORT ok=' + r.ok + ' msg=' + r.msg);
    promptAction.showToast({ message: r.msg, duration: 3000 });
  }
```

（`hostFilesDir` 已存在；`promptAction`/`common` 已 import。）

- [ ] **Step 4: 编译验证**

Run: `/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon 2>&1 | tail -3`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/pages/EditorPage.ets
git commit -m "feat(font): font:import 命令与 lsofonts URL 参数（导入结果 toast 回报）"
```

---

## Task 6: 页面侧注册（`20_bridge.js`）

**Files:** Modify `scripts/onlyoffice/desktop/src/20_bridge.js`（三表注入段 :8-14 之后）

- [ ] **Step 1: 加注册段**

在 `window["__fonts_ranges"] = @@FONT_RANGES_JSON@@;` 之后（同一 IIFE 内）加：

```js
  // ---- 0.2 用户自导入字体（2026-09-18）：URL 参数 lsofonts = base64(URI 编码的
  //      JSON 数组)，元素 [file, family, weight, italic]。三表刚注入、sdk-all.js
  //      尚未加载（checkAllFonts 未跑）——这是唯一能改注册表的时机（跑完即删表）。
  //      注册行四槽同索引（单文件通吃；先例 OpenSymbol 行）；行名 = 字体内部
  //      family 名（引擎契约：行名必须等于 face 内部名，故导入侧从 name 表读，
  //      见 common/sfnt.ets）。与内置行重名者跳过（ArkTS 导入侧已拦，此处兜底）。
  (function _userFonts() {
    try {
      var _m = /[?&]lsofonts=([^&]+)/.exec(window.location.search || '');
      if (!_m) { return; }
      var _arr = JSON.parse(decodeURIComponent(atob(decodeURIComponent(_m[1]))));
      var _files = window["__fonts_files"];
      var _infos = window["__fonts_infos"];
      var _n = 0, _skip = 0;
      for (var _i = 0; _i < _arr.length; ++_i) {
        var _it = _arr[_i];
        var _file = String(_it[0] || ''), _fam = String(_it[1] || '');
        if (!_file || !_fam) { continue; }
        var _dup = false;
        for (var _j = 0; _j < _infos.length; ++_j) {
          if (_infos[_j][0] === _fam) { _dup = true; break; }
        }
        if (_dup) { _skip++; continue; }
        _files.push(_file);
        var _idx = _files.length - 1;
        _infos.push([_fam, _idx, 0, _idx, 0, _idx, 0, _idx, 0]);
        _n++;
      }
      console.error('LSO_UFONT_REG n=' + _n + ' skip=' + _skip + ' total=' + _arr.length);
    } catch (_e) {
      console.error('LSO_UFONT_REG_ERR ' + String(_e));
    }
  })();
```

- [ ] **Step 2: 装配（把改动编进 ascshim.js）**

Run: `python3 scripts/onlyoffice/desktop/make_ascshim.py 2>&1 | tail -3`
Expected: 无错误；`ascshim.js` 重新生成

- [ ] **Step 3: 静态检查新段存在**

Run: `grep -c "LSO_UFONT_REG" entry/src/main/resources/rawfile/onlyoffice/ascshim.js`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add scripts/onlyoffice/desktop/src/20_bridge.js
git commit -m "feat(font): ascshim 注册用户字体行（URL 参数 lsofonts → __fonts_files/__fonts_infos）"
```

---

## Task 7: 装填并入（`09_fonts.js`）

**Files:** Modify `scripts/onlyoffice/desktop/src/09_fonts.js`（`IDS` 常量 :29-34 之后）

- [ ] **Step 1: 并入用户字体 ID**

在 `var IS_SYS = {...};` 之后加：

```js
  // 用户自导入字体（2026-09-18）：URL 参数 lsofonts 同时驱动本清单——注册行由
  //   20_bridge 追加（该段在 sdk 加载前执行、本段的装填在 g_font_files 建好后
  //   轮询触发，故两段时序天然错开）。元素 [file, family, weight, italic]，
  //   装填按 file 名（ID 即文件名，与 __fonts_files 一致）。
  try {
    var _ufm = /[?&]lsofonts=([^&]+)/.exec(window.location.search || '');
    if (_ufm) {
      var _ufa = JSON.parse(decodeURIComponent(atob(decodeURIComponent(_ufm[1]))));
      for (var _ufi = 0; _ufi < _ufa.length; ++_ufi) {
        var _uff = String(_ufa[_ufi][0] || '');
        if (_uff && IDS.indexOf(_uff) < 0) { IDS.push(_uff); }
      }
      console.error('LSO_UFONT_IDS n=' + IDS.length);
    }
  } catch (_ufe) { console.error('LSO_UFONT_IDS_ERR ' + String(_ufe)); }
```

- [ ] **Step 2: 预取 URL 加用户字体分支**

把 `prefetch()` 内的 `urls` 定义改为：

```js
      var urls = [
        (IS_SYS[ID] ? 'http://localhost/onlyoffice/systemfonts/'
                    : (ID.indexOf('-') > 0 && /\.(ttf|otf)$/i.test(ID)
                       ? 'http://localhost/onlyoffice/userfonts/'
                       : 'http://localhost/onlyoffice/fonts/')) + ID,
        '../../../../fonts/' + ID                    // 相对兜底（仅 rawfile；系统/用户字体 miss）
      ];
```

（用户字体 ID 形态 `<hex>-<hex>.ttf|otf`，与随包字体名（下划线/无连字符）区分。）

- [ ] **Step 3: 装配 + 静态检查**

Run: `python3 scripts/onlyoffice/desktop/make_ascshim.py 2>&1 | tail -3 && grep -c "LSO_UFONT_IDS" entry/src/main/resources/rawfile/onlyoffice/ascshim.js`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add scripts/onlyoffice/desktop/src/09_fonts.js
git commit -m "feat(font): 装填清单并入用户字体（userfonts 前缀预取）"
```

---

## Task 8: 欢迎页入口（`40_save.js`）

**Files:** Modify `scripts/onlyoffice/desktop/src/40_save.js`（3.10 欢迎页段 :419-464 之后）

- [ ] **Step 1: 加注入段**

在 `_hideWelcomeNav` IIFE 之后加：

```js
  // ---- 3.11 欢迎页「导入字体」入口（2026-09-18 用户需求）----
  // loginpage 侧栏是官方静态模板（panels.js），无插件位——clone 一个已存在的
  // .menu-item（用被 3.10 隐藏的「模板」项）保住官方样式，改文本与 action 后
  // 追加到 .tool-menu 末尾。点击 → AscNative.execCommand('font:import') →
  // EditorPage 走系统 picker（导入结果由 ArkTS toast 回报）。
  (function _injectFontImport() {
    try {
      var _fp = (window.location || {}).pathname || '';
      if (_fp.indexOf('/onlyoffice/index.html') < 0) { return; }
      var _fins = function() {
        if (document.getElementById('lso-import-font')) { return; }
        var _ftpl = document.querySelector('.tool-menu a[action="templates"]');
        if (!_ftpl || !_ftpl.closest) { return; }
        var _fli = _ftpl.closest('.menu-item');
        if (!_fli || !_fli.parentNode) { return; }
        var _fclone = _fli.cloneNode(true);
        _fclone.style.display = '';
        var _fa = _fclone.querySelector('a');
        if (!_fa) { return; }
        _fa.setAttribute('action', 'lsofonts');
        _fa.id = 'lso-import-font';
        // 文本节点替换（结构含图标 span + 文本，只改非空文本节点）
        for (var _fn = 0; _fn < _fa.childNodes.length; ++_fn) {
          var _fc = _fa.childNodes[_fn];
          if (_fc.nodeType === 3 && String(_fc.nodeValue || '').replace(/\s/g, '').length > 0) {
            _fc.nodeValue = '导入字体';
          }
        }
        _fa.addEventListener('click', function(_ev) {
          _ev.preventDefault();
          _ev.stopPropagation();
          try {
            if (window.AscNative && typeof window.AscNative._call === 'function') {
              window.AscNative._call('execCommand', ['font:import']);
            }
          } catch (_fe) { console.error('LSO_UFONT_ENTRY_CALL_ERR ' + String(_fe)); }
        });
        _fli.parentNode.appendChild(_fclone);
        console.error('LSO_UFONT_ENTRY ok');
      };
      var _fobs = new MutationObserver(_fins);
      if (document.body) {
        _fobs.observe(document.body, {childList: true, subtree: true});
      } else {
        document.addEventListener('DOMContentLoaded', function() {
          _fobs.observe(document.body, {childList: true, subtree: true});
        });
      }
      _fins();
    } catch (_fe2) { console.error('LSO_UFONT_ENTRY_ERR ' + String(_fe2)); }
  })();
```

- [ ] **Step 2: 自检登记**

在 `00_boot.js` 的 `EXPECT` 表里加 `userfonts: 'home'`（`about: 'home'` 一行之后）。

- [ ] **Step 3: 装配 + 静态检查**

Run: `python3 scripts/onlyoffice/desktop/make_ascshim.py 2>&1 | tail -3 && grep -c "LSO_UFONT_ENTRY" entry/src/main/resources/rawfile/onlyoffice/ascshim.js`
Expected: `2`（段内两处 console.error）

- [ ] **Step 4: Commit**

```bash
git add scripts/onlyoffice/desktop/src/40_save.js scripts/onlyoffice/desktop/src/00_boot.js
git commit -m "feat(font): 欢迎页侧栏「导入字体」入口（clone 官方项保样式 + 桥命令）"
```

---

## Task 9: 端到端真机验证

**Files:** 无代码改动（发现缺陷则回到对应 Task 修）

- [ ] **Step 1: 部署**

Run: `OHOS_DEV=192.168.1.6:33363 bash scripts/onlyoffice/deploy_ohos.sh 2>&1 | tail -8`
Expected: `== done ==`，install 段含 `install bundle successfully`

- [ ] **Step 2: 准备样本并推送到设备**

```bash
# 中文 ttf 样本（取随包字体之一改名，family 与内置行重名则换用系统字体文件）
hdc -t 192.168.1.6:33363 file send \
  entry/src/main/resources/rawfile/onlyoffice/fonts/FandolKai.ttf \
  /data/local/tmp/Download/OnlyOffice/Documents/TestFont.ttf
```
（另备：一个 `.ttc`、一个把 `.txt` 改名成 `.ttf` 的假文件，用于拒绝路径验收）

- [ ] **Step 3: 验收主链（真机手指操作 + 日志）**

1. 启动应用 → 欢迎页侧栏出现「导入字体」（截图确认，样式与相邻项一致）
2. 点「导入字体」→ 系统选择器出现，且**能同时看到 .ttf 与 .otf**（后缀过滤坑）
3. 选 `TestFont.ttf` → toast 提示（成功文案或「已内置」拒绝文案之一）
   - 若被拒（family 与内置重名）：换用系统目录里一个非内置名的字体再试
4. 主页新建 Word → 字体下拉出现该字体名（截图）
5. 选中该字体输入中文 → 字形**有内容**（非方块/非空白，与默认字体对比截图）
6. 杀进程重开 → 再新建 → 字体仍在（持久化）

日志判据（`hdc ... cat .../files/web_console.txt | grep -E "LSO_UFONT|FONT_WARM"`）：
- `LSO_UFONT_REG n=1 skip=0`（注册成功）
- `LSO_UFONT_IDS n=9`（装填清单 8+1）
- `userfont hit: onlyoffice/userfonts/<file> bytes=<n>`（拦截层供给）
- `FONT_WARM_FILLED id=<file> idx=… status=0`（装填成功）

- [ ] **Step 4: 边界用例**

| 用例 | 期望 |
|---|---|
| 导入 `.ttc` | 提示不支持（pickler 只列 .ttf/.otf，改名绕过时被解析器拒绝） |
| 导入假字体（.txt 改名） | 「不是有效的字体文件」 |
| 重复导入同一文件 | 「之前已导入过」且 `userFonts/` 不产生第二个文件 |
| 导入与内置同名字体 | 「已内置，无需导入」 |
| 关闭文档再开（同 tab） | 字体仍可用（URL 每次重新拼） |

- [ ] **Step 5: 回归**

- 三格式打开/编辑/保存各跑一遍（重点：保存链未受字体表追加影响）
- 随包字体（宋体/黑体/仿宋/楷体）与系统字体渲染不变（字体下拉截图对比）
- 打印链、放映、多 tab 不受影响

- [ ] **Step 6: 记录结论并提交（如有修复）**

```bash
# 验证结论写入 commit message 与记忆；代码修复单独提交
```

---

## 自审记录（计划阶段）

- **spec 覆盖**：设计 §4.1→Task 1、§4.2→Task 3、§4.3→Task 5、§4.4→Task 4、§4.5 三处→Task 6/7/8、§5 边界→Task 3 校验 + Task 9 Step 4、§6 日志→各 Task 判据、§7 验证→Task 9、§4.6 构建→Task 2。§9 交付物清单中 `ascBridge.ets` 一项经核实不需要（见「差异 1」）。
- **接口一致性**：`UserFont{id,file,family,subfamily,weight,italic}`、`encodeUrlParam(filesDir)`、`importViaPicker(ctx,filesDir,resMgr)`、URL 元素 `[file,family,weight,italic]` 在 Task 3/5/6/7 中一致。
- **已知未决**：CFF（.otf）渲染兼容性、字体下拉缩略图表现——两者都留到 Task 9 实测判定（设计 §8.3/§8.5）。
