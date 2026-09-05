import { resourceManager } from '@kit.LocalizationKit';
import { u8ToStr } from './bytes';

/**
 * 自动验收（smoke）工具 —— 与产品路径隔离（2026-09-05 用户要求：smoke 代码内聚，
 * 少侵入产品流程）。
 *
 * 激活方式：ability 启动参数 m7accept=1（可带 m7file=<样本名>，默认 sample.docx）；
 * 无参数启动 = 产品态，本模块的所有行为（自动打开/样本拷贝/诊断快照注入）不生效。
 * ascshim 侧对应的 m7open/m7auto 段另按页面 URL 参数门控（EditorPage 只在激活时拼参数），
 * 双重保证产品路径无任何验收行为。
 *
 * smoke 页面脚本外置在 rawfile/onlyoffice/smoke/*.js（源：scripts/onlyoffice/smoke/，
 * 多行可读、node --check 校验），EditorPage 注入前经本模块读取 —— 不再以 TS 字符串
 * 单行内嵌在页面代码里（维护性）。
 */
export class Smoke {
  /** 验收样本名；空 = 产品态（无任何 smoke 行为） */
  static target: string = '';

  protected static readonly DEFAULT_SAMPLE = 'sample.docx';
  /** 白名单后缀（m7file 只允许三类样本；dev-only 参数，防路径越界） */
  protected static readonly EXT_WHITELIST = ['docx', 'xlsx', 'pptx'];

  /** 从 ability 启动参数解析（EntryAbility.getLaunchOptions）；无参数/非法值 = 产品态 */
  static fromParams(params: Record<string, string>): void {
    Smoke.target = '';
    if (params['m7accept'] !== '1') {
      return;
    }
    const f = String(params['m7file'] ?? Smoke.DEFAULT_SAMPLE);
    // 仅接受 "名.白名单后缀" 文件名（rawfile 路径 <onlyoffice>/<f> 与沙箱 <filesDir>/<f> 拼接处）
    const dot = f.lastIndexOf('.');
    if (dot > 0 && Smoke.EXT_WHITELIST.indexOf(f.substring(dot + 1)) >= 0
      && f.indexOf('/') < 0 && f.indexOf('\\') < 0 && f.indexOf('..') < 0) {
      Smoke.target = f;
    }
  }

  /** 是否激活（产品态 false → 调用方跳过所有 smoke 行为） */
  static enabled(): boolean {
    return Smoke.target.length > 0;
  }

  /**
   * 读取 smoke 页面脚本（rawfile/onlyoffice/smoke/<name>.js）。
   * 返回字符串注入页面（runJavaScript 执行）；读失败返回 null（调用方仅记日志）。
   */
  static readScript(resMgr: resourceManager.ResourceManager | undefined, name: string): string | null {
    if (!resMgr) {
      return null;
    }
    try {
      const raw = resMgr.getRawFileContentSync('onlyoffice/smoke/' + name) as Uint8Array;
      return u8ToStr(raw as Uint8Array);
    } catch (e) {
      return null;
    }
  }
}

