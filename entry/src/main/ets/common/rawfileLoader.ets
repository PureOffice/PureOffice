import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { readSystemFontSync } from './x2t';

const BASE_DIR = 'onlyoffice/';
// 用户文件沙箱入口：http://localhost/userfile/<name> → filesDir/<name>
const USERFILE_PREFIX = 'userfile/';
// 引擎离线媒体：documentUrl='_offline_' 时引擎拼 <documentUrl>+'media/'+<name>，
// 请求落到 <当前页面目录>/_offline_media/<name>。字节不用我们解包——x2t 转换
// （pptx/docx→bin）时已把 */media/* 就地解到 <filesDir>/media/，保存链（bin→OOXML）
// 又从同一目录取图（DocxSerializer setSrcPath(bin 所在目录)）。本分支即官方 native
// 形态 GetImagesPath() 的等价物，只是走 HTTP 供给。用 lastIndexOf 定位：路径前缀
// 随编辑器而异（presentationeditor / spreadsheeteditor / texteditor）。详见记忆
// onlyoffice-image-pipeline。
const OFFLINE_MEDIA_SEG = '_offline_media/';
const MEDIA_DIR = 'media';
// 系统字体桥 v2（2026-09-07）：http://localhost/onlyoffice/systemfonts/<name>
// → NAPI native 读 /system/fonts/<name>（ArkTS fileIo 对系统根路径一律 ENOENT，
// native 层与 wine 同权可读；见 x2t.ets readSystemFontSync 头注）。
// 返回前 XOR 前 32B（guidOdttf 循环，同构建机 pre_xor_font 加密态）→ 页面
// 09_fonts.js xorDecode 统一还原装填（装填链零分支）。
const SYSTEM_FONT_PREFIX = 'onlyoffice/systemfonts/';
const FONT_GUID: number[] = [0xA0, 0x66, 0xD6, 0x20, 0x14, 0x96, 0x47, 0xFA,
  0x95, 0x69, 0xB8, 0x50, 0xB0, 0x41, 0x49, 0x48];

/**
 * 系统字体：native 读 /system/fonts/<name> → ArrayBuffer（加密态）。
 * 文件名仅纯名（native 侧同样防穿越检验）。
 */
function loadSystemFont(rel: string, log: (m: string) => void): ArrayBuffer | null {
  if (rel.indexOf('/') >= 0 || rel.indexOf('\\') >= 0 || rel.indexOf('..') >= 0) {
    log('systemfont bad path: ' + rel);
    return null;
  }
  const ab = readSystemFontSync(rel);
  if (ab === undefined || ab.byteLength === 0) {
    log('systemfont miss: /system/fonts/' + rel + ' (native)');
    return null;
  }
  // 与构建机 pre_xor_font 相同的加密态：前 32B XOR FONT_GUID（16 字节循环）
  const u8 = new Uint8Array(ab);
  const n = Math.min(32, u8.length);
  for (let i = 0; i < n; i++) {
    u8[i] ^= FONT_GUID[i % 16];
  }
  return ab;
}

function mimeTypeFor(path: string): string {
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.js')) return 'application/javascript';
  if (path.endsWith('.css')) return 'text/css';
  if (path.endsWith('.json')) return 'application/json';
  // 文档内嵌媒体（_offline_media 供给）：OOXML 包里的图片不一定是 png——
  // octet-stream 会被渲染器拒绝（同 wasm 那条 MIME 教训）
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
  if (path.endsWith('.gif')) return 'image/gif';
  if (path.endsWith('.webp')) return 'image/webp';
  if (path.endsWith('.bmp')) return 'image/bmp';
  if (path.endsWith('.tif') || path.endsWith('.tiff')) return 'image/tiff';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.woff')) return 'font/woff';
  if (path.endsWith('.woff2')) return 'font/woff2';
  if (path.endsWith('.ttf')) return 'font/ttf';
  // font/排版引擎 wasm（fonts.js fetch 后 WebAssembly.instantiateStreaming 要求
  // application/wasm，octet-stream 会 MIME mismatch 导致字体引擎加载失败——症状：页面空白/无字体）
  if (path.endsWith('.wasm')) return 'application/wasm';
  if (path.endsWith('.docx')) return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  if (path.endsWith('.xlsx')) return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  if (path.endsWith('.pptx')) return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  if (path.endsWith('.odt')) return 'application/vnd.oasis.opendocument.text';
  return 'application/octet-stream';
}

/**
 * 提取 URL 路径部分：先剥离 query/锚点再解码（decodeURIComponent 对畸形 % 编码抛
 * URIError——解析失败仅告警，返回原样本由调用侧 404 兜底）。
 * 入参形如 http://localhost/userfile/sample.docx?v=2 或 onlyoffice://webapps/...
 */
