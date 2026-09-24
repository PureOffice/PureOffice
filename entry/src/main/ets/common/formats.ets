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
  /** 打开链显式目标格式（CANVAS_* 内部二进制枚举，OfficeFileFormats.h:151）；
   *  0 = 不需要，x2t 按输入扩展名走方向表。doc/csv 非 0——x2t 的方向表把
   *  「.doc→.bin」判为 TCD_DOC2DOCT_BIN、「.csv→.bin」判为 TCD_CSV2XLST_BIN，
   *  而 fromInputParams 的 switch 缺这两个 case（落到 default 即
   *  CONVERT_PARAMS，真机实测 0x80041358），其余格式的 TCD_*2*_BIN case 齐全。
   *  显式给出格式对后 x2t 不再查方向表，改走 fromDocument/fromSpreadsheet
   *  「先落 OOXML 目录、再出内部二进制」的通路——该通路对 CANVAS_* 目标有
   *  docx_dir2doct_bin / xlsx_dir2xlst_bin 分派。必须与 recentType 成对下发：
   *  只给 From 会让 x2t 的格式判定整体失败（getConversionDirection 返回
   *  TCD_ERROR），比不传更糟。 */
  openBinTo: number;
  /** 打开链附加 x2t 参数（XML 片段，空串 = 无）。
   *  CSV 必须给：x2t 的 processDownloadFile 对 CSV/TSV/SCSV 源要求编码与分隔符
   *  **二者都非空**，否则方向判定失败（特判成 NEED_PARAMS，真机实测 0x80041359）；
   *  而 .csv 扩展名不会自动填分隔符，无 BOM 时 x2t 也测不出编码
   *  （getEncodingByContent 只认 BOM）。
   *  CSV 行的该字段留空：参数由 openExtraFor() 按**文件字节**嗅探生成——表内写死
   *  只能覆盖 UTF-8+逗号一种形态，Excel 导出的 GBK（解成乱码）与分号/制表符分隔
   *  （整行挤一列）都会坏（见 csvOpenExtra）。 */
  openExtra: string;
  /** 保存链显式格式对（[源, 目标]，0 = 不需要——x2t 按目标扩展名走方向表）。
   *  保存链的源是内部二进制（doct_bin/xlst_bin/pptt_bin），不是原文件格式。
   *  csv 需要：方向表把「xlst_bin→.csv」判为 TCD_XLST_BIN2CSV，而
   *  fromInputParams 的 switch 缺这个 case（落 default 返 CONVERT_PARAMS，
   *  真机实测 0x80041358）；显式给「CANVAS_SPREADSHEET → CSV」后走
   *  fromXlstBin 的 xlst_bin2csv 分支（该分支存在、无需额外参数）。
   *  与 openBinTo 同理必须成对下发。 */
  saveFrom: number;
  saveTo: number;
  /** 保存只保留文本内容（csv：编辑器里新加的合并单元格/颜色/列宽写不进纯文本）
   *  → 保存前提示确认（官方 Excel 保存 csv 亦提示）。false = 无此限制 */
  lossySave: boolean;
}

