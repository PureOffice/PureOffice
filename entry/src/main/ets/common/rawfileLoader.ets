import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const BASE_DIR = 'onlyoffice/';
// 用户文件沙箱入口：http://localhost/userfile/<name> → filesDir/<name>
const USERFILE_PREFIX = 'userfile/';

function mimeTypeFor(path: string): string {
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.js')) return 'application/javascript';
  if (path.endsWith('.css')) return 'text/css';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.png')) return 'image/png';
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

/** 用户文件：沙箱 filesDir/<name> → ArrayBuffer */
function loadUserFile(filesDir: string, rel: string, log: (m: string) => void): ArrayBuffer | null {
  // 防目录穿越：只允许单一文件名（不允许 / 和 ..）
  if (rel.indexOf('/') >= 0 || rel.indexOf('\\') >= 0 || rel.indexOf('..') >= 0) {
    log('userfile bad path: ' + rel);
    return null;
  }
  const fp = filesDir + '/' + rel;
  try {
    const st = fs.statSync(fp);
    if (st.isDirectory()) {
      log('userfile dir: ' + fp);
      return null;
    }
    const o = fs.openSync(fp, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(st.size);
    fs.readSync(o.fd, buf);
    fs.closeSync(o);
    return buf;
  } catch (e) {
    log('userfile miss: ' + fp + ' ' + String(e));
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
 * 拦截请求。两类 URL：
 *   http://localhost/onlyoffice/xxx → rawfile（前端资源，本地化）
 *   http://localhost/userfile/<name> → 沙箱 filesDir/<name>（用户文档，迭代 1 真文件打开链）
 * filesDir 为 context.filesDir；沙箱文件不存在时返回 404 文本，不抛。
 * log：可选的 ArkTS 日志注入（EditorPage.arkLog → web_console.txt；缺省 console.error）。
 */
export function loadRaw(
  request: WebResourceRequest,
  resMgr: resourceManager.ResourceManager,
  filesDir: string,
  log?: (m: string) => void
): WebResourceResponse {
  const _log: (m: string) => void = log ?? ((m: string) => console.error(m));
  const url = request.getRequestUrl();
  const p = urlPathOnly(url);
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
