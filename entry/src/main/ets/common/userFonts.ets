/**
 * userFonts.ets —— 用户自导入字体：落盘、清单、URL 参数编码。
 *
 * 存储（沙箱 filesDir/userFonts/）：
 *   <id>.ttf|.otf   字体本体（id = 内容指纹，见 fontIdAsync）
 *   index.json      {"v":1,"fonts":[{id,file,family,subfamily,weight,italic}]}
 *
 * 本模块只管"把用户选中的字体变成沙箱里的一份声明"；注册进引擎字体表是页面侧的
 * 事（ascshim 20_bridge 读 URL 参数 lsofonts —— 注册表必须早于 sdk-all.js 的
 * checkAllFonts() 就位，之后表即被删，页面加载时同步可得的通道只有 URL）。
 *
 * JSON 读写沿用 recents.ets 的 ArkTS 惯例（Object 逐字段取 + 显式转换）。
 */
import { fileIo as fs, picker, hash } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { readFileBuf, readFileBufAsync, writeFileBufAsync, u8ToStr,
  bufToB64 } from './bytes';
import { parseSfnt, isTtcCollection } from './sfnt';
import { t } from './i18n';

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

/** 字体管理弹层的列表项：UI 只渲染字符串——尺寸格式化与 stat 都留在本模块，
 *  页面层不碰文件系统 */
export interface FontListItem {
  id: string;
  family: string;
  /** 副标题：`<subfamily> · <大小>`；subfamily 为空时只有大小；stat 失败为 — */
  sub: string;
}

const SUB = 'userFonts';
const IDX = '/index.json';
export const MAX_FONTS = 32;

function dirOf(filesDir: string): string {
  return filesDir + '/' + SUB;
}

/**
 * 内容指纹：字节长度 + 哈希前 8 位（去重与文件名用，非安全用途）。
 *
 * 用系统 native 哈希，不用 JS 逐字节循环——后者在 24.7MB 上要占住调用线程几百毫秒，
 * 导入期间界面整个冻住（连「导入中」都渲染不出来）。优先让 `file.hash` 直接读文件
 * （native 异步、调用线程零占用）；它不接受该路径形态时，退回对内存字节哈希
 * （native 同步，但比 JS 循环快一个量级）。
 *
 * 注意：id 与早期 FNV 版**不同**——同一文件在新旧版本算出的 id 不一样。去重的兜底
 * 是 family 同名判定（行为不变），早期导入的条目不受影响（id 只用于文件名与本次比较）。
 */
async function fontIdAsync(path: string, u8: Uint8Array): Promise<string> {
  let hx = '';
  try {
    hx = await hash.hash(path, 'sha256');
  } catch (e) {
    try {
      const hs = hash.createHash('sha256');
      hs.update(u8.buffer);
      hx = hs.digest();
    } catch (e2) {
      console.error('LSO_UFONT_HASH_ERR ' + String(e2));
      return '';
    }
  }
  return u8.length.toString(16) + '-' + hx.substring(0, 8).toLowerCase();
}

/** 读清单；文件缺失/损坏 → []（空表视为"没有导入过"） */
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

/** 内置字体行名（fontrows.json；读不到 → 空表 = 不做重名拦截，不阻断导入） */
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
 * 第一步：调系统 picker 单选一个字体文件，返回 uri（'' = 取消，含选择器异常）。
 *
 * 与第二步拆开，是为了让 UI 能区分「选择中」和「导入中」——合并成一个 await 时
 * 按钮只显示得出「导入中」，而那段里用户其实还停在系统选择器里，名不副实。
 */
export async function pickFontFile(ctx: common.UIAbilityContext): Promise<string> {
  try {
    const dvp = new picker.DocumentViewPicker(ctx);
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    // 单元素 + 逗号分隔（多元素 = 下拉里多个选项且只默认选中第一个，用户看不到 .otf）
    opts.fileSuffixFilters = [t($r('app.string.picker_filter_font')) + '|.ttf,.otf'];
    const uris = await dvp.select(opts);
    return uris.length === 0 ? '' : uris[0];
  } catch (e) {
    console.error('LSO_UFONT_PICK_ERR ' + String(e));
    return '';
  }
}

/**
 * 第二步：从 uri 导入（读文件 → 校验 → 落盘 → 写清单）。失败原因全部走返回值
 * 文案（调用方 toast），不抛异常。
 */
