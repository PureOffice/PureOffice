import { fileIo as fs } from '@kit.CoreFileKit';
import { readFileBuf, u8ToStr } from './bytes';

/**
 * recents.ets —— "最近打开"文件清单的单一实现（2026-09-05 审查收敛：
 * 原 EditorPage.appendRecent 与 ascBridge.localFileRecents 各维护一份读写与解析，
 * 且注释警告"两处必须同格式"——契约与实现分居两地必然漂移）。
 *
 * 文件：<filesDir>/recents.json —— EditorPage 打开文档时追加（打开过即"最近"），
 * ascBridge LocalFileRecents 读取（loginpage 呈现）。
 * 契约（loginpage utils.js parseRecent 消费；字段不可多不可少）：
 *   id(存为 fileid) / pin(置 pinid 符号) / name / path(绝对路径，名从路径尾截取)
 *   type(FileFormat 枚举整数: docx=0x41 xlsx=0x101 pptx=0x81) / modifyed(显示"最近打开")
 */

export const RECENT_TYPE_DOCX = 0x41;
export const RECENT_TYPE_XLSX = 0x101;
export const RECENT_TYPE_PPTX = 0x81;

/** recents.json 条目（字段名与 loginpage parseRecent 契约一致） */
export interface RecentItem {
  id: number;
  pin: number;
  name: string;
  path: string;
  type: number;
  modifyed: string;
}

const RECENTS_FILE = '/recents.json';

/**
 * 读取 recents.json：
 *   文件缺失/为空 → []（正常开始新列表）
 *   文件损坏/JSON 解析失败 → null（调用方**不得**据此重写文件——否则一条脏数据
 *   即清空整个"最近"，2026-09-05 审查修复）
 * modifyed 兜底用 ISO（与 appendRecent 写入同格式；locale 格式带非 ASCII 字符、
 * loginpage 渲染乱码——2026-09-04 踩坑，两处必须同格式）。
 */
export function readRecents(filesDir: string): RecentItem[] | null {
  try {
    const ab = readFileBuf(filesDir + RECENTS_FILE);
    if (ab === null) {
      return [];
    }
    const parsed = JSON.parse(u8ToStr(new Uint8Array(ab))) as Array<Record<string, Object>>;
    const now = modifyedNow();
    const arr: RecentItem[] = [];
    for (const r of parsed) {
      arr.push({
        id: Number(r['id'] ?? 0),
        pin: Number(r['pin'] ?? 0),
        name: String(r['name'] ?? ''),
        path: String(r['path'] ?? ''),
        type: Number(r['type'] ?? RECENT_TYPE_DOCX),
        modifyed: String(r['modifyed'] ?? now)
      });
    }
    return arr;
  } catch (e) {
    return null;
  }
}

/**
 * 删除一条最近记录（按 id——官方面板「从列表中移除」sdk.LocalFileRemoveRecent(fileid)
 * 的 fileid 即本 id；2026-09-05 此前 ascBridge 硬编码返回 '1' 假成功 → 列表从不清除）。
 * 返回 false：文件损坏（拒绝覆盖，同 readRecents 保护）或写失败。
 */
export function removeRecent(filesDir: string, id: number): boolean {
  try {
    const arr = readRecents(filesDir);
    if (arr === null) {
      return false;
    }
    const next = arr.filter((r) => r.id !== id);
    if (next.length !== arr.length || arr.length === 0) {
      return writeRecents(filesDir, next);
    }
    return true; // 无此 id：列表本就无它（幂等）
  } catch (e) {
    return false;
  }
}

/** 清空整个「最近使用」列表（官方面板「清除」→ sdk.LocalFileRemoveAllRecents() → 本函数） */
export function clearRecents(filesDir: string): boolean {
  try {
    const arr = readRecents(filesDir);
    if (arr === null) {
      return false;
    }
    return writeRecents(filesDir, []);
  } catch (e) {
    return false;
  }
}

/** 写回 recents.json（removeRecent/clearRecents 共用；损坏/空清单写 '[]'） */
function writeRecents(filesDir: string, arr: RecentItem[]): boolean {
  try {
    const f = fs.openSync(filesDir + RECENTS_FILE, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, JSON.stringify(arr));
    fs.closeSync(f);
    return true;
  } catch (e) {
    return false;
  }
}

/** appendRecent 写入格式：UTC 秒精度 "YYYY-MM-DD HH:MM:SS"（loginpage 显示兼容） */
function modifyedNow(): string {
  return new Date().toISOString().replace('T', ' ').substring(0, 19);
}

/**
 * 追加/置顶一条最近记录（同名去旧置顶；id=max+1；返回 false 表示未写入——
 * 旧清单损坏时拒绝覆盖，仅报日志）。type 为 loginpage FileFormat 枚举
 * （docx=0x41 xlsx=0x101 pptx=0x81 —— 官方枚举见 recents 契约头注释）。
 */
export function appendRecent(filesDir: string, name: string, path: string, typeNum: number): boolean {
  try {
    const arr = (readRecents(filesDir) ?? []).filter((r) => r.name !== name);
    let maxId = 0;
    for (const r of arr) {
      if (r.id > maxId) {
        maxId = r.id;
      }
    }
    arr.unshift({
      id: maxId + 1,
      pin: 0,
      name: name,
      path: path,
      type: typeNum,
      modifyed: modifyedNow()
    });
    const f = fs.openSync(filesDir + RECENTS_FILE,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, JSON.stringify(arr));
    fs.closeSync(f);
    return true;
  } catch (e) {
    return false;
  }
}