/** 可打开格式表（新增格式 = 此处加一行 + 备样本 + 回归 case） */
const FORMATS: FormatSpec[] = [
  { ext: 'docx', family: 'word', fileType: 'docx', recentType: 0x41, saveExt: 'docx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'doc', family: 'word', fileType: 'docx', recentType: 0x42, saveExt: 'docx', check: 'zip', openBinTo: 0x2001, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'rtf', family: 'word', fileType: 'docx', recentType: 0x44, saveExt: 'rtf', check: 'rtf', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'txt', family: 'word', fileType: 'docx', recentType: 0x45, saveExt: 'docx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'xlsx', family: 'cell', fileType: 'xlsx', recentType: 0x101, saveExt: 'xlsx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'xls', family: 'cell', fileType: 'xlsx', recentType: 0x102, saveExt: 'xlsx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'csv', family: 'cell', fileType: 'xlsx', recentType: 0x104, saveExt: 'csv', check: 'size', openBinTo: 0x2002,
    saveFrom: 0x2002, saveTo: 0x104,
    openExtra: '',
    lossySave: true },
  { ext: 'pptx', family: 'slide', fileType: 'pptx', recentType: 0x81, saveExt: 'pptx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false },
  { ext: 'ppt', family: 'slide', fileType: 'pptx', recentType: 0x82, saveExt: 'pptx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '', lossySave: false }
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

/**
 * 系统文件选择器过滤项（DocumentSelectOptions.fileSuffixFilters）。
 *
 * **必须是单个元素**：该字段的每个元素 = 选择器「文件格式」下拉里的一个**选项**，
 * 弹窗打开时只默认选中第一项——按后缀逐个传（9 个元素）时，用户打开弹窗只看得到
 * .docx 文件，要选 pptx 得自己发现并切换右上角下拉（用户实测反馈「没法选择 pptx
 * 等文件类型」）。单个元素内后缀用逗号分隔（d.ts 原文：Multiple document suffixes
 * separated by a comma (,) are allowed **in an option**）→ 一个选项覆盖全部支持
 * 后缀，打开即见全部支持格式的文件。
 * 元素形式 =「描述|后缀,…」：竖线前是下拉里显示的选项名，无竖线则显示后缀串。
 *
 * 注意与保存对话框的 fileSuffixChoices（DocumentSaveOptions）区分：那个的每元素
 * 同样是「保存类型」下拉里的一项，但保存目标本就只有一个（saveExt 一对一映射，
 * 不能原地保存的格式只能落 OOXML），单元素即预期形态（见 EditorPage.doSaveAs）。
 */
export function pickerFilterOption(): string[] {
  return ['支持的文件|' + pickerSuffixes().join(',')];
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

/** 保存是否会丢弃格式（原地保存但只留文本——需提示确认，见 FormatSpec.lossySave） */
export function isLossySave(ext: string): boolean {
  const f = specOf(ext);
  return f !== null && f.lossySave;
}

// —— CSV 打开参数嗅探 ——
// 为什么在壳层做：x2t 的 getEncodingByContent 只认 BOM（无 BOM 返回 -1）、
// getDelimiterByContent 未被调用（processDownloadFile 里那段在 if (false) 内），
// 而编码与分隔符任一为空即判转换失败——拿到完整文件字节的壳层是唯一能补上的地方。

/** x2t 编码索引：UnicodeConverter_Encodings.h 的 Encodings[].Index
 *  （CSVReader 对 UTF-8/16/32 另有 46/48/50 的显式分支，与表值一致） */
const CSV_ENC_UTF8 = 46;      // Index 46 = 65001 UTF-8
const CSV_ENC_GBK = 18;       // Index 18 = 936 GBK
const CSV_ENC_UTF16LE = 48;   // Index 48 = 1200 UTF-16LE
const CSV_ENC_UTF16BE = 49;   // Index 49 = 1201 UTF-16BE

/** x2t 分隔符枚举（X2tConverter/src/cextracttools.h TCSVD_*） */
const CSV_DELIM_TAB = 1;
const CSV_DELIM_SEMICOLON = 2;
const CSV_DELIM_COMMA = 4;

/** 嗅探取样上限：字节数（覆盖表头与若干数据行即可）/ 分隔符统计行数 */
const CSV_SNIFF_BYTES = 8192;
const CSV_SNIFF_LINES = 10;

/**
 * 字节序列是否为合法 UTF-8（只看前 CSV_SNIFF_BYTES）。
 * 严格版：拒绝 overlong、代理区、超 U+10FFFF——此判据用于**区分 GBK 与 UTF-8**，
 * 放宽会让 GBK 字节对（两个编码的字节范围有交集）碰巧过关。
 */
function isUtf8Bytes(buf: Uint8Array): boolean {
  const lim = buf.byteLength < CSV_SNIFF_BYTES ? buf.byteLength : CSV_SNIFF_BYTES;
  let i = 0;
  while (i < lim) {
    const b = buf[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    let need = 0;
    let cp = 0;
    let min = 0;
    if (b >= 0xC2 && b <= 0xDF) {
      need = 1;
      cp = b & 0x1F;
      min = 0x80;
    } else if (b >= 0xE0 && b <= 0xEF) {
      need = 2;
      cp = b & 0x0F;
      min = 0x800;
    } else if (b >= 0xF0 && b <= 0xF4) {
      need = 3;
      cp = b & 0x07;
      min = 0x10000;
    } else {
      // 0x80-0xC1 与 0xF5-0xFF 都不是合法起始字节
      return false;
    }
    if (i + need >= lim) {
      // 序列跨取样边界：证据不足，按「不判错」收手（余下字节不再看）
      break;
    }
    for (let k = 1; k <= need; k++) {
      const c = buf[i + k];
      if (c < 0x80 || c > 0xBF) {
        return false;
      }
      cp = (cp << 6) | (c & 0x3F);
    }
    if (cp < min || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF) {
      return false;
    }
    i += need + 1;
  }
  return true;
}

/**
 * 编码嗅探：BOM 优先，无 BOM 用「是否合法 UTF-8」二选一。
 * 判据可靠性：GBK 汉字同时满足「首字节落进 UTF-8 起字节区间 0xC2-0xDF」与
 * 「续字节落进 0x80-0xBF」的概率约 1/12（GBK 首字节 0x81-0xFE 中的 30/126、
 * 续字节 0x40-0xFE 中的 64/190）——整份中文 CSV 全部「碰巧合法」的概率趋近零。
 */
function sniffCsvEncoding(buf: Uint8Array): number {
  if (buf.byteLength >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) {
    return CSV_ENC_UTF8;
  }
  if (buf.byteLength >= 2 && buf[0] === 0xFF && buf[1] === 0xFE) {
    return CSV_ENC_UTF16LE;
  }
  if (buf.byteLength >= 2 && buf[0] === 0xFE && buf[1] === 0xFF) {
    return CSV_ENC_UTF16BE;
  }
  return isUtf8Bytes(buf) ? CSV_ENC_UTF8 : CSV_ENC_GBK;
}

/**
 * 分隔符嗅探：取前若干行，选「每行出现次数一致且 > 0」的候选（并列取次数多者）；
 * 无满足者兜底逗号（单列 CSV 即无分隔符的情形）。
 * 只判逗号/分号/制表符——x2t 枚举里另有冒号与空格，那两种在正文里太常见，
 * 判错的代价大于不判。UTF-16 的 ASCII 字符隔字节存放，先剥掉 0x00 位再统一统计。
 */
function sniffCsvDelimiter(buf: Uint8Array, enc: number): number {
  let sample = buf;
  if (enc === CSV_ENC_UTF16LE || enc === CSV_ENC_UTF16BE) {
    const src = buf.byteLength < CSV_SNIFF_BYTES * 2 ? buf.byteLength : CSV_SNIFF_BYTES * 2;
    const out = new Uint8Array(src >> 1);
    const off = enc === CSV_ENC_UTF16LE ? 0 : 1;
    for (let i = 0; i < out.length; i++) {
      out[i] = buf[i * 2 + off];
    }
    sample = out;
  }
  const lim = sample.byteLength < CSV_SNIFF_BYTES ? sample.byteLength : CSV_SNIFF_BYTES;
  const starts: number[] = [];
  const ends: number[] = [];
  let from = 0;
  for (let i = 0; i < lim && starts.length < CSV_SNIFF_LINES; i++) {
    if (sample[i] === 0x0A) {
      starts.push(from);
      ends.push(i);
      from = i + 1;
    }
  }
  if (starts.length === 0) {
    return CSV_DELIM_COMMA;
  }
  const codes: number[] = [0x09, 0x3B, 0x2C];
  const ids: number[] = [CSV_DELIM_TAB, CSV_DELIM_SEMICOLON, CSV_DELIM_COMMA];
  let best = CSV_DELIM_COMMA;
  let bestCount = 0;
  for (let c = 0; c < codes.length; c++) {
    let first = -1;
    let even = true;
    for (let j = 0; j < starts.length; j++) {
      let n = 0;
      for (let i = starts[j]; i < ends[j]; i++) {
        if (sample[i] === codes[c]) {
          n++;
        }
      }
      if (first < 0) {
        first = n;
      } else if (n !== first) {
        even = false;
        break;
      }
    }
    if (even && first > bestCount) {
      best = ids[c];
      bestCount = first;
    }
  }
  return best;
}

/** CSV 打开参数（编码 + 分隔符，按文件字节嗅探） */
function csvOpenExtra(buf: Uint8Array): string {
  const enc = sniffCsvEncoding(buf);
  const dlm = sniffCsvDelimiter(buf, enc);
  return '<m_nCsvTxtEncoding>' + enc + '</m_nCsvTxtEncoding>'
    + '<m_nCsvDelimiter>' + dlm + '</m_nCsvDelimiter>';
}

/** 打开链附加参数唯一入口：CSV 按字节嗅探（表内 openExtra 留空），其余取表值 */
export function openExtraFor(spec: FormatSpec, buf: Uint8Array): string {
  if (spec.ext === 'csv') {
    return csvOpenExtra(buf);
  }
  return spec.openExtra;
}

/** RTF 头「{\rtf」的字节 */
const RTF_HEAD: number[] = [0x7B, 0x5C, 0x72, 0x74, 0x66];

/** ECMA-376 密文容器头（CFB/OLE2 魔数）。密码保护文档的字节是 CFB 容器而非 zip
 *  ——加密保存（x2t m_sSavePassword）产出的 docx/xlsx/pptx 均以此开头，
 *  天然通不过 zip/rtf 魔数判据，故在判据前放行（2026-09-12 实测：密文产物
 *  被 ZIPBAD 拦下致保存失败）。本工程保存链的明文产物恒为 zip 或 rtf，出现
 *  CFB 只可能是密文。 */
const CFB_HEAD: number[] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

/** 字节是否为 CFB/OLE2 容器（密文 OOXML） */
export function isEncryptedContainer(buf: Uint8Array): boolean {
  if (buf.byteLength < CFB_HEAD.length) {
    return false;
  }
  for (let i = 0; i < CFB_HEAD.length; i++) {
    if (buf[i] !== CFB_HEAD[i]) {
      return false;
    }
  }
  return true;
}

/**
 * 保存产物校验（按 check 分派）：null = 通过；否则返回失败标签（调用方打日志）。
 * 'size'（csv 纯文本无稳定魔数）只拦空产物——内容正确性由真机回读验证。
 */
export function checkSaveOut(buf: Uint8Array, check: string): string | null {
  if (buf.byteLength === 0) {
    return 'EMPTY';
  }
  if (isEncryptedContainer(buf)) {
    // 密文产物：CFB 容器合法（zip/rtf 魔数均不适用——加密后的字节不是 zip）
    return null;
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
