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
