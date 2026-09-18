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
const SFNT_TTC = 0x74746366;

/** 字体集合容器（.ttc）：多 face 共用一个文件，需 face 索引才能定位其中一个。
 *  导入链没有传递索引的通路（注册给引擎的只有文件名）→ 调用方据此给专门提示。 */
export function isTtcCollection(u8: Uint8Array): boolean {
  if (u8.length < 4) {
    return false;
  }
  return u32(new DataView(u8.buffer, u8.byteOffset, u8.byteLength), 0) === SFNT_TTC;
}

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