function urlPathOnly(rawUrl: string): string {
  let p = rawUrl;
  const m = p.match(/^https?:\/\/localhost\//);
  if (m !== null) {
    p = p.substring(m[0].length);
  } else {
    p = p.replace(/^onlyoffice:\/\/+/, '');
  }
  let q = p.indexOf('?');
  if (q < 0) {
    q = p.length;
  }
  let h = p.indexOf('#');
  if (h < 0 || h > q) {
    h = q;
  }
  p = p.substring(0, h);
  try {
    p = decodeURIComponent(p);
  } catch (e) {
    console.error('url decode err: ' + rawUrl);
  }
  return p;
}

/**
 * 沙箱单文件读取（用户文件 / 引擎媒体共用；label 只影响日志前缀）。
 * 防目录穿越：只允许单一文件名（不允许 / 和 ..）——媒体名来自引擎 URL，
 * 与用户文件名同等不可信。
 */
function loadUserFile(filesDir: string, rel: string, log: (m: string) => void,
  label: string = 'userfile'): ArrayBuffer | null {
  // 路径形态：<name> 或 <tab 目录>/<name>（tab 目录严格 t<数字>）。
  // 允许这一层前缀是因为 per-tab 改造后页面 XHR 要按 tab 取自己的临时产物
  //（userfile/t<id>/open-in.bin → filesDir/t<id>/open-in.bin；不隔离会让多 tab
  // 互踩，且名称相同的老文件会让读取静默拿到**陈旧内容**——见下方调用侧 size 校验）。
  // 其余仍只允许单一文件名（防目录穿越：媒体名/临时名来自引擎 URL，不可信）。
  let dir = filesDir;
  const slash = rel.indexOf('/');
  if (slash >= 0) {
    const seg = rel.substring(0, slash);
    if (!/^t[0-9]+$/.test(seg)) {
      log(label + ' bad path: ' + rel);
      return null;
    }
    dir = filesDir + '/' + seg;
    rel = rel.substring(slash + 1);
  }
  if (rel.length === 0 || rel.indexOf('/') >= 0 || rel.indexOf('\\') >= 0 || rel.indexOf('..') >= 0) {
    log(label + ' bad path: ' + rel);
    return null;
  }
  const fp = dir + '/' + rel;
  try {
    const st = fs.statSync(fp);
    if (st.isDirectory()) {
      log(label + ' dir: ' + fp);
      return null;
    }
    const o = fs.openSync(fp, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(st.size);
    fs.readSync(o.fd, buf);
    fs.closeSync(o);
    return buf;
  } catch (e) {
    log(label + ' miss: ' + fp + ' ' + String(e));
    return null;
  }
}

function notFoundResp(url: string): WebResourceResponse {
  const resp = new WebResourceResponse();
  resp.setResponseMimeType('text/plain');
  resp.setResponseEncoding('utf-8');
  resp.setResponseData('404: ' + url);
  resp.setResponseCode(404);
  resp.setReasonMessage('Not Found');
  resp.setResponseIsReady(true);
  return resp;
}

/**
 * 补全标准响应字段（官方 onInterceptRequest 示例要求）：
 * setResponseCode(200) + setReasonMessage + setResponseIsReady(true)。
 * 渲染器子资源（页面/JS/字体）对缺省字段容错，但文档下载 XHR（sdkjs asc_ajax，
 * responseType=arraybuffer）路径严格——缺 setResponseIsReady/status 会拿不到
 * 响应体（表现为编辑器 "Connection is lost" / 文档打开卡死）。
 */
function readyResp(resp: WebResourceResponse): WebResourceResponse {
  resp.setResponseCode(200);
  resp.setReasonMessage('OK');
  resp.setResponseIsReady(true);
  return resp;
}

// 把页面 URL 映射到 rawfile 路径 onlyoffice/xxx，支持两种形态：
//   http://localhost/onlyoffice/xxx  （标准 scheme，XHR/fetch 走正常 CORS 路径——实际使用）
//   onlyoffice://xxx                 （自定义 scheme；urlPathOnly 兼容剥离，当前无生产者）
function pathToRawFile(rawUrl: string): string {
  let p = urlPathOnly(rawUrl);
  if (!p.startsWith(BASE_DIR)) {
    p = BASE_DIR + p;
  }
  return p;
}

/**
 * 拦截请求。本地化四类 URL：
 *   http://localhost/onlyoffice/xxx → rawfile（前端资源，本地化）
 *   http://localhost/onlyoffice/systemfonts/<name> → /system/fonts/<name>（系统字体桥 v2，native 读）
 *   http://localhost/userfile/<name> → 沙箱 filesDir/<name>（用户文档，迭代 1 真文件打开链）
 *   <任意页面目录>/_offline_media/<name> → 沙箱 filesDir/media/<name>（文档内嵌媒体，
 *     x2t 转换时就地解包；见 OFFLINE_MEDIA_SEG 头注）
 * **非本地 URL 返回 null = 放行**（onInterceptRequest 语义：null 不拦截，继续默认网络栈）：
 *   AI 插件远程 API（https://api.openai.com/... 等自定义 provider）= 页面 fetch 直连
 *   （2026-09-07 方案 A，用户决策；ArkTS/native 不做代调——官方两条代调通道
 *   AscSimpleRequest / ai_onExternalFetch 在本部署均不存在，详见 engine.js 注释）。
 * filesDir 为 context.filesDir；目标不存在时返回 404 文本，不抛。
 * mediaDir 为**当前 tab 的**媒体目录（<工作目录>/media）——必须由调用方按其
 * tab 上下文传入：所有 tab 的工作文件同处一个 per-tab 目录（DocTabCtx.tabDir），
 * x2t 转换时把内嵌媒体解包到该目录下的 media/，故按 tab 取目录即天然隔离
 * （不传就会退化成全局目录 → 不同文档同名图互相覆盖）。
 * log：可选的 ArkTS 日志注入（EditorPage.arkLog → web_console.txt；缺省 console.error）。
 * 返回 null 时 _log 留痕供诊断。
 */
export function loadRaw(
  request: WebResourceRequest,
  resMgr: resourceManager.ResourceManager,
  filesDir: string,
  mediaDir: string,
  log?: (m: string) => void
): WebResourceResponse | null {
  const _log: (m: string) => void = log ?? ((m: string) => console.error(m));
  const url = request.getRequestUrl();
  // 放行判据：host ≠ localhost/127.0.0.1 且协议非 onlyoffice:（localhost 前缀含
  // 端口与路径；无端口裸 localhost 也放行——如 AI provider 指 http://localhost:11434，
  // 该请求同样走默认网络栈，与编辑器本地资源互不纠缠）。
  const p = urlPathOnly(url);
  // 官方模板库（oforms）快速失败：欢迎页会拉 templates/static-oforms 两个域名的
  // 模板清单与几百张缩略图——实测一次欢迎页加载产生 550 个外网请求（4.3s 内），
  // 同进程的编辑器页被拖到引擎 90s 未就绪（LSO_WAITFULL_GIVEUP → 编辑器白屏，
  // 2026-09-12 open-slide 偶发卡死实测）。离线应用不需要模板库 → 直接 404，
  // 不让它们进默认网络栈。**只挡这两个域名**：AI provider 等其它非本地 URL 照旧放行。
  if (/^https?:\/\/(templates|static-oforms)\.onlyoffice\.com\//.test(url)) {
    _log('oforms blocked: ' + url);
    return notFoundResp(url);
  }
  if (!/^https?:\/\/localhost(\/|$|\?|#)/.test(url) &&
      !/^https?:\/\/127\.0\.0\.1(\/|$|\?|#)/.test(url) &&
      !url.startsWith('onlyoffice://')) {
    _log('outer pass-through: ' + url + ' method=' + request.getRequestMethod());
    return null;
  }
  if (p.startsWith(SYSTEM_FONT_PREFIX)) {
    const ab = loadSystemFont(p.substring(SYSTEM_FONT_PREFIX.length), _log);
    if (ab === null) {
      return notFoundResp(url);
    }
    _log('systemfont hit: ' + p + ' bytes=' + ab.byteLength);
    const resp = new WebResourceResponse();
    resp.setResponseMimeType('font/ttf');
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(ab);
    return readyResp(resp);
  }
  if (p.startsWith(USERFILE_PREFIX)) {
    const ab = loadUserFile(filesDir, p.substring(USERFILE_PREFIX.length), _log);
    if (ab === null) {
      return notFoundResp(url);
    }
    _log('userfile hit: ' + p + ' bytes=' + ab.byteLength);
    const resp = new WebResourceResponse();
    resp.setResponseMimeType(mimeTypeFor(p));
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(ab);
    return readyResp(resp);
  }
  // 引擎离线媒体：<...>/_offline_media/<name> → filesDir/media/<name>
  // （必须先于 rawfile 分支——否则被 pathToRawFile 拼成 onlyoffice/webapps/...
  //  /_offline_media/... 而必然 miss，2026-09-12 实测日志即此形态）
  const mi = p.lastIndexOf(OFFLINE_MEDIA_SEG);
  if (mi >= 0) {
    const name = p.substring(mi + OFFLINE_MEDIA_SEG.length);
    const ab = loadUserFile(mediaDir, name, _log, 'media');
    if (ab === null) {
      return notFoundResp(url);
    }
    _log('media hit: ' + name + ' bytes=' + ab.byteLength);
    const resp = new WebResourceResponse();
    resp.setResponseMimeType(mimeTypeFor(name));
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(ab);
    return readyResp(resp);
  }
  const rawPath = pathToRawFile(url);
  try {
    const raw = resMgr.getRawFileContentSync(rawPath);
    // Uint8Array 转成精确长度 ArrayBuffer
    const ab: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);
    const resp = new WebResourceResponse();
    resp.setResponseMimeType(mimeTypeFor(rawPath));
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(ab);
    return readyResp(resp);
  } catch (e) {
    _log('rawfile miss: ' + rawPath + ' ' + String(e));
    return notFoundResp(url);
  }
}
