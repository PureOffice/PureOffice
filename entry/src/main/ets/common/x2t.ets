// x2t.ets —— libconvertershell.so（x2t 转换内核 NAPI 模块）类型隔离层。
// 当前 SDK 的 ArkTS 编译器对 ".so" import 不做模块类型验证（导入值为推断 any），
// ArkTS 禁止 any 推断使用，故在此唯一处接收并按接口断言（as）桥接出强类型函数。
// xml: x2t 命令行同款参数 XML，如
//   <Convert><m_sFileFrom>/data/xxx/in.docx</m_sFileFrom><m_sFileTo>/data/xxx/out.pdf</m_sFileTo></Convert>
// 返回 x2t 原始错误码：0 = 成功（SUCCEEDED_X2T）；0x8004350 = AVS_FILEUTILS_ERROR_CONVERT（转换失败码）。
import * as convertershell_so from 'libconvertershell.so';

interface X2TCore {
  convertSync(xml: string): number;
  convert(xml: string): Promise<number>;
  version(): string;
}

const core: X2TCore = convertershell_so as X2TCore;

export function x2tConvertSync(xml: string): number {
  // 同步转换（调试/诊断用；正式接口为 x2tConvert 异步）
  return core.convertSync(xml);
}

export function x2tConvert(xml: string): Promise<number> {
  return core.convert(xml);
}

export function x2tVersion(): string {
  return core.version();
}
