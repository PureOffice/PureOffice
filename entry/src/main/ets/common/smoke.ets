import { resourceManager } from '@kit.LocalizationKit';
import { u8ToStr } from './bytes';
import { pickerSuffixes } from './formats';

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
 * 验收样本同样集中 at rawfile/onlyoffice/smoke/（sample.*、m7-open-test.docx、
 * demo-cn.*；2026-09-06 用户：smoke 文件单独目录存放）——本模块 m7file 文件名
 * 语义 = smoke/ 目录下的文件名（沙箱拷贝名不变）。
 */
export class Smoke {
  /** 验收样本名；空 = 产品态（无任何 smoke 行为） */
  static target: string = '';
  /** AI 联网验证密钥（m7key 启动参数；仅注入态使用，不落盘不进 git） */
  static key: string = '';
  /** AI 插件自动点击门控（m7ai=1）：prof-snap 的点击类动作（切 AI tab / 点 Chatbot）
   *  会弹出聊天窗遮挡常规验收截图，故默认关；需验 AI 插件链时显式开启。 */
  static ai: boolean = false;
  /** 保存链验收语义门控（m7autosave=1）：save:bin 以 userFlag=0（autosave）发送——用于
   *  回归「autosave 不得回写不能原地保存的格式源文件」这条数据安全不变量（见 30_open.js
   *  m7autosave 段；产品路径 userFlag 恒 1） */
  static autosave: boolean = false;
  /** 插入图片验收门控（m7img）：模型就绪后构造 File 对象走 sdkjs 上传汇合点
   *  （AscCommon.UploadImageFiles）插入一张内置小图——覆盖"上传→落盘→进模型→渲染
   *  供给→进保存产物"全链；只跳过系统 picker（需手指，uitest 注入不了）。
   *  取值 1=插入后保存（正向链）；2=插入后**撤销**再保存（反向链：模型回退后产物
   *  不含该图——删除链的自动可验部分）。需与 m7auto=1 同用（挂它的模型就绪回调）。
   *  见 30_open.js m7img 段。 */
  static img: string = '';
  /** 打开链文档密码（m7pwd 启动参数）。加密样本（samples/enc.*，口令 1234）用于验证
   *  x2t 的密文解密通路：非空时打开链在转换参数里拼 <m_sPassword>，空 = 产品路径不受影响。 */
  static pwd: string = '';

  protected static readonly DEFAULT_SAMPLE = 'sample.docx';
  /** 白名单后缀（m7file 只允许验收样本；dev-only 参数，防路径越界）——
   *  与 formats 表同源（新增可打开格式自动放行其样本名） */
  protected static readonly EXT_WHITELIST: string[] =
    pickerSuffixes().map((s: string) => s.substring(1));

  /** 从 ability 启动参数解析（EntryAbility.getLaunchOptions）；无参数/非法值 = 产品态
   * 参数载体：aa start 的 --ps 只能可靠携带**一个**参数对（实测多 --ps 只有第一个
   * 生效——2026-09-07，1.4 版 aa start 用法串），多参数用单值 `m7args` 传：
   *   --ps m7args "m7accept=1;m7file=sample.docx;m7key=sk-xxx"
   * （= 分隔键值；值禁空格；m7key 不进 git 不落盘）。旧单参 --ps m7accept 1 仍兼容。 */
  static fromParams(params: Record<string, string>): void {
    Smoke.target = '';
    Smoke.key = '';
    Smoke.ai = false;
    Smoke.autosave = false;
    Smoke.pwd = '';
    if (params['m7args'] !== undefined) {
      // 复合载体（; 与 = 拆解；值无空格——aa start 参数值空格会断键）
      const merged: Record<string, string> = {};
      for (const seg of String(params['m7args']).split(';')) {
        const eq = seg.indexOf('=');
        if (eq > 0) {
          merged[seg.substring(0, eq)] = seg.substring(eq + 1);
        }
      }
      params = merged;
    }
    if (params['m7accept'] !== '1') {
      return;
    }
    Smoke.key = String(params['m7key'] ?? '');
    Smoke.ai = String(params['m7ai'] ?? '') === '1';
    Smoke.autosave = String(params['m7autosave'] ?? '') === '1';
    Smoke.img = String(params['m7img'] ?? '');
    Smoke.pwd = String(params['m7pwd'] ?? '');
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

