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
  /** 打开链附加 x2t 参数（XML 片段，空串 = 无）。CSV 必须给：x2t 的
   *  processDownloadFile 对 CSV/TSV/SCSV 源要求编码与分隔符**二者都非空**，
   *  否则转换方向判定失败（CSV 被特判成 NEED_PARAMS，真机实测 0x80041359）；
   *  而 .csv 扩展名不会自动填分隔符，无 BOM 的 UTF-8 也测不出编码
   *  （getEncodingByContent 只认 BOM，无 BOM 返回 -1）。
   *  46 = codePage 65001(UTF-8)，4 = TCSVD_COMMA。
   *  固定值取舍：无 BOM 的 GBK CSV（Excel 中文导出常见）会按 UTF-8 解出乱码，
   *  分号/制表符分隔的会整行挤在一列——x2t 侧无从自动判定（同 getEncodingByContent
   *  只认 BOM），壳层嗅探留待后续；此处取中文环境最常见形态（UTF-8 + 逗号）。 */
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
}

/** 可打开格式表（新增格式 = 此处加一行 + 备样本 + 回归 case） */
const FORMATS: FormatSpec[] = [
  { ext: 'docx', family: 'word', fileType: 'docx', recentType: 0x41, saveExt: 'docx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'doc', family: 'word', fileType: 'docx', recentType: 0x42, saveExt: 'docx', check: 'zip', openBinTo: 0x2001, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'rtf', family: 'word', fileType: 'docx', recentType: 0x44, saveExt: 'rtf', check: 'rtf', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'txt', family: 'word', fileType: 'docx', recentType: 0x45, saveExt: 'docx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'xlsx', family: 'cell', fileType: 'xlsx', recentType: 0x101, saveExt: 'xlsx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'xls', family: 'cell', fileType: 'xlsx', recentType: 0x102, saveExt: 'xlsx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'csv', family: 'cell', fileType: 'xlsx', recentType: 0x104, saveExt: 'csv', check: 'size', openBinTo: 0x2002,
    saveFrom: 0x2002, saveTo: 0x104,
    openExtra: '<m_nCsvTxtEncoding>46</m_nCsvTxtEncoding><m_nCsvDelimiter>4</m_nCsvDelimiter>' },
  { ext: 'pptx', family: 'slide', fileType: 'pptx', recentType: 0x81, saveExt: 'pptx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' },
  { ext: 'ppt', family: 'slide', fileType: 'pptx', recentType: 0x82, saveExt: 'pptx', check: 'zip', openBinTo: 0, saveFrom: 0, saveTo: 0, openExtra: '' }
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
