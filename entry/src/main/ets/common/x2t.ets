// x2t.ets —— libconvertershell.so（x2t 转换内核 NAPI 模块）类型隔离层。
// 当前 SDK 的 ArkTS 编译器对 ".so" import 不做模块类型验证（导入值为推断 any），
// ArkTS 禁止 any 推断使用，故在此唯一处接收并按接口断言（as）桥接出强类型函数。
// xml: x2t 命令行同款参数 XML，如
//   <Convert><m_sFileFrom>/data/xxx/in.docx</m_sFileFrom><m_sFileTo>/data/xxx/out.pdf</m_sFileTo></Convert>
// 返回 x2t 原始错误码：0 = 成功（SUCCEEDED_X2T）；0x8004350 = AVS_FILEUTILS_ERROR_CONVERT（转换失败码）。
//
// 历史注记：原导出 x2tConvert（异步）与 x2tVersion 无任何调用者（2026-09-05 审查删除）；
// 产品路径（打开/保存链）即使用 x2tConvertSync——NAPI 同步语义，转换对象为单个
// 文档（真机实测秒级，无 ANR）；若未来转大文件需改 worker 执行。
import * as convertershell_so from 'libconvertershell.so';

interface X2TCore {
  convertSync(xml: string): number;
  readSystemFontSync(name: string): ArrayBuffer | undefined;
}

const core: X2TCore = convertershell_so as X2TCore;

/** 同步文档转换（NAPI 同步调用；0=成功，错误码见头注释） */
export function x2tConvertSync(xml: string): number {
  return core.convertSync(xml);
}

/**
 * 读取系统字体 /system/fonts/<name>（NAPI 同步；native 层 ifstream——ArkTS
 * fileIo 对系统根路径一律 ENOENT（域白名单），native 同 wine 可读）。
 * 失败返回 undefined（native 侧 OH_LOG 留痕）。2026-09-07 系统字体桥 v2。
 */
export function readSystemFontSync(name: string): ArrayBuffer | undefined {
  return core.readSystemFontSync(name);
}
