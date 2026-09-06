import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * bytes.ets —— 字节/文件基元工具（EditorPage 与 ascBridge 共用，2026-09-05 审查收敛：
 * 原 base64 解码、Uint8Array→string、open/read/close 三连与 x2t XML 拼装在各文件重复实现）。
 */

/** base64 → ArrayBuffer（ArkTS 无内置解码；文档字节经 bridge 上行） */
export function b64ToBuf(b64: string): ArrayBuffer {
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const clean = b64.replace(/[^A-Za-z0-9+/=]/g, '');
  let n = clean.indexOf('=');
  if (n < 0) {
    n = clean.length;
  }
  const pad = n % 4;
  const bytes = Math.floor(n / 4) * 3 + (pad === 2 ? 1 : pad === 3 ? 2 : 0);
  const out = new Uint8Array(bytes);
  let bi = 0;
  for (let i = 0; i < n; i += 4) {
    const c1 = B64.indexOf(clean.charAt(i));
    const c2 = B64.indexOf(clean.charAt(i + 1));
    const c3 = (i + 2 < n) ? B64.indexOf(clean.charAt(i + 2)) : 0;
    const c4 = (i + 3 < n) ? B64.indexOf(clean.charAt(i + 3)) : 0;
    const ch = (c1 << 18) | (c2 << 12) | (c3 << 6) | c4;
    out[bi++] = (ch >> 16) & 0xFF;
    if (bi < bytes) {
      out[bi++] = (ch >> 8) & 0xFF;
    }
    if (bi < bytes) {
      out[bi++] = ch & 0xFF;
    }
  }
  return out.buffer.slice(0, bytes);
}

/** Uint8Array → base64（ArkTS 手写循环，输出纯 A-Za-z0-9+/=；
 *  libfont Base64.decode 会跳过非法字符但 ';' 是长度前缀分隔符——手写仅标准字符集
 *  避免歧义。2026-09-05 新增：LoadFontBase64 桥（ArkTS→引擎字体流）。 */
export function bufToB64(u8: Uint8Array): string {
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < u8.length; i += 3) {
    const b0 = u8[i];
    const b1 = i + 1 < u8.length ? u8[i + 1] : -1;
    const b2 = i + 2 < u8.length ? u8[i + 2] : -1;
    out += B64.charAt(b0 >> 2);
    out += B64.charAt(((b0 & 0x3) << 4) | (b1 >= 0 ? (b1 >> 4) : 0));
    out += b1 >= 0 ? B64.charAt(((b1 & 0xF) << 2) | (b2 >= 0 ? (b2 >> 6) : 0)) : '=';
    out += b2 >= 0 ? B64.charAt(b2 & 0x3F) : '=';
  }
  return out;
}

/** Uint8Array → UTF-8 string（readFile/JSON 解析用） */
export function u8ToStr(u8: Uint8Array): string {
  // util.TextDecoder 是字节解码标准实现（原 String.fromCharCode 循环在 4 处重复）
  const dec = new util.TextDecoder('utf-8');
  return dec.decode(u8);
}

/** 读整个文件（stat/open/read/close 三连，close 保证执行；失败返回 null） */
export function readFileBuf(path: string): ArrayBuffer | null {
  // openSync 返回 fs.File（含 fd 的句柄），非数字——null 表示未打开
  let f: fs.File | null = null;
  try {
    const st = fs.statSync(path);
    if (st.isDirectory()) {
      return null;
    }
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(st.size);
    fs.readSync(f.fd, buf);
    return buf;
  } catch (e) {
    return null;
  } finally {
    if (f !== null) {
      try {
        fs.closeSync(f);
      } catch (ce) {
        // 关闭失败不影响结果
      }
    }
  }
}

/** 覆盖写文件（open/write/close 三连，close 保证执行；成功返回 true） */
export function writeFileBuf(path: string, data: ArrayBuffer | Uint8Array): boolean {
  let f: fs.File | null = null;
  try {
    f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    // writeSync 只收 ArrayBuffer | string（POC-2 实测拒 Uint8Array——直传会写出 0 字节，
    // 2026-09-06 app_version.json 0Byte 实证）；Uint8Array 先落成 ArrayBuffer 再传
    const buf = data instanceof Uint8Array
      ? data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)
      : data;
    fs.writeSync(f.fd, buf);
    return true;
  } catch (e) {
    return false;
  } finally {
    if (f !== null) {
      try {
        fs.closeSync(f);
      } catch (ce) {
        // 关闭失败不影响结果
      }
    }
  }
}

/** x2t 转换参数 XML 拼装（打开/保存链共用；路径为沙箱绝对路径） */
export function x2tXml(from: string, to: string): string {
  return `<Convert><m_sFileFrom>${from}</m_sFileFrom><m_sFileTo>${to}</m_sFileTo></Convert>`;
}