export async function importFontFile(filesDir: string,
  resMgr: resourceManager.ResourceManager, uri: string): Promise<ImportResult> {
  try {
    const ab = await readFileBufAsync(uri);
    if (ab === null) {
      return { ok: false, msg: t($r('app.string.font_err_read')) };
    }
    const u8 = new Uint8Array(ab);
    const info = parseSfnt(u8);
    if (info === null) {
      // .ttc 单独提示：它是「字体集合」容器（多个 face 共用一个文件），引擎按文件名
      // 加载整包、没有 face 索引通路（__fonts_files 只有文件名），硬塞会让字体出现在
      // 下拉里却渲染不出来——比明确拒绝更糟。故拒绝并说清替代做法。
      return {
        ok: false,
        msg: isTtcCollection(u8)
          ? t($r('app.string.font_err_ttc'))
          : t($r('app.string.font_err_invalid'))
      };
    }
    if (info.isVariable) {
      return { ok: false, msg: t($r('app.string.font_err_vf')) };
    }
    const fam = info.family.trim();
    if (fam.length === 0) {
      return { ok: false, msg: t($r('app.string.font_err_nofamily')) };
    }
    if (builtinRows(resMgr).indexOf(fam) >= 0) {
      return { ok: false, msg: t($r('app.string.font_err_builtin'), fam) };
    }
    try {
      fs.mkdirSync(dirOf(filesDir));
    } catch (e) {
      // 目录已存在
    }
    const id = await fontIdAsync(uri, u8);
    if (id.length === 0) {
      return { ok: false, msg: t($r('app.string.font_err_hash')) };
    }
    const list = listFonts(filesDir);
    for (const f of list) {
      if (f.id === id) {
        return { ok: true, msg: t($r('app.string.font_ok_dup'), f.family) };
      }
      if (f.family === fam) {
        return { ok: false, msg: t($r('app.string.font_err_dupname'), fam) };
      }
    }
    if (list.length >= MAX_FONTS) {
      return { ok: false, msg: t($r('app.string.font_err_limit'), MAX_FONTS) };
    }
    const file = id + (info.isCff ? '.otf' : '.ttf');
    if (!(await writeFileBufAsync(dirOf(filesDir) + '/' + file, u8))) {
      return { ok: false, msg: t($r('app.string.font_err_write')) };
    }
    list.push({
      id: id,
      file: file,
      family: fam,
      subfamily: info.subfamily,
      weight: info.weight,
      italic: info.italic
    });
    if (!writeIndex(filesDir, list)) {
      return { ok: false, msg: t($r('app.string.font_err_manifest')) };
    }
    return { ok: true, msg: t($r('app.string.font_ok_imported'), fam) };
  } catch (e) {
    return { ok: false, msg: t($r('app.string.font_err_import'), String(e)) };
  }
}

/**
 * 删除一个已导入字体：先从清单移除并写回，成功后再删磁盘文件。
 *
 * 顺序不可反：清单是数据源（下拉、URL 参数都从它来），先删文件再写清单一旦写失败，
 * 就留下「清单里有、文件没了」的幽灵条目——下拉里照常显示、选中后渲染不出来，
 * 且用户没有任何入口能清掉它。反过来最坏只留下清单外的孤儿文件：不注册、不装填、
 * 不显示，无害。
 *
 * 磁盘文件已不存在（ENOENT）按成功处理（磁盘以清单为准收敛，让用户点得掉）。
 * 非 ENOENT 的 unlink 失败也不报失败——此时清单已更新、条目对用户已不可见，
 * 报错只会让用户重试后得到「字体不存在」，更糟。
 */
export function removeFont(filesDir: string, id: string): ImportResult {
  try {
    const list = listFonts(filesDir);
    const rest: UserFont[] = [];
    let hit: UserFont | null = null;
    for (const f of list) {
      if (f.id === id) {
        hit = f;
      } else {
        rest.push(f);
      }
    }
    if (hit === null) {
      return { ok: false, msg: t($r('app.string.font_err_notfound')) };
    }
    if (!writeIndex(filesDir, rest)) {
      return { ok: false, msg: t($r('app.string.font_err_delmanifest')) };
    }
    try {
      fs.unlinkSync(dirOf(filesDir) + '/' + hit.file);
    } catch (e) {
      console.error('LSO_UFONT_UNLINK_ERR id=' + id + ' ' + String(e));
    }
    return { ok: true, msg: t($r('app.string.font_ok_deleted'), hit.family) };
  } catch (e) {
    return { ok: false, msg: t($r('app.string.font_err_delete'), String(e)) };
  }
}

/** 字节数 → 展示串（1024 进制）：<1KB 用 B；<1MB 用整数 KB；否则一位小数 MB */
function fmtFontSize(n: number): string {
  if (n < 1024) {
    return String(n) + ' B';
  }
  if (n < 1024 * 1024) {
    return String(Math.round(n / 1024)) + ' KB';
  }
  return (Math.round(n / (1024 * 1024) * 10) / 10).toFixed(1) + ' MB';
}

/**
 * 弹层列表数据：清单 + 现取的磁盘大小。stat 失败（字体文件被外部删掉）显示 —，
 * 但**该条仍要列出来**——用户得有入口把它删掉（removeFont 会收敛清单）。
 */
export function listFontItems(filesDir: string): FontListItem[] {
  const out: FontListItem[] = [];
  const dir = dirOf(filesDir);
  for (const f of listFonts(filesDir)) {
    let size = '—';
    try {
      size = fmtFontSize(fs.statSync(dir + '/' + f.file).size);
    } catch (e) {
      size = '—';
    }
    out.push({
      id: f.id,
      family: f.family,
      sub: f.subfamily.length > 0 ? (f.subfamily + ' · ' + size) : size
    });
  }
  return out;
}

/**
 * 清单 → URL 参数值（空清单返回 ''）。元素 [file, family, weight, italic]。
 * 编码链：JSON → encodeURIComponent（转纯 ASCII）→ base64；页面侧逆序解回
 * （20_bridge / 09_fonts 的 lsofonts 解析）。base64 含 '+' '/' '='，
 * 调用方拼 URL 时需再 encodeURIComponent（见 EditorPage.editorUrl）。
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
