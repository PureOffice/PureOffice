import { resourceManager } from '@kit.LocalizationKit';

const BASE_DIR = 'onlyoffice/';

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
  return 'application/octet-stream';
}

// 把 onlyoffice://xxx 映射到 rawfile 路径 onlyoffice/xxx
function pathToRawFile(rawUrl: string): string {
  let p = rawUrl.replace(/^onlyoffice:\/\/+/, '');
  p = decodeURIComponent(p);
  // 去掉查询串/锚点
  const q = p.indexOf('?');
  if (q >= 0) {
    p = p.substring(0, q);
  }
  if (!p.startsWith(BASE_DIR)) {
    p = BASE_DIR + p;
  }
  return p;
}

/**
 * 拦截 onlyoffice:// 请求，从 rawfile 同步读取内容并返回 WebResourceResponse。
 * 前端资源完全本地化，不经过系统网络/明文放行限制。
 */
export function loadRaw(
  request: WebResourceRequest,
  resMgr: resourceManager.ResourceManager
): WebResourceResponse {
  const url = request.getRequestUrl();
  const rawPath = pathToRawFile(url);
  try {
    const raw = resMgr.getRawFileContentSync(rawPath);
    // Uint8Array 转成精确长度 ArrayBuffer
    const ab: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);
    const resp = new WebResourceResponse();
    resp.setResponseMimeType(mimeTypeFor(rawPath));
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(ab);
    return resp;
  } catch (e) {
    console.error('rawfile miss: ' + rawPath + ' ' + String(e));
    const resp = new WebResourceResponse();
    resp.setResponseMimeType('text/plain');
    resp.setResponseEncoding('utf-8');
    resp.setResponseData('404: ' + url);
    return resp;
  }
}
