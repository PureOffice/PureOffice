// convertershell —— x2t 转换内核 NAPI 模块类型声明（entry/src/main/cpp/convertershell.cpp 实现）。
// 注：".so" specifier 在当前 SDK 的 ArkTS 编译中不进行类型验证（导入即 any），
// 故以普通相对路径模块引入本声明文件。xml 参数同 x2t 命令行：
//   <Convert><m_sFileFrom>/data/xxx/in.docx</m_sFileFrom><m_sFileTo>/data/xxx/out.pdf</m_sFileTo></Convert>
// 返回 x2t 原始错误码：0x8004350 AVS_FILEUTILS_ERROR_CONVERT 表示成功，非失败。
export const convertSync: (xml: string) => number;
export const convert: (xml: string) => Promise<number>;
export const version: () => string;
