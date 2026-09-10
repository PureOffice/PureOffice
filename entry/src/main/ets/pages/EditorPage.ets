import { BusinessError, deviceInfo, print } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { promptAction, window } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { x2tConvertSync } from '../common/x2t';
import { AscNativeBridge, AscNativeDispatch, AscCommandHandler } from '../common/ascBridge';
import { Smoke } from '../common/smoke';
import { getLaunchOptions, setWindowCloseHandler } from '../entryability/EntryAbility';
import { b64ToBuf, readFileBuf, writeFileBuf, x2tXml, x2tXmlFont, u8ToStr } from '../common/bytes';
import { appendRecent, RECENT_TYPE_DOCX, RECENT_TYPE_XLSX, RECENT_TYPE_PPTX } from '../common/recents';
import { P0TabsProbe, P0TabCtx, P0TabPair } from './P0TabsProbe';
import { DocTabHost, DocTabCtx, DocTabPair } from './DocTabHost';

/** 未保存关闭守卫：保存动作在途（设计 docs/UNSAVED_CLOSE_GUARD_DESIGN.md §3.3）——
 *  ctx=目标文档；awaitingSaveAs=新建首次保存=系统另存为框在途（save:bin 同步返回
 *  时不得提前关——框取消=不关）；then=窗口级退出队列的继续回调（undefined=tab 级） */
interface CloseGuardDefer {
  ctx: DocTabCtx;
  awaitingSaveAs: boolean;
  then: ((proceed: boolean) => void) | undefined;
}

/** ArkTS 侧调试开关：false=仅落 web_console.txt 文件（默认）；true=另 hilog 双写 */
const ARK_DEBUG: boolean = false;
/**
 * 打印字体表（x2t bin2pdf 的 m_sFontDir 内容）——2026-09-10。
 *
 * 为什么不用 /system/fonts：x2t 选字体是**打分制**（FontManager→CFontList::GetByParams，
 * 名字/粗斜体/charset 加权取 penalty 最小者）。设备 /system/fonts 有 205 个字体，
 * 当文档声明的字体名（Arial/Calibri/Tahoma…）一个都匹配不上时，**粗体位**成为决胜项
 * → 声明 Arial 的粗体文本被 NotoSansBengaliUI-Bold 命中，而该字体无拉丁/西里尔字形
 * → PDF 文字乱码（2026-09-10 真机实证：pptx 预览乱码，PDF 内嵌字体为 Bengali）。
 * 改为只用随包字体：回退集里全是含拉丁+西里尔+中文的字体（Liberation = Arial/
 * Times/Courier 的度量兼容替身）。字体本体来自 rawfile/onlyoffice/fonts。
 *
 * 解包时机：aboutToAppear 后台解包一次（~10MB 写入）；首次打印若尚未就绪则同步补。
 */
const PRINT_FONT_FILES: string[] = [
  'LiberationSans-Regular.ttf', 'LiberationSans-Bold.ttf',
  'LiberationSans-Italic.ttf', 'LiberationSans-BoldItalic.ttf',
  'LiberationSerif-Regular.ttf', 'LiberationSerif-Bold.ttf',
  'LiberationSerif-Italic.ttf', 'LiberationSerif-BoldItalic.ttf',
  'LiberationMono-Regular.ttf', 'LiberationMono-Bold.ttf',
  'HarmonyOS_Sans_SC.ttf', 'NotoSerifCJK-SC.ttf'
];
/**
 * 字体前 32B 的 XOR 密钥（构建期 pre_xor_font 加密态，SDK 假设服务器字体已
 * guidOdttf 预加密）。x2t 解析 TTF 头需要明文 → 解包时必须还原。
 * 与 09_fonts.js 的 GUID、build_editors_ohos.FONT_GUID_ODTTF 同源。
 */
const FONT_GUID_ODTTF: number[] = [
  0xA0, 0x66, 0xD6, 0x20, 0x14, 0x96, 0x47, 0xFA,
  0x95, 0x69, 0xB8, 0x50, 0xB0, 0x41, 0x49, 0x48
];
/**
 * 自动验收 = ability 启动参数控制（2026-09-05 用户建议：不写死代码，避免重新编译切换）：
 *   hdc XXX shell aa start -a EntryAbility -b app.fuqidian.pureoffice \
 *     -p m7accept 1 -p m7file sample.xlsx
 *   m7accept=1  → 验收开启（缺省 m7file=sample.docx；文件名须在 rawfile/onlyoffice/ 下，
 *                 且被 copySandboxSamples 复制到沙箱）。
 *   无参数启动 → 产品态：无自动打开/探针/诊断快照/样本拷贝（验收与产品分离，阶段2）。
 * 双重门控：ascshim 的 m7open/m7auto 另按 URL 参数触发（EditorPage 只在该模式拼参数）。
 */

/** 桌面命令处理器（per-instance：每 Web 实例一方，ctx 标识该实例——
 *  open: 任意实例（接收方=发起者页面），save:bin / file:close 路由到该 ctx 的 per-tab 状态） */
class ShellCommandHandler implements AscCommandHandler {
  private owner: EditorPage;
  private ctx: DocTabCtx;

  constructor(owner: EditorPage, ctx: DocTabCtx) {
    this.owner = owner;
    this.ctx = ctx;
  }

  onCommand(cmd: string, param: string, userFlag?: number): string {
    // userFlag 透传（ascBridge 第三参：1 用户保存 / 0 autosave——v2 保存语义，
    // 缺省 1 兜底用户保存）
    return this.owner.onTabCommand(this.ctx, cmd, param, userFlag ?? 1);
  }
}

@Entry
@Component
struct EditorPage {
  private resourceManager: resourceManager.ResourceManager | undefined = undefined;
  private ascNative: AscNativeBridge | undefined = undefined;
  private hostFilesDir: string = '';
  private webLogPath: string = '';
  /** UIAbilityContext（aboutToAppear 取一次；@ohos.print 等需 context 的 API 用） */
  private abilityCtx: common.UIAbilityContext | undefined = undefined;
  /** 打印字体目录（沙箱内解包路径，x2t bin2pdf 的 m_sFontDir；见 PRINT_FONT_FILES） */
  private printFontDir: string = '';
  /** 打印字体是否已就绪（.ready 标记已见/本次已解包成功） */
  private printFontsReady: boolean = false;
  /** M7 诊断直达配额：onPageEnd 时打开样本（welcome 完成后才触发，避开加载竞争） */
  private m7DirectQueued: boolean = false;
  /** 资源版本自愈 flush 一次守卫（onInstanceReady 周期内）——升级自愈只跑一次 */
  private cacheFlushed: boolean = false;
  // —— P1b（2026-09-08）：「保存目标」等文档身份字段已全部下沉 per-tab 的
  //    DocTabCtx.state（DocTabState：name/ext/saveTarget/savePath/pendingOpen）——
  //    原单例保留字段 savePath 等不再存在（多文档并存下单例必串写，见设计 §3）。

  /**
   * 统一日志入口（ArkTS 侧 → web_console.txt 镜像，与页面 [web] 日志同文件/时间戳）。
   * 页面日志经 onConsole 也走本函数（2026-09-05 归并：原内联落盘与此处双份重复）。
   * 开关：ARK_DEBUG=false 仅落文件（设备文件最可靠，hilog 抓取部分环境不可用）；
   * true 另 console.error 双写（hilog）。文件名：主日志系统缺 hilog 时仍可拷贝。
   */
  private arkLog(msg: string): void {
    if (ARK_DEBUG) {
      console.error(msg);
    }
    try {
      const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
      fs.writeSync(f.fd, 'T' + Date.now() + ' ' + msg + '\n');
      fs.closeSync(f);
    } catch (e) {
      // 日志落盘失败不影响主流程
    }
  }

  /** 页缓存版本号：构建期按 rawfile/onlyoffice 内容哈希生成（version.json）
   *  → URL ?v=N cache-bust（原 VERSION_BUMP 手工递增已删，阶段3 2026-09-05） */
  private pageVer: string = '0';
  /** 自动验收样本名（Smoke.target 的页面侧副本——smoke 行为见 Smoke 模块/Ascshim；
   *  空 = 产品态：无自动打开/诊断快照/样本拷贝） */
  private m7Target: string = '';
  /** P0 多实例探针（docs/ONLYOFFICE_MULTITAB_DESIGN.md §9；p0tabs=1 启动参数门控，
   *  产品态不挂载本分支——验证骨架，验证完可整体移除） */
  private p0On: boolean = false;
  @State p0Tabs: P0TabPair[] = [];
  /** P1b 容器：tab 数组（home 恒第一，随打开/关闭变化）+ 活动 tab（DocTabHost 受控） */
  @State docTabs: DocTabPair[] = [];
  @State focusTab: number = 0;
  /** tab 标题平行数组（@State 元素可观察——另存为改名即时刷新 chip）；与 docTabs 同步
   *  （index 对应；home 恒 '主页'） */
  @State docTitles: string[] = [];
  /** tab 主题色平行数组（页面 00_theme 0.10 上报：当前主题 CSS 变量
   *  --toolbar-header-<app>）——选中 chip 颜色跟随文档页当前主题色（官方桌面特性；
   *  主题切换重报）。缺省 ''=回退静态 accent。 */
  @State docAccents: string[] = [];
  private docTabSeq: number = 0;
  // —— 放映全屏（2026-09-11，PPT 放映「只在 webview 内播、tab 栏与窗口不动」）——
  /** 放映全屏态：sdkjs 放映引擎经 AscDesktopEditor.SetFullscreen 桥驱动
   *  （ascBridge → onFullscreenReq）。true 时 DocTabHost 收起 tab 条（Web 区自动
   *  吸顶铺满）+ PC 窗口沉浸最大化。 */
  @State fsMode: boolean = false;
  /** 进入放映前的窗口状态（windowStatusType；PC 退出时精确还原；-1=未记录） */
  private fsPreStatus: number = -1;
  // —— 未保存关闭守卫（2026-09-09，设计 §3）——
  /** 保存动作在途（至多一个——弹框模态互斥；待 save:bin/doSaveAs 完成消费） */
  private closeGuardDefer: CloseGuardDefer | null = null;
  /** 守卫单弹框互斥（查询窗口期/弹框在途时不再起新询问——默认不叠框） */
  private guardBusy: boolean = false;
  /** 窗口退出队列（onBackPress：未保存 doc 逐个询问；全处置完 terminateSelf） */
  private backQueue: DocTabCtx[] = [];
  // —— 守卫三按钮弹框（自绘覆盖层状态，2026-09-10）——
  /** 显示中/文档名（@State——渲染观察）；ctx/then=守卫上下文（非观察字段） */
  @State guardDialogOn: boolean = false;
  @State guardDialogName: string = '';
  private guardDialogCtx: DocTabCtx | null = null;
  private guardDialogThen: ((proceed: boolean) => void) | undefined = undefined;

  /** 官方欢迎页（loginpage）：欢迎/最近文件列表 + 新建卡片
   *  lang=zh-CN：loginpage 界面语言由 URL 参数决定（utils.inParams.lang；
   *  未传时回退英文——2026-09-05 用户目标「默认中文」） */
  private homeUrl(): string {
    return 'http://localhost/onlyoffice/index.html?v=' + this.pageVer
      + '&lang=zh-CN'
      // 注：zoom=1.2 只在文档页（editorUrl）拼——2026-09-05 用户：主界面不放大，
      // 文档页面才放大（LSO_PAGE_ZOOM 由 ascshim 00_boot 按参数设 html CSS zoom）
      + (this.m7Target.length > 0 ? '&m7open=' + encodeURIComponent(this.m7Target) : '');
  }

  /**
   * 编辑器页 URL —— 官方编辑器应用页（apps/<app>/main/index.html，顶层加载；
   * POC 打开链 v12 真机成功渲染的页面/构建组合）。页面经 Gateway init 后接收
   * openDocumentFromBinary 字节（官方 api.js/Gateway/loadBinary 链）。
   * 注：官方面向 API 调用方的桌面壳页（api/documents/index.html + iframe）组合已实测
   * 到 openDocument 前链；引擎模型初始化依赖 B 架构运行时序，本阶段以顶层页打开（后续 M4+ 返回 iframe 结构）。
   */
  private editorUrl(type: string, title: string, sidVal?: number): string {
    const app = type === 'xlsx' ? 'spreadsheeteditor'
      : type === 'pptx' ? 'presentationeditor' : 'documenteditor';
    let url = 'http://localhost/onlyoffice/webapps/apps/' + app + '/main/index.html?v=' + this.pageVer
      + '&fileType=' + type + '&isDesktop=false&docType=' + type + '&lang=zh-CN&title=' + encodeURIComponent(title)
      // sid=实例唯一化（2026-09-05 修复「关闭文档后再新建显示旧内容」：相同 URL 的
      // 二次导航 ArkWeb 复用引擎实例——页面事件照常（LSO_OPEN_DOCUMENT_OK 收到新模板
      // 字节 len=1086）但旧文档模型残留（真机实锤：新建「未命名的文档」显示 demo-cn 7 页
      // 内容）；sid 强制全新导航。P1b 起 sid=tabId（单调递增，比 Date.now 更保唯一；
      // 语义=tab 标识）。禁止回退为固定 URL（v= 仅防 HTTP 缓存，不防复用）。
      + '&sid=' + (sidVal !== undefined ? sidVal : Date.now());
    // M7 验收态：自动打开后追加 m7auto=1（ascshim：模型就绪→序列化→save:bin→x2t 落盘）
    if (this.m7Target.length > 0) {
      url = url + '&m7auto=1'
        // AI 联网验证 key 走页面 URL 传递（2026-09-08：启动参数链路在 1.4 上不可达
        // ——见 smoke.ets m7args 头注；URL 是 Web 侧已知可靠通道）
        + (Smoke.key.length > 0 ? '&m7key=' + encodeURIComponent(Smoke.key) : '');
    }
    return url;
  }

  /**
   * 官方桌面命令（loginpage sdk.command → AscNative.execCommand 与 command 两入口 → 本函数）。
   *   open:recent —— 沙箱源文件 → x2t 转 doct_bin（DOCY;v10 二进制）→ base64 暂存 →
   *                   loadUrl 官方编辑外壳，等 LocalStartOpen 就绪注入
   *   create:new  —— 空文档（无字节），直接打开外壳（引擎 OfflineApp 空文档）
   * 返回 'true'/'false'：loginpage 不依赖返回值（C++ 侧真正动作已由本函数执行）。
   */
  /**
   * 桌面命令（per-instance 分派入口——handler 按 ctx 路由；open: 由实例发起即合法，
   * save:bin / file:close 只认发送者 ctx 的 per-tab 状态）。
   */
  onTabCommand(ctx: DocTabCtx, cmd: string, param: string, userFlag: number = 1): string {
    this.arkLog('[TabCommand] ' + ctx.kind + ctx.id + ' ' + cmd + ' ' + param.slice(0, 300));
    if (cmd === 'open:recent') {
      return this.openRecent(param);
    }
    if (cmd === 'create:new') {
      // 官方 create:new 参数：'word'|'cell'|'slide'（新建卡片）或 {template:...}（模板卡）
      // 2026-09-05：cell/slide 支持（空模板 empty.xlsx/empty.pptx 由
      // scripts/onlyoffice/make_empty_templates.py 生成——原为 M4 TODO 不支持）
      const isCell = param.indexOf('cell') >= 0;
      const isSlide = param.indexOf('slide') >= 0;
      const ext = isSlide ? 'pptx' : isCell ? 'xlsx' : 'docx';
      return this.openNewFile(ext);
    }
    if (cmd === 'open:folder') {
      // M7：loginpage「Open local file」→ sdk.command('open:folder', path)（欢迎页按钮/拖放区
      // "选择文件"；param 为 pinned 文件夹路径，桌面语义"打开文件夹位置"）。本机语义 = 系统
      // 文件选择器选一个 docx/xlsx/pptx 打开（async 处理，命令先行受理）。
      this.openLocalFile();
      return 'true';
    }
    if (cmd === 'save:bin') {
      // userFlag=1 用户主动保存（补录 recents）/ 0 autosave（不补录——2026-09-05）
      const r = this.saveBinRaw(ctx, param, userFlag > 0);
      // 未保存关闭守卫：保存链同步完成 → 消费 defer（关 tab 或存失败不关）。
      // 新建首次保存（saveTarget='none'）saveBinRaw 内已另起 doSaveAs（异步系统框）
      // 并置 awaitingSaveAs——本处不得消费（框取消=不关；成功由 doSaveAs 尾消费）。
      if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx
        && !this.closeGuardDefer.awaitingSaveAs) {
        this.clearCloseGuard(ctx, r === 'true');
      }
      return r;
    }
    if (cmd === 'save:as') {
      // 官方另存为（asc_Save isSaveAs=true → 同格式）：40_save 发来的是**序列化流 DOCY**
      // （不是文件字节！）→ 先 x2t doct_bin2docx（保存链同款，saveBinRaw 'none' 分支的
      // doSaveAs 入参即此产物）→ 系统保存框（doSaveAs 既有链：uri 落盘+saveTarget/
      // savePath 身份演进+recents 补录）。直接写 DOCY=伪 docx（外部打开损坏——
      // 2026-09-08 真机发现 SAVE_AS_WRITE 落盘的是 doct bin 流，必修）。不同格式导出
      // 走「下载为」（暂未支持，菜单已隐藏——2026-09-08 用户决策）。
      return this.saveAsBin(ctx, param);
    }
    if (cmd === 'print:bin') {
      // 打印链（2026-09-10）：45_print.js 覆写 asc_Print 后发来的**元文件指令流**
      // （引擎 CDocumentRenderer 产物，非 PDF 文件格式）→ x2t bin2pdf 转真 PDF
      // → @ohos.print 调起系统打印。
      return this.printBin(ctx, param);
    }
    if (cmd === 'go:folder') {
      // 官方桌面"返回"（FileMenu 返回到文档列表）→ tab 化语义：激活主页 tab（doc 实例
      // 保留——文档仍开着，点 doc chip 即回，状态零重建）
      this.arkLog('GOBACK -> home tab');
      this.focusTab = 0;
      return 'true';
    }
    if (cmd === 'files:explore') {
      // 官方面板「在文件夹中显示」→ sdk.execCommand('files:explore', {path,id,hash})
      // B 架构无系统级「文件管理器定位文件」API（桌面 C++ OpenDir 等价物）——降级为
      // toast 显示文件绝对路径（用户可在系统文件管理/导出中按路径查找；2026-09-05）
      try {
        const fp = JSON.parse(param) as Record<string, Object>;
        const p = String(fp['path'] ?? '');
        this.arkLog('FILES_EXPLORE path=' + p);
        promptAction.showToast({ message: '文件位置：' + p, duration: 3000 });
      } catch (e) {
        this.arkLog('FILES_EXPLORE_ERR ' + String(e));
      }
      return 'true';
    }
    if (cmd === 'editor:event') {
      // 官方桌面"关闭文件"（FileMenu miExit → file:exit → Desktop.js:640）
      try {
        const oe = JSON.parse(param) as Record<string, Object>;
        if (String(oe['action']) === 'file:close') {
          this.arkLog('CLOSE_FILE -> guard id=' + ctx.id);
          this.requestCloseDoc(ctx);
        }
        if (String(oe['action']) === 'close-request') {
          // 官方 Header X（40_save _hookCloseEditor 重定向 closeEditor → 本上报）——
          // 统一走三按钮守卫（官方 web 弹框无「保存」项，语义不符离线单机）
          this.arkLog('CLOSE_REQUEST(HeaderX) -> guard id=' + ctx.id);
          this.requestCloseDoc(ctx);
        }
      } catch (e) {
        this.arkLog('EDITOR_EVENT_ERR ' + String(e));
      }
      return 'true';
    }
    // 其余桌面命令（files:check 等）M5 登记降级，当前 no-op
    return 'true';
  }

  /** 另存为命令体（per-tab：临时文件带 ctx 后缀——多文档隔离） */
  private saveAsBin(ctx: DocTabCtx, param: string): string {
    try {
      const abS = b64ToBuf(param);
      if (abS === null || abS.byteLength === 0) {
        this.arkLog('SAVE_AS_B64_BAD len=' + param.length);
        return 'false';
      }
      const extA = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const inA = ctx.tabPath('saveas-in.bin');
      const outA = ctx.tabPath('saveas-out.' + extA);
      if (!writeFileBuf(inA, abS)) {
        this.arkLog('SAVE_AS_WRITE_ERR ' + inA);
        return 'false';
      }
      const rcA = x2tConvertSync(x2tXml(inA, outA));
      this.arkLog('SAVE_AS_X2T rc=0x' + (rcA >>> 0).toString(16) + ' tab=' + ctx.id);
      if (rcA !== 0) {
        this.arkLog('SAVE_AS_X2T_FAIL');
        return 'false';
      }
      const docxBuf = readFileBuf(outA);
      if (docxBuf === null) {
        this.arkLog('SAVE_AS_SUBMISS ' + outA);
        return 'false';
      }
      this.doSaveAs(ctx, docxBuf);
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_AS_ERR ' + String(e));
      return 'false';
    }
  }

  /** 官方语言包词条缓存（懒加载，一次；三 app 键值） */
  private defaultNames: Record<string, string> | null = null;

  /**
   * 新建文档默认名 —— 从官方语言包读取（rawfile webapps/apps/<app>/main/locale/
   * zh.json，键 [DE|SSE|PE].Controllers.LeftMenu.newDocumentTitle = 官方桌面「新建」
   * 默认名：未命名的文档/未命名的电子表格/未命名的演示）。语言文件与 UI lang 对齐
   * （editorUrl lang=zh-CN → locale/zh.json；未来多语言换 lang 即换文件）。
   * 兜底仅在语言包读失败/键缺失时给直写中文（正常路径零硬编码文本）。
   */
  private defaultDocName(ext: string): string {
    try {
      if (this.defaultNames === null) {
        this.defaultNames = {};
        const lang = 'zh'; // 与 editorUrl lang=zh-CN 对齐
        const apps: [string, string, string][] = [
          ['docx', 'documenteditor', 'DE'],
          ['xlsx', 'spreadsheeteditor', 'SSE'],
          ['pptx', 'presentationeditor', 'PE']
        ];
        for (let i = 0; i < apps.length; i++) {
          const e: string = apps[i][0];
          const app: string = apps[i][1];
          const pfx: string = apps[i][2];
          const raw = this.resourceManager!.getRawFileContentSync(
            'onlyoffice/webapps/apps/' + app + '/main/locale/' + lang + '.json') as Uint8Array;
          const dict = JSON.parse(u8ToStr(raw)) as Record<string, string>;
          this.defaultNames[e] = dict[pfx + '.Controllers.LeftMenu.newDocumentTitle'] ?? '';
        }
      }
    } catch (e) {
      this.arkLog('DEFAULT_NAME_LOCALE_ERR ' + String(e));
    }
    const fromLoc = this.defaultNames && this.defaultNames[ext];
    if (fromLoc !== null && fromLoc !== undefined && fromLoc.length > 0) {
      return fromLoc + '.' + ext;
    }
    // 兜底（语言包读取失败/键缺失时保底；正常路径走上面官方词条）
    const base = ext === 'xlsx' ? '未命名的电子表格'
      : ext === 'pptx' ? '未命名的演示' : '未命名的文档';
    return base + '.' + ext;
  }

  /** create:new（word）：空文档模板 → 与打开同管线注入（官方 C++ 对新建同样发 DocumentEndLoad） */
  private openNewFile(ext: string): string {
    try {
      // 空模板（rawfile/onlyoffice/templates/empty.<ext>；docx/xlsx/pptx 均由
      // 官方样本/结构保证合法——xlsx/pptx 生成见 scripts/onlyoffice/make_empty_templates.py）
      const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/templates/empty.' + ext) as Uint8Array;
      const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      this.arkLog('CREATE_NEW empty.' + ext + ' len=' + ab.byteLength);
      // 新建（未保存）不进「最近使用」——官方桌面语义：recents=打开过的文件；
      // 未保存的新建无独立文件身份，点开即编辑 — 2026-09-05 修复（原 convertAndOpen
      // 无条件 appendRecent，创建一轮就把未命名文档堆进 recents，用户实测质疑）
      // 2026-09-05 根因修正：newDoc=true（零状态空文档，无模板文件/无写入源）
      return this.openNewTabEntry(ab, ext, this.defaultDocName(ext), false, true);
    } catch (e) {
      this.arkLog('CREATE_NEW_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * M7 打开真实文件：系统文件选择器（DocumentViewPicker）→ 选中 docx/xlsx/pptx
   * → 字节交 convertAndOpen（写入沙箱 <name> + x2t + 编辑器导航）。
   * 选择器授权 uri 仅临时可读 —— 字节读入内存即固化为沙箱文件，此后与源文件无关联
   * （保存回写沙箱；"导出"经系统保存对话框写用户位置）。
   */
  private async openLocalFile(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.docx', '.xlsx', '.pptx'];
      const uris = await dvp.select(opts);
      if (uris.length === 0) {
        this.arkLog('OPEN_LOCAL_CANCEL');
        return;
      }
      const uri = uris[0];
      // 选择器授权 uri 仅临时可读：读入内存即固化（后续 convertAndOpen 写沙箱）
      const ab = readFileBuf(uri);
      if (ab === null) {
        this.arkLog('OPEN_LOCAL_READERR uri=' + uri);
        return;
      }
      // 文件名/扩展名：uri 尾段（Picker uri 通常带编码文件名；统计型 uri 兜底 docx）
      const label = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
      let ext = '';
      const dot = label.lastIndexOf('.');
      if (dot > -1) {
        ext = label.substring(dot + 1).toLowerCase();
      }
      if (ext !== 'docx' && ext !== 'xlsx' && ext !== 'pptx') {
        this.arkLog('OPEN_LOCAL_EXTBAD label=' + label + ' ext=' + ext);
        return;
      }
      this.arkLog('OPEN_LOCAL_OK label=' + label + ' uri=' + uri + ' size=' + ab.byteLength);
      // userUri=系统选择器真实位置——保存目标=用户原文件（覆盖式保存，2026-09-05）
      this.openNewTabEntry(ab, ext, label, true, false, uri);
    } catch (e) {
      this.arkLog('OPEN_LOCAL_ERR ' + String(e));
    }
  }

  /** open:recent → 沙箱文件 x2t 转换 + 编辑器导航（转换器按输入扩展名自动选择，.bin 输出） */
  private openRecent(param: string): string {
    try {
      const o = JSON.parse(param) as Record<string, Object>;
      const path = String(o['path'] ?? '');
      const name = String(o['name'] ?? '');
      const typeNum = Number(o['type'] ?? 0);
      let ext = '';
      if (typeNum === RECENT_TYPE_XLSX) {
        ext = 'xlsx';
      } else if (typeNum === RECENT_TYPE_PPTX) {
        ext = 'pptx';
      } else {
        ext = 'docx';
      }
      // 扩展名兜底（recents 模型缺 type 时从文件名后缀采信白名单）
      if (name.length > 0) {
        const i = name.lastIndexOf('.');
        if (i > 0) {
          const sfx = name.substring(i + 1);
          if (sfx === 'xlsx' || sfx === 'pptx' || sfx === 'docx') {
            ext = sfx;
          }
        }
      }
      if (path.length === 0) {
        this.arkLog('OPEN_RECENT_NOPATH ' + param);
        return 'false';
      }
      // 文件名以 path 尾部为准（loginpage recents 的 name 字段可能被截断/缺失）
      const base = path.substring(path.lastIndexOf('/') + 1);
      // 读源文件字节
      const ab = readFileBuf(path);
      if (ab === null) {
        this.arkLog('OPEN_RECENT_READERR ' + path);
        return 'false';
      }
      // userUri=recents 记录的真实位置（uri→保存覆盖用户文件；历史沙箱路径→兼容）
      return this.openNewTabEntry(ab, ext, base.length > 0 ? base : name, true, false, path);
    } catch (e) {
      this.arkLog('OPEN_RECENT_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 另存为（per-tab：ctx.state 唯一身份源）：系统保存对话框（DocumentViewPicker.save）
   * → 用户选位置/文件名 → 字节落盘（uri 写）→ 身份演进（'none'→'uri'）→ recents 补录
   * → tab 标题刷新（docTitles 平行数组——@State 元素级可观察）。取消 → 不动。
   */
  private async doSaveAs(ctx: DocTabCtx, outBuf: ArrayBuffer): Promise<void> {
    try {
      const aCtx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(aCtx);
      const opts = new picker.DocumentSaveOptions();
      // 默认名：已保存文档=当前名；新建=语言包中文未命名（defaultDocName——
      // 2026-09-08 补：doSaveAs 兜底名原写死 Unnamed.，与 openNewFile 语言包驱动对齐）
      const defName = ctx.state.name.length > 0 ? ctx.state.name : this.defaultDocName(ctx.state.ext);
      opts.newFileNames = [defName];
      const uris = await dvp.save(opts);
      if (!uris || uris.length === 0) {
        this.arkLog('SAVE_AS_CANCEL tab=' + ctx.id);
        // 未保存关闭守卫：另存为取消=数据未保存 → 不关（留在文档），守卫终止。
        // saveAborted 显式置位（clearCloseGuard 仅守卫路径生效——手动保存（非守卫）
        // 取消同样代表「未落盘」，下次关闭守卫须弹框）
        ctx.state.saveAborted = true;
        this.clearCloseGuard(ctx, false);
        return;
      }
      const uri = uris[0];
      const ok = writeFileBuf(uri, outBuf);
      this.arkLog('SAVE_AS_WRITE uri=' + uri + ' ok=' + ok + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
      if (!ok) {
        this.arkLog('SAVE_AS_WRITE_ERR ' + uri);
        // 未保存关闭守卫：落盘失败=未保存 → 不关
        ctx.state.saveAborted = true;
        this.clearCloseGuard(ctx, false);
        return;
      }
      ctx.state.savePath = uri; // 身份=真实位置（后续保存覆盖写它）
      // 文件身份 = 用户选择的位置（recents path=真实 uri）；文件名以 uri 尾段为准
      const base = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
      if (base.length > 0) {
        ctx.state.name = base;
        const dot = base.lastIndexOf('.');
        if (dot > 0) {
          const e2 = base.substring(dot + 1).toLowerCase();
          if (e2 === 'docx' || e2 === 'xlsx' || e2 === 'pptx') {
            ctx.state.ext = e2;
          }
        }
      }
      // 身份演进（saveTarget 单点）：'none' → 'uri'——页面经 save:type 同步询问即命中。
      // 不写沙箱镜像：用户数据只存用户选择的位置（重开后由打开链自动建立工作副本）。
      ctx.state.saveTarget = 'uri';
      // tab 标题刷新（docTitles 平行数组 index 与 docTabs 一致）
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === ctx) {
          const tArr = this.docTitles.slice();
          tArr[i] = base.length > 0 ? base : this.defaultDocName(ctx.state.ext);
          this.docTitles = tArr;
          break;
        }
      }
      if (ctx.state.name.length > 0) {
        const typeNum = ctx.state.ext === 'xlsx' ? RECENT_TYPE_XLSX
          : ctx.state.ext === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
        // path=真实保存位置（uri）；重开走 readFileBuf(uri)（picker 授权持久）
        if (appendRecent(this.hostFilesDir, ctx.state.name, uri, typeNum)) {
          this.arkLog('RECENTS_APPEND_SAVEAS name=' + ctx.state.name + ' path=' + uri);
        }
      }
      // 未保存关闭守卫：另存为成功（身份成立/落盘完成）→ 清除「保存中止」标记
      //（幂等；defer 存在时消费关闭——普通另存为（非守卫）defer null=仅清标记）
      // 与关闭目标 tab（守卫 defer 仅「保存」路径产生；普通另存为无 defer 空操作）
      ctx.state.saveAborted = false;
      this.clearCloseGuard(ctx, true);
    } catch (e) {
      this.arkLog('SAVE_AS_ERR ' + String(e));
      // 未保存关闭守卫：另存为异常=未保存 → 不关
      ctx.state.saveAborted = true;
      this.clearCloseGuard(ctx, false);
    }
  }

  /**
   * @param userSaved 用户主动保存（true=补录 recents）/ autosave（false=只落盘不打扰
   * 「最近使用」；2026-09-05 新建即 autosave 的连锁修正）
   */
  /**
   * M4 保存链本体（saveBinRaw）：ascshim saveDocument 接手 → 官方 asc_nativeGetFileData
   * （BinaryFileWriter 序列化当前模型 → DOCY;v10，与打开链 in.bin 同格式）→ save:bin
   * 至此：写沙箱 in.bin → x2t doct_bin2docx → save.<ext>（zip 头校验）→ 回写当前源文件。
   * userSaved=1 用户保存（补录 recents）/ 0 autosave（只落盘不补录，2026-09-05 语义）。
   */
  /**
   * M4 保存链本体（per-tab 版：ctx.state 身份源 + ctx.tabPath 临时文件——多文档隔离）：
   * save:bin ← ascshim saveDocument 接手 → 官方 asc_nativeGetFileData（BinaryFileWriter
   * 序列化当前模型 → DOCY;v10）→ 本方法：写 per-tab in.<id>.bin → x2t doct_bin2docx →
   * save.<id>.<ext>（zip 头校验）→ 回写当前源文件（ctx.state.savePath）。
   */
  /**
   * 打印：引擎元文件流 → x2t bin2pdf → 系统打印（2026-09-10）。
   *
   * 入参 = 45_print.js 覆写 asc_Print 后发来的 base64——内容是**元文件绘图指令流**
   * （引擎 CDocumentRenderer 产物），不是 PDF 文件格式。转换靠 x2t 的 bin2pdf
   * （NExtractTools::bin2pdf，纯 C++ 的 NSOnlineOfficeBinToPdf，不依赖
   * doctrenderer/V8）：方向判定看扩展名——源 .bin → AVS_OFFICESTUDIO_FILE_CANVAS_PDF、
   * 目标 .pdf → TCD_BIN2PDF。
   */
  private printBin(ctx: DocTabCtx, b64: string): string {
    // 字体表必须就绪再转（未就绪则本次同步解包，~10MB 一次性写入）
    const fontDir = this.ensurePrintFonts() ? this.printFontDir : '';
    try {
      if (b64.length === 0) {
        this.arkLog('PRINT_BIN_EMPTY');
        return 'false';
      }
      const ab = b64ToBuf(b64);
      const inP = this.printDir(ctx) + '/in.bin';
      const outP = this.printOutPath(ctx);
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('PRINT_BIN_WRITE_ERR ' + inP);
        return 'false';
      }
      const rc = x2tConvertSync(x2tXmlFont(inP, outP, fontDir));
      this.arkLog('PRINT_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        promptAction.showToast({ message: '打印失败：文档转换出错', duration: 3000 });
        return 'false';
      }
      const outBuf = readFileBuf(outP);
      if (outBuf === null) {
        this.arkLog('PRINT_PDF_MISSING ' + outP);
        return 'false';
      }
      // %PDF- 魔数校验（元文件流若被误当 PDF 会直接从这里暴露）
      const mk = new Uint8Array(outBuf.slice(0, 5));
      const pdfOk = mk[0] === 0x25 && mk[1] === 0x50 && mk[2] === 0x44 && mk[3] === 0x46;
      this.arkLog('PRINT_PDF size=' + outBuf.byteLength + (pdfOk ? ' pdfok' : ' PDFBAD'));
      if (!pdfOk) {
        promptAction.showToast({ message: '打印失败：PDF 生成异常', duration: 3000 });
        return 'false';
      }
      this.printPdf(ctx, outP);
      return 'true';
    } catch (e) {
      this.arkLog('PRINT_BIN_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 打印字体就绪（幂等）：rawfile/onlyoffice/fonts → 沙箱 printFontDir，供 x2t
   * bin2pdf 建字体表（缘由见 PRINT_FONT_FILES）。标记文件 .ready 存在即视为完成，
   * 避免每次启动重复写 ~10MB。返回是否可用。
   */
  private ensurePrintFonts(): boolean {
    if (this.printFontsReady) {
      return true;
    }
    const dir = this.printFontDir;
    const rm = this.resourceManager;
    if (dir.length === 0 || rm === undefined) {
      return false;
    }
    // 注意：fs.accessSync 是**返回 boolean** 而非抛异常（2026-09-10 实测——
    // 不能写成 try{ accessSync() }catch{}，那样"不存在"会被当成已就绪直接返回）
    let hasFlag = false;
    try {
      hasFlag = fs.accessSync(dir + '/.ready');
    } catch (e) {
      hasFlag = false;
    }
    if (hasFlag) {
      this.printFontsReady = true;
      return true;
    }
    try {
      fs.mkdirSync(dir);
    } catch (e) {
      // 目录已存在
    }
    let ok = 0;
    for (let i = 0; i < PRINT_FONT_FILES.length; i++) {
      const name = PRINT_FONT_FILES[i];
      try {
        const u8 = rm.getRawFileContentSync('onlyoffice/fonts/' + name) as Uint8Array;
        // pre_xor_font 只加密前 32B（TTF 头）—— 正是 x2t 解析所需，必须先还原
        const n = Math.min(32, u8.length);
        for (let k = 0; k < n; k++) {
          u8[k] = u8[k] ^ FONT_GUID_ODTTF[k % 16];
        }
        if (!writeFileBuf(dir + '/' + name, u8)) {
          this.arkLog('PRINT_FONT_WRITE_ERR ' + name);
          continue;
        }
        // 大字体（最大 5.5MB）单次 writeSync 可能截断 → 按落盘尺寸复核
        let sz = -1;
        try {
          sz = fs.statSync(dir + '/' + name).size;
        } catch (e) {
          sz = -1;
        }
        if (sz === u8.length) {
          ok++;
        } else {
          this.arkLog('PRINT_FONT_SIZE_ERR ' + name + ' ' + sz + '/' + u8.length);
        }
      } catch (e) {
        this.arkLog('PRINT_FONT_ERR ' + name + ' ' + String(e));
      }
    }
    this.printFontsReady = ok === PRINT_FONT_FILES.length;
    if (this.printFontsReady) {
      writeFileBuf(dir + '/.ready', new ArrayBuffer(0));
    }
    this.arkLog('PRINT_FONTS_EXTRACT ' + ok + '/' + PRINT_FONT_FILES.length);
    return this.printFontsReady;
  }

  /** 调起系统打印（@ohos.print）：文件路径 + context；任务终态回调里清理临时文件。
   *  注意：终态事件（succeed/fail/cancel）只在系统走完打印流程时到达——**用户直接关掉
   *  打印界面不一定触发任何事件**（2026-09-11 真机实测：关闭打印框后无 CANCEL 日志、
   *  工作目录原样保留）。故清理不能只依赖这里，启动 sweepPrintFiles 才是兜底路径
   *  （幂等，重复清无副作用）。 */
  private printPdf(ctx: DocTabCtx, pdfPath: string): void {
    const c = this.abilityCtx;
    if (c === undefined) {
      this.arkLog('PRINT_NO_CTX');
      return;
    }
    // 传给系统打印服务的必须是 FileUri（file://<bundle>/<sandbox>）而非裸沙箱路径——
    // 打印服务是独立进程，裸路径在它的视图里不存在（2026-09-10 真机实证：
    // HwPrintSpooler "loadPdf failed: 1 / No such file or directory"）。
    // fileUri.getUriFromPath 即官方为「跨进程访问应用沙箱文件」提供的转换。
    let src = pdfPath;
    try {
      src = fileUri.getUriFromPath(pdfPath);
    } catch (ue) {
      this.arkLog('PRINT_URI_ERR ' + String(ue));
    }
    this.arkLog('PRINT_URI ' + src);
    print.print([src], c)
      .then((task: print.PrintTask) => {
        this.arkLog('PRINT_TASK_START ' + pdfPath);
        // 临时 PDF 须活到任务终态（系统打印服务异步读文件）；缺纸/离线（block）
        // 时保留文件——此时删了任务就废了。
        task.on('succeed', () => {
          this.arkLog('PRINT_TASK_SUCCEED');
          this.cleanupPrintFiles(ctx);
        });
        task.on('fail', () => {
          this.arkLog('PRINT_TASK_FAIL');
          this.cleanupPrintFiles(ctx);
        });
        task.on('cancel', () => {
          this.arkLog('PRINT_TASK_CANCEL');
          this.cleanupPrintFiles(ctx);
        });
        task.on('block', () => {
          this.arkLog('PRINT_TASK_BLOCK');
        });
      })
      .catch((e: BusinessError) => {
        // 201 = 缺 ohos.permission.PRINT 声明；其余 = 系统打印服务不可用
        this.arkLog('PRINT_TASK_ERR ' + e.code + ' ' + e.message);
        promptAction.showToast({ message: '无法调起系统打印', duration: 3000 });
        this.cleanupPrintFiles(ctx);
      });
  }

  /**
   * 打印工作目录（per-tab）：<filesDir>/print/<tabId>/。
   * 用目录而非 tabPath 的文件名后缀，是为了让输出 PDF 的文件名**保持文档名**
   * ——系统打印服务的「另存为 pdf」以传入文件名作保存框默认名（2026-09-10 真机：
   * 原 tabPath 命名让保存框显示 print-out.2，内部临时名暴露给用户）。
   * 目录隔离同时保住多文档互不踩。
   */
  private printDir(ctx: DocTabCtx): string {
    const dir = this.hostFilesDir + '/print/' + ctx.id;
    // 父目录必须显式建：mkdirSync 无递归语义，父不存在时建子目录直接抛错
    // （2026-09-11 真机实证：print/2/in.bin 写入失败，异常被下面的 catch 吞成静默）
    try {
      fs.mkdirSync(this.hostFilesDir + '/print');
    } catch (e) {
      // 已存在
    }
    try {
      fs.mkdirSync(dir);
    } catch (e) {
      // 已存在
    }
    return dir;
  }

  /** 输出 PDF 路径：print/<tabId>/<文档名>.pdf（文档名为空时回落 doc.pdf）。
   *  ctx.state.name 是含扩展名的文档名（保存链的同一事实源：savePath = filesDir + '/' + name），
   *  新建未保存的文档也有值（defaultDocName）。 */
  private printOutPath(ctx: DocTabCtx): string {
    const src = ctx.state.name.length > 0 ? ctx.state.name : 'doc';
    const dot = src.lastIndexOf('.');
    const stem = dot > 0 ? src.substring(0, dot) : src;
    const safe = stem.replace(/[\\/:*?"<>|]/g, '_');
    return this.printDir(ctx) + '/' + (safe.length > 0 ? safe : 'doc') + '.pdf';
  }

  /** 启动清扫：删沙箱里的打印残留（崩溃/强杀时任务终态回调未跑；幂等）。
   *  两级都扫：新的 print/<tabId>/ 工作目录 + 旧版平铺的 print-in. 与 print-out. 前缀文件。 */
  private sweepPrintFiles(): void {
    const root = this.hostFilesDir + '/print';
    try {
      const ids = fs.listFileSync(root);
      for (const id of ids) {
        const dir = root + '/' + id;
        try {
          const names = fs.listFileSync(dir);
          for (const n of names) {
            try {
              fs.unlinkSync(dir + '/' + n);
            } catch (e) {
              // 占用中/已删——忽略
            }
          }
          fs.rmdirSync(dir);
        } catch (e) {
          // 非目录或已删——忽略
        }
      }
      try {
        fs.rmdirSync(root);
      } catch (e) {
        // 非空/已删——忽略
      }
    } catch (e) {
      // 无 print 目录（首次运行）——非致命
    }
    try {
      const names = fs.listFileSync(this.hostFilesDir);
      for (const n of names) {
        if (n.startsWith('print-in.') || n.startsWith('print-out.')) {
          try {
            fs.unlinkSync(this.hostFilesDir + '/' + n);
          } catch (e) {
            // 占用中/已删——忽略
          }
        }
      }
    } catch (e) {
      // 目录不可读等——非致命
    }
  }

  /** 删除该 tab 的打印工作目录（幂等；调用点只在打印任务终态） */
  private cleanupPrintFiles(ctx: DocTabCtx): void {
    const dir = this.hostFilesDir + '/print/' + ctx.id;
    try {
      const names = fs.listFileSync(dir);
      for (const n of names) {
        try {
          fs.unlinkSync(dir + '/' + n);
        } catch (e) {
          // 占用中/已删——忽略
        }
      }
      fs.rmdirSync(dir);
    } catch (e) {
      // 目录不存在/非空——残留由下次启动 sweepPrintFiles 兜底
    }
  }

  private saveBinRaw(ctx: DocTabCtx, b64: string, userSaved: boolean = true): string {
    try {
      if (b64.length === 0) {
        this.arkLog('SAVE_BIN_EMPTY');
        return 'false';
      }
      const ab = b64ToBuf(b64);
      // M7 三格式：目标后缀决定 x2t 转换器（doct_bin2docx / xlst_bin2xlsx / pptt_bin2pptx）
      const extU = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const inP = ctx.tabPath('in.bin');
      const outP = ctx.tabPath('save.' + extU);
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('SAVE_BIN_WRITE_ERR ' + inP);
        return 'false';
      }
      // x2t doct_bin2docx（checker 以文件头 DOCY 内容识别，.bin 后缀无碍；POC 保存链实证）
      const rc = x2tConvertSync(x2tXml(inP, outP));
      this.arkLog('SAVE_BIN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        return 'false';
      }
      // zip 头校验 0x50 0x4b（校验比 exist 更严：x2t 产物必须是合法 ZIP）
      const outBuf = readFileBuf(outP);
      if (outBuf === null) {
        this.arkLog('SAVE_BIN_SUBMISS ' + outP);
        return 'false';
      }
      const mk = new Uint8Array(outBuf.slice(0, 2));
      const zipOk = mk[0] === 0x50 && mk[1] === 0x4b;
      this.arkLog('SAVE_BIN_OUT size=' + outBuf.byteLength + ' mk=0x'
        + mk[0].toString(16).padStart(2, '0') + mk[1].toString(16).padStart(2, '0')
        + (zipOk ? ' zipok' : ' ZIPBAD'));
      if (!zipOk) {
        return 'false';
      }
      // 新文件首次保存 = 另存为（官方桌面语义：无文件身份 → 弹系统保存对话框选位置；
      // 2026-09-05 用户「点保存应弹保存位置，却直接保存了」）。x2t 产物 outBuf 交接给
      // doSaveAs（async：dvp.save → uri 落盘 + 沙箱同步 + recents + 复位 isNewUnsaved）。
      // 对话框异步期间先回 'true'（保存受理）；取消=未保存（isNewUnsaved 仍 true，
      // 下次保存再弹）。
      // v2 保存决策（单一事实源 saveTarget，per-tab）：
      if (userSaved && ctx.state.saveTarget === 'none') {
        // 新建无身份 + 用户保存 → 弹另存为（async：dvp.save → uri 落盘 → 'none'→'uri'）
        this.arkLog('SAVE_AS_DIALOG name=' + ctx.state.name + ' tab=' + ctx.id);
        // 未保存关闭守卫：「保存」→ 另存为框在途——守卫消费移交 doSaveAs 完成回调
        //（此时 save:bin 将返回 'true'，handler 见 awaitingSaveAs 不消费）
        if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx) {
          this.closeGuardDefer.awaitingSaveAs = true;
        }
        this.doSaveAs(ctx, outBuf);
        return 'true';
      }
      if (ctx.state.name.length > 0) {
        if (ctx.state.saveTarget === 'uri' && ctx.state.savePath.length > 0) {
          // 已另存为：覆写真实位置（用户数据=savePath uri）
          const okUri = writeFileBuf(ctx.state.savePath, outBuf);
          this.arkLog('SAVE_BIN_URI ok=' + okUri + ' uri=' + ctx.state.savePath + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
          if (!okUri) {
            this.arkLog('SAVE_BIN_URI_ERR ' + ctx.state.savePath);
            return 'false';
          }
        }
        // 引擎工作副本同步（打开/另存为后重开链以最新内容起步；不参与 recents/用户
        // 数据——用户文件=savePath（uri 或沙箱工作副本，2026-09-05）
        const srcP = this.hostFilesDir + '/' + ctx.state.name;
        if (!writeFileBuf(srcP, outBuf)) {
          this.arkLog('SAVE_BIN_BACK_ERR src=' + srcP);
          return 'false';
        }
        this.arkLog('SAVE_BIN_BACK src=' + srcP + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
        // 保存成功 = 文件身份成立（官方桌面语义：保存后的文件进「最近使用」；
        // 新建在打开链已禁 recents（openNewTabEntry addRecent=false）——用户保存即补录；
        // appendRecent 同名去旧置顶，已打开文件的保存同样刷新置顶。
        // 仅用户保存补录（自动保存/autosave 不打扰列表——2026-09-05 用户实测后修正）。
        if (userSaved) {
          const saveType = ctx.state.ext === 'xlsx' ? RECENT_TYPE_XLSX
            : ctx.state.ext === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
          // recents.path：真实位置优先（uri），否则沙箱（打开链/兼容）
          const recentPath = ctx.state.saveTarget === 'uri' ? ctx.state.savePath : srcP;
          if (appendRecent(this.hostFilesDir, ctx.state.name, recentPath, saveType)) {
            this.arkLog('RECENTS_APPEND_SAVE name=' + ctx.state.name);
          }
        }
      }
      // 保存真正落盘（URI/沙箱覆写完成）→ 清「保存中止」标记（2026-09-09 review：
      // 仅守卫消费路径清不够——另存为取消后用户**手动** Ctrl+S 保存成功的场景，
      // saveAborted 残留会导致下次关闭误弹框；落盘终点统一复位，幂等）
      ctx.state.saveAborted = false;
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_BIN_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 打开共用管线：x2t 转 doct_bin（DOCY;v10;0;+raw 二进制）→ 字节读入内存 → 导航空
   * 官方编辑外壳（LocalStartOpen 就绪后经 onEditorReadyForDoc 注入）。
   * 转换失败或文件不可读 → 不导航，留在欢迎页（避免官方壳报"打开文件错误"弹窗）。
   */
  /**
   * @param addRecent 是否写入「最近使用」（打开=写入；新建=不写，2026-09-05）
   * @param newDoc  新建语义（2026-09-05 根因修正「创建≠打开文件」）：不落模板源文件、
   *                currentOpenName 置空（无文件身份——官方桌面语义：新建即零状态，保存
   *                首次=另存为；此前把新建当「打开模板文件」导致保存/recents 路径/未保存
   *                语义全部错位）
   */
  /**
   * 打开管线（per-tab 版，P1b——多文档并存的基础）：
   * 先建 doc 实例（tab id 定名）→ 沙箱工作副本（newDoc 跳过）→ x2t 转换
   * （临时文件带 tab 后缀：open-in.<id>.*——多实例互不踩）→ per-tab 身份 state
   * （name/ext/saveTarget/savePath/pendingOpen 全部下沉）→ 追加 tab 并列（不再关旧开新）。
   * m7 验收锁（设计 §6.4）：验收态单 tab 隧道（关旧开新）——产品态自由多开。
   */
  private openNewTabEntry(ab: ArrayBuffer, ext: string, name: string, addRecent: boolean = true,
    newDoc: boolean = false, userUri?: string): string {
    try {
      const extU = ext.toLowerCase();
      if (Smoke.enabled()) {
        const oldDocs = this.docTabs.filter((p: DocTabPair) => p.ctx.kind === 'doc');
        for (let i = 0; i < oldDocs.length; i++) {
          this.closeDocTab(oldDocs[i].ctx.id);
        }
      }
      // 身份对象先行（tabId 唯一化）：临时文件/url/state 全部以 id 定名
      this.docTabSeq += 1;
      const ctx = new DocTabCtx(this.docTabSeq, 'doc', name, '',
        this.resourceManager!, this.hostFilesDir,
        ((m: string) => this.arkLog(m)), ((c: DocTabCtx) => this.onInstanceReady(c)),
        ((c: DocTabCtx) => this.onPageEndCB(c)));
      // M7：源文件持久化到沙箱 <name>（openRecent 的来源 / 保存回写目标 / recents 条目；
      // 选择器授权 uri 读权限短暂——字节落盘即固化）。newDoc 跳过（无文件身份，2026-09-05）
      if (!newDoc) {
        const srcP = this.hostFilesDir + '/' + name;
        if (!writeFileBuf(srcP, ab)) {
          this.arkLog('OPEN_SRC_WRITE_ERR ' + srcP);
          return 'false';
        }
      }
      // 临时文件 per-tab（TRUNC 覆盖语义不变；不在回调里删——与页面 XHR 竞态，2026-09-05）
      const inP = ctx.tabPath('open-in.' + extU);
      const outP = ctx.tabPath('open-in.bin');
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('OPEN_TMP_WRITE_ERR ' + inP);
        return 'false';
      }
      // x2t 按输入扩展名自动选 *2doct_bin 转换器；.bin 输出后缀已实机验证（POC 打开链 v10）
      const rc = x2tConvertSync(x2tXml(inP, outP));
      this.arkLog('OPEN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ') tab=' + ctx.id);
      if (rc !== 0) {
        this.arkLog('OPEN_X2T_FAIL ext=' + extU);
        return 'false';
      }
      const buf = readFileBuf(outP);
      if (buf === null) {
        this.arkLog('OPEN_BIN_MISS ' + outP);
        return 'false';
      }
      // per-tab 身份赋值（原保存链单例字段→ctx.state）
      if (newDoc) {
        ctx.state.name = '';
        ctx.state.ext = extU;
        ctx.state.saveTarget = 'none';
        ctx.state.savePath = '';
      } else {
        ctx.state.name = name;
        ctx.state.ext = extU;
        if (userUri !== undefined && userUri.length > 0) {
          // 历史 recents 的 path 是沙箱路径（=工作副本本身）→ 保存目标=沙箱；
          // 真实位置（file:/// 等）→ 保存覆盖用户文件
          ctx.state.saveTarget = userUri.indexOf(this.hostFilesDir) === 0 ? 'sandbox' : 'uri';
          ctx.state.savePath = userUri;
        } else {
          ctx.state.saveTarget = 'sandbox';
          ctx.state.savePath = this.hostFilesDir + '/' + name;
        }
        // recents 真数据（仅打开 addRecent=true 写入；新建不写）——path=保存目标真实路径
        if (addRecent) {
          const typeNum = extU === 'xlsx' ? RECENT_TYPE_XLSX : extU === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
          if (appendRecent(this.hostFilesDir, name, ctx.state.savePath, typeNum)) {
            this.arkLog('RECENTS_APPEND name=' + name + ' type=0x' + typeNum.toString(16));
          } else {
            this.arkLog('RECENTS_APPEND_ERR name=' + name);
          }
        }
      }
      ctx.state.pendingOpen = true;
      ctx.url = this.editorUrl(extU, name, ctx.id); // sid=tabId：强制唯一加载 + 事件归属
      const arr = this.docTabs.slice();
      const tArr = this.docTitles.slice();
      const aArr = this.docAccents.slice();
      arr.push(new DocTabPair(ctx));
      tArr.push(name.length > 0 ? name : this.defaultDocName(extU));
      aArr.push('');
      this.docTabs = arr;
      this.docTitles = tArr;
      this.docAccents = aArr;
      this.focusTab = this.docTabs.length - 1;
      this.arkLog('P1B_OPEN_TAB id=' + ctx.id + ' ext=' + extU + ' bin=' + buf.byteLength
        + ' target=' + ctx.state.saveTarget + ' name=' + name);
      return 'true';
    } catch (e) {
      this.arkLog('OPEN_CONVERT_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * LocalStartOpen 回调（引擎 isLoadFullApi && _isLoadedModules 完成时 sdkjs 调
   * window.AscDesktopEditor.LocalStartOpen()；common/Local/common.js:64 —— 引擎已就绪）。
   * 注入官方 api.js 字节通道：docEditor.openDocument({buffer})（api.js _openDocumentFromBinary
   * → postMessage+transfer → Gateway openDocumentFromBinary → Main.js loadBinary
   * → new Uint8Array → asc_openDocumentFromBytes —— 内部 checkStreamSignature 嗅探
   * DOCY/DV5 签名，与官方 C++ DesktopOfflineAppDocumentEndLoad 同构）。
   * 注：DesktopOfflineAppDocumentEndLoad 是编辑器 iframe 内 sdkjs 函数（顶层不可见）；
   *     API 层字节传送是官方唯一的跨 frame 通道。
   */
  /**
   * LocalStartOpen 回调（per-instance：dispatch 装配时绑定 ctx）——字节注入该实例。
   * 多文档下每个 doc 实例独立就绪、独立注入（open-in.<id>.bin 隔离）。
   */
  private onDocReady(docC: DocTabCtx): void {
    if (!docC.state.pendingOpen) {
      this.arkLog('LSO_NO_PENDING (editor ready, no doc — create:new?) tab=' + docC.id);
      return;
    }
    // tab 关闭守卫（探针注入不再进已消亡实例；注入路径本身判 null 不崩）
    const closedTab = (): boolean => {
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === docC) {
          return false;
        }
      }
      return true;
    };
    // 页面 XHR 拉取沙箱 doct_bin（rawfileLoader 已拦 userfile/ → filesDir 返回真字节）→
    // window.postMessage openDocumentFromBinary（官方 api.js/Gateway/loadBinary →
    // asc_openDocumentFromBytes，checkStreamSignature 嗅探 DOCY 签名 —— web/服务器链，
    // 与 3.7 web 语义（编辑器页删除 AscDesktopEditor）配套；桌面 doffline 链路待桌面
    // 字体/native 通路三件套齐备后再启用）。
    const js = '(function(){'
      + 'try{var x=new XMLHttpRequest();'
      + 'x.open("GET","http://localhost/userfile/open-in.' + docC.id + '.bin?v="+Date.now(),true);'
      + 'x.responseType="arraybuffer";'
      + 'x.onload=function(){try{var ab=x.response;'
      + 'if(!ab||!ab.byteLength){console.error("LSO_XHR_EMPTY st="+x.status);return;}'
      + 'window.postMessage({command:"openDocumentFromBinary",data:ab},"*");'
      + 'console.error("LSO_OPEN_DOCUMENT_OK len="+ab.byteLength);'
      + '}catch(e){console.error("LSO_LOAD_ERR "+String(e));}};'
      + 'x.onerror=function(){console.error("LSO_XHR_ERR st="+x.status);};'
      + 'x.send(null);}catch(e){console.error("LSO_INJECT_ERR "+String(e));}})();';
    docC.controller.runJavaScript(js, (err: BusinessError, res: string) => {
      if (err) {
        this.arkLog('LSO_INJECT_ERR ' + err.code + ' ' + err.message);
      } else {
        this.arkLog('LSO_INJECT_OK ' + res);
      }
      // 注：不再在此删除临时文件 —— runJavaScript 回调先于页面 XHR onload 返回，
      // 删文件会让 rawfileLoader 返回 404（实测 XHR 拿到 58B 的 "404: <url>" 响应体），
      // 与字节交付竞态。临时文件本就每轮 TRUNC 覆盖（见 openNewTabEntry），无需清理。
    });
    docC.state.pendingOpen = false; // 一次性（下次打开重新转换）
    // smoke 诊断（自动验收态才注入，产品无此行为）：页面状态快照（区分"主线程卡死"
    // vs "链未走完但页面活"）。脚本外置 rawfile/onlyoffice/smoke/prof-snap.js
    //（源 scripts/onlyoffice/smoke/——多行可读，不再以 TS 字符串内嵌单行）。
    if (Smoke.enabled()) {
      const snap = Smoke.readScript(this.resourceManager, 'prof-snap.js');
      if (snap === null) {
        this.arkLog('SMOKE_SNAP_MISSING');
      } else {
        const c1 = docC;
        setTimeout(() => {
          if (!closedTab()) {
            c1.js(snap, '');
          }
        }, 10000);
      }
      // AI 联网验证（2026-09-07 方案 A 放行）：与 AI 插件同形态的 fetch 直连
      // DeepSeek /v1（key 经启动参数 m7key 注入，不进 git/不落盘；见 ai_fetch_test.js）。
      const aiTest = Smoke.readScript(this.resourceManager, 'ai_fetch_test.js');
      if (aiTest === null) {
        this.arkLog('SMOKE_AITEST_MISSING');
      } else {
        const c2 = docC;
        setTimeout(() => {
          if (!closedTab) {
            c2.js(aiTest.replace('__AI_KEY__', Smoke.key), '');
          }
        }, 15000);
      }
    }
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.abilityCtx = ctx;
    this.resourceManager = ctx.resourceManager;
    this.hostFilesDir = ctx.filesDir;
    this.webLogPath = ctx.filesDir + '/web_console.txt';
    this.printFontDir = ctx.filesDir + '/printfonts';
    // 打印临时文件启动清扫（上次进程崩溃/强杀时任务终态回调未跑，文件会残留
    // 在沙箱；按前缀扫一遍删除。正常关闭路径已在任务终态/tab 关闭时清过）
    this.sweepPrintFiles();
    // 打印字体后台解包（~10MB 一次性；放启动后让位首屏。首次打印若仍未就绪
    // 由 ensurePrintFonts 同步补——正确性不依赖本调用）
    setTimeout(() => {
      this.ensurePrintFonts();
    }, 3000);
    // 系统三键 ✕ 关闭守卫（2026-09-10，WPS 同款正路）：EntryAbility 里
    // windowStageClose 恒拦（return true=不关窗）→ 本回调 = 与返回键同链的
    // requestBackExit（未保存逐个弹框→全处置完 terminateSelf；取消=窗口保留）。
    // 替代已移除的自绘关闭 ✕（系统三键本就常驻——decor 只藏标题栏）。
    setWindowCloseHandler((): void => {
      this.requestBackExit();
    });
    // 自动验收开关（ability 启动参数 → Smoke；见 smoke.ets / EntryAbility）：无参数 = 产品态
    Smoke.fromParams(getLaunchOptions());
    this.m7Target = Smoke.target;
    // 页面版本号（构建期生成 version.json）：资源变更 → URL ?v= 变化 → 系统缓存失效
    try {
      const vr = this.resourceManager.getRawFileContentSync('onlyoffice/version.json') as Uint8Array;
      const parsed = JSON.parse(u8ToStr(vr)) as Record<string, string>;
      this.pageVer = String(parsed['v'] ?? '0');
    } catch (e) {
      // version.json 缺失（本地调试/旧包）→ 默认 '0'，缓存不失效但功能不受影响
    }
    try {
      const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(f); // 每次启动清空 web 日志（避免无限增长/读旧日志）
    } catch (e) {
      // 忽略
    }
    this.copySandboxSamples(); // 样本 docx/xlsx/pptx：rawfile → 沙箱 filesDir（open 链走 userfile/；保存回写也落这里）
    // 自动验收诊断直达：跳过 welcome（loginpage 全量渲染可达 60-90s，且末轮设备状态
    // 出现 welcome 卡死）——启动即走打开链进编辑器页，PROF 剖面链（3.4 DI → Gateway
    // 字节注入 → serverId 踢闸 → loading 移除 → 工具栏判据）全靠编辑器页自身，
    // 无需 welcome/sdk。生产态（m7Target 空）即无此路径。
    // M7_DIRECT 前置：onPageEnd（welcome 完成）后触发 open（见 onPageEnd 分支）——
    // 不能放此处 setTimeout 3s：与 welcome 慢加载（60s+）竞争会被覆盖。
    this.m7DirectQueued = this.m7Target.length > 0;
    // P0 探针：启动参数 p0tabs=1 → 挂双实例验证骨架（tabs 数组用于 build 分支判断）
    this.p0On = getLaunchOptions()['p0tabs'] === '1';
    if (this.p0On) {
      try {
        const logFn: (m: string) => void = ((m: string) => this.arkLog(m));
        this.p0Tabs = [
          new P0TabPair(new P0TabCtx(1, '主页', this.homeUrl(), this.resourceManager!, this.hostFilesDir, logFn)),
          new P0TabPair(new P0TabCtx(2, 'P0 文档', this.editorUrl('docx', 'P0 验证'), this.resourceManager!, this.hostFilesDir, logFn))
        ];
        this.arkLog('P0_TABS_INIT n=' + this.p0Tabs.length
          + ' t1=' + this.p0Tabs[1].ctx.url);
      } catch (e) {
        this.arkLog('P0_TABS_ERR ' + String(e));
      }
    }
    // P1a 容器初始化：主页实例恒第一（常驻；doc 由打开/新建命令动态追加）
    if (!this.p0On) {
      try {
        const homeCtx = new DocTabCtx(0, 'home', '主页', this.homeUrl(),
          this.resourceManager!, this.hostFilesDir,
          ((m: string) => this.arkLog(m)), ((c: DocTabCtx) => this.onInstanceReady(c)),
          ((c: DocTabCtx) => this.onPageEndCB(c)));
        this.docTabs = [new DocTabPair(homeCtx)];
        this.docTitles = ['主页'];
        this.docAccents = [''];
        this.arkLog('P1A_TABS_INIT home=' + homeCtx.url);
      } catch (e) {
        this.arkLog('P1A_TABS_ERR ' + String(e));
      }
    }
  }

  /** rawfile 样本复制到沙箱 filesDir（open 链走 userfile/ 前缀；编辑/转换产物也在 filesDir）。
   *  仅自动验收态拷贝（m7Target 非空——阶段2 验收与产品分离）：产品路径不产生任何验收样本文件。
   *  样本集中 at rawfile/onlyoffice/smoke/samples/（2026-09-06 用户：smoke 文件单独
   *  目录存放；install_smoke 整目录拷贝保留 samples/ 子目录——读取须加 samples/ 段）。 */
  private copySandboxSamples(): void {
    if (!this.resourceManager || this.m7Target.length === 0) {
      return;
    }
    for (const name of ['sample.docx', 'sample.xlsx', 'sample.pptx', 'm7-open-test.docx']) {
      try {
        const raw = this.resourceManager.getRawFileContentSync('onlyoffice/smoke/samples/' + name) as Uint8Array;
        const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        if (!writeFileBuf(this.hostFilesDir + '/' + name, ab)) {
          this.arkLog('SAMPLE_COPY_ERR ' + name);
        }
      } catch (e) {
        this.arkLog('SAMPLE_COPY_ERR ' + name + ' ' + String(e));
      }
    }
  }

  /**
   * 页面实例就绪（Web onControllerAttached，每实例一次——节点复用不重装配）：
   * 桥装配（AscNative 注册）。P1a：装配与业务仍单例（handler/saveTarget 读 this）；
   * P1b 起 per-tab 化。升级自愈 cacheFlush 仅 home 实例执行（removeCache 对同一
   * user data dir 全实例生效——产品级一次即可）。
   */
  private onInstanceReady(ctx: DocTabCtx): void {
    // 升级自愈（2026-09-06 注释原文）：install -r 整包替换 rawfile，但 WebView 磁盘
    // 缓存（data/storage/el2/base/cache/web/Cache，install -r 不清空）中同 URL 旧响应
    // 可能被命中——主页面/编辑页 URL 已带 ?v=<资源哈希>（cache-bust）自愈，但插件
    // iframe 等子资源引用无版本参数（如 plugins/v1/plugins.js）——兜底：资源版本
    // 变化后首次启动 flush 一次（once per version；记录于 files/app_version.json）。
    // 前车之鉴：不得用缓存清理解释页面行为 bug。
    if (ctx.kind === 'home' && !this.cacheFlushed) {
      this.cacheFlushed = true;
      try {
        const vRaw = this.resourceManager?.getRawFileContentSync('onlyoffice/version.json') as Uint8Array | undefined;
        const cur = vRaw ? String((JSON.parse(u8ToStr(vRaw)) as Record<string, string>).v || '') : '';
        const metaP = this.hostFilesDir + '/app_version.json';
        let old = '';
        const oldB = readFileBuf(metaP);
        if (oldB) {
          old = u8ToStr(new Uint8Array(oldB)).trim();
        }
        if (old !== cur) {
          ctx.controller.removeCache(true);
          const curBytes = new Uint8Array(cur.length);
          for (let bi = 0; bi < cur.length; bi++) {
            curBytes[bi] = cur.charCodeAt(bi);
          }
          writeFileBuf(metaP, curBytes);
          this.arkLog('VERSION_CACHE_FLUSH v=' + cur + ' (was ' + (old || 'none') + ')');
        }
      } catch (ce) {
        this.arkLog('VERSION_CACHE_ERR ' + String(ce));
      }
    }
    // ascNative 字段保持强引用（registerJavaScriptProxy 代理对象避免被回收）。
    const nativeDispatch = new AscNativeDispatch(this.hostFilesDir, ((m: string) => this.arkLog(m)));
    // LoadFontBase64 桥（引擎桌面路径取字体字节）：rawfile/onlyoffice/fonts/<id>
    // —— 2026-09-05 根因修复（此前缺失 → CJK 字体流空 → 方块）
    nativeDispatch.setRawReader((p: string) => {
      const raw = this.resourceManager?.getRawFileContentSync(p);
      return raw ? (raw as Uint8Array) : null;
    });
    // per-instance 装配：handler/LocalStartOpen/save:type 全部绑定该 ctx
    // （P1b 核心——多文档并存：每实例的保存/注入只走自己的 per-tab 状态）
    nativeDispatch.setHandler(new ShellCommandHandler(this, ctx));
    nativeDispatch.setLocalStartOpenHandler(() => {
      this.onDocReady(ctx);
    });
    // 主题色上报（页面 00_theme 0.10 → 本实例的 chip 激活色）
    nativeDispatch.setThemeReporter((payload: string) => {
      return this.onThemeReport(ctx, payload);
    });
    // 放映全屏（sdkjs 放映引擎 SetFullscreen → 壳层窗口/tab 条；2026-09-11）：
    // 窗口级操作，不区分发起实例（与 go:folder 同型）。
    nativeDispatch.setFullscreenHandler((on: boolean) => {
      this.onFullscreenReq(on);
    });
    // save:type 询问（per-tab 单一事实源）：页面 asc_Save 同步询问保存目标——
    // 'none'（autosave 跳过/用户保存→另存为）| 'sandbox' | 'uri'
    nativeDispatch.setSaveTargetReader(() => ctx.state.saveTarget);
    this.ascNative = new AscNativeBridge(nativeDispatch);
    ctx.controller.registerJavaScriptProxy(this.ascNative, 'AscNative', ['_call', '_onReady'], []);
    this.arkLog('P1A_INSTANCE_READY kind=' + ctx.kind + ' id=' + ctx.id);
  }

  /** onPageEnd（每实例首次到达）：M7 直达（仅 home）+ 页面级错误采集（每实例幂等） */
  private onPageEndCB(ctx: DocTabCtx): void {
    const cu = ctx.controller.getUrl();
    // M7 诊断直达：welcome（首页）完成加载后触发样本打开（避开加载竞争；仅 home）
    if (ctx.kind === 'home' && this.m7DirectQueued && cu.indexOf('/main/index.html') < 0) {
      this.m7DirectQueued = false;
      try {
        const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/smoke/samples/' + this.m7Target) as Uint8Array;
        const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        const ext = this.m7Target.substring(this.m7Target.lastIndexOf('.') + 1).toLowerCase();
        this.arkLog('M7_DIRECT_OPEN ' + this.m7Target + ' len=' + ab.byteLength);
        this.openNewTabEntry(ab, ext, this.m7Target, true, false);
      } catch (e) {
        this.arkLog('M7_DIRECT_ERR ' + String(e));
      }
    }
    // 页面级错误采集（onerror/unhandledrejection 是最直接证据；JS 内幂等 __ooh_installed）
    const inject = `(function(){
if(window.__ooh_installed){return;}
window.__ooh_installed=true;
try{var _er0=window.onerror;window.onerror=function(msg,src,ln,cl,err){console.error('JSERR '+String(msg).slice(0,160)+' @'+String(src||'').slice(-40)+':'+ln);if(_er0)return _er0.apply(this,arguments);return false;};}catch(e){}
try{window.addEventListener('unhandledrejection',function(ev){console.error('UHR '+String(ev.reason&&ev.reason.message||ev.reason).slice(0,160));});}catch(e){}
})();`;
    ctx.js(inject, '');
  }

  /** tab id → DocTabCtx（守卫/关闭共用；未找到=已关闭 → null） */
  private findCtx(id: number): DocTabCtx | null {
    for (let i = 0; i < this.docTabs.length; i++) {
      if (this.docTabs[i].ctx.id === id) {
        return this.docTabs[i].ctx;
      }
    }
    return null;
  }

  /**
   * 未保存关闭守卫（2026-09-09，docs/UNSAVED_CLOSE_GUARD_DESIGN.md §3）——
   * 所有「关闭文档」入口统一入口：关闭瞬间向页面点查官方引擎 API。句柄链（真机实证
   * 2026-09-09）：window.<SSE|DE|PE>.controllers.Main.api —— **controllers 是小写**
   * （打包后实际名；源码写 <NS>.Controllers.Main 大写是写法，运行时不存在大写 C——
   * ascshim LSO_KICK_SERVERID 链 10_engine 同句柄可用，为唯一实证句柄；window.editor/
   * window.Asc.editor 此壳不存在）。查询 API：asc_isDocumentCanSave（三引擎均含，
   * DE 官方自身以它判 onDocumentModifiedChanged 的 isModified——Main.js:2575）；
   * asc_isDocumentModified 仅 cell 引擎有（保底）。
   *   '1' 未保存 → 三按钮弹框（保存/不保存/取消；不调用官方 web 两按钮框——无保存项）
   *   '0' 干净/未就绪 → 直关（closeDocTab 权威关闭）
   *   '2'/查询失败/页面死 → 直关（数据已不可救，守卫只会死锁——日志留证）
   * then：窗口级退出队列继续回调（undefined=tab 级关闭）；proceed=false=用户取消
   */
  private requestCloseDoc(ctx: DocTabCtx, then?: (proceed: boolean) => void): void {
    if (this.guardBusy || this.closeGuardDefer !== null) {
      // 查询/弹框/保存在途：不叠新询问（弹框模态应在 UI 层挡住；防御路径=日志留证）
      this.arkLog('CLOSE_GUARD_BUSY tab=' + ctx.id);
      return;
    }
    this.guardBusy = true;
    try {
      // 判据=canSave || isDocumentModified（2026-09-10 打开已有文档**守卫失灵**修复：
      // 真机实证「zzz 修改后 asc_isDocumentCanSave=0 但 asc_getCanUndo=1」——引擎确认
      // 有未保存修改；canSave 属性由 _onUpdateDocumentCanSave 刷新，本链时序未触发
      // （官方 Desktop 语义同源；官方自身判未保存=isDocumentModified——Main.js:2575）。
      // isDocumentModified()=原型方法三引擎均有（word/slide 72179 式 = isDocumentModify
      // 属性——保存后复位，不误判；cell 另有 asc_ 前缀版）。返回管道串 vcs|im|uu：
      // im 兜底 cs，uu 仅打点（canUndo 保存后栈不清——不可作判据）。
      const query = '(function(){try{'
        + 'var ns=window.SSE||window.DE||window.PE;'
        + 'var m=ns&&ns.controllers&&ns.controllers.Main;'
        + 'var e=m&&m.api;'
        + 'var cs="na",im="na",uu="nu";'
        + 'try{cs=(e&&typeof e.asc_isDocumentCanSave==="function")?(e.asc_isDocumentCanSave()?"1":"0"):"na";}catch(x){cs="x";}'
        + 'try{im=(e&&typeof e.isDocumentModified==="function")?(e.isDocumentModified()?"1":"0"):"na";}catch(x){im="x";}'
        + 'try{uu=(e&&typeof e.asc_getCanUndo==="function")?(e.asc_getCanUndo()?"1":"0"):"nu";}catch(x){uu="x";}'
        + 'return "v"+cs+"|"+im+"|"+uu;'
        + '}catch(x){return "vj|j|j";}})()';
      ctx.controller.runJavaScript(query, (err: BusinessError, res: string) => {
        if (err) {
          // 页面死/节点已分离（竞态）——守卫只死锁，放行关闭
          this.guardBusy = false;
          this.arkLog('CLOSE_GUARD_QUERY_ERR tab=' + ctx.id + ' ' + String(err.code));
          this.closeDocTab(ctx.id);
          if (then !== undefined) { then(true); }
          return;
        }
        // ArkWeb runJavaScript 对 JS 字符串返回值做 **JSON 编码**（实测 res=`"1"` 带引号
        // ——2026-09-09 实证；直接 === '1' 永假会落进直关分支。统一 JSON.parse 剥外层，
        // 得 "vcs|im|uu" 拼接串再拆；**v = cs || im || uu**（2026-09-10 打开已有文档
        // 修复：cs/im 在该形态下恒 0（引擎 modified 标志链未随编辑触发——实测
        // zzz 后 cs=0 im=0 uu=1，而保存产物含 zzz），uu=asc_getCanUndo 是引擎唯一
        // 权威「有变更」信号。已知代价：保存链（ArkTS 侧序列化）不经引擎，undo 栈
        // 不清——已保存后再次关闭会重弹一次（保存幂等覆写，不丢数据——记录取舍）。
        let v: string = String(res);
        let diag: string = 'na';
        try {
          const pv = String(JSON.parse(String(res)) as string).trim();
          const parts = pv.split('|');
          const cs = parts[0].replace(/^v/, '');
          const im = parts[1] ?? '?';
          const uu = parts[2] ?? '?';
          diag = 'cs=' + cs + ' im=' + im + ' uu=' + uu;
          v = (cs === '1' || im === '1' || uu === '1') ? '1' : '0';
        } catch (pe) {
          v = String(res);
        }
        v = v.trim();
        this.arkLog('CLOSE_GUARD_QUERY tab=' + ctx.id + ' v=' + v + ' ' + diag);
        if (v !== '1' && ctx.state.saveAborted) {
          // 引擎 CanSave 已被 asc_Save 复位但保存未落盘（另存为取消/失败/超时）——
          // 数据真没保存：忽略页面 '0'，按未保存弹框（2026-09-09 真机实锤场景）
          this.arkLog('CLOSE_GUARD_SAVEABORTED tab=' + ctx.id + ' v=' + v);
          this.showCloseGuardDialog(ctx, then);
          return;
        }
        if (v === '1') {
          this.arkLog('CLOSE_GUARD_MODIFIED tab=' + ctx.id);
          this.showCloseGuardDialog(ctx, then);
          return; // guardBusy 由弹框回调消费复位
        }
        if (v === '2') {
          this.arkLog('CLOSE_GUARD_UNKNOWN tab=' + ctx.id);
        }
        this.guardBusy = false;
        this.closeDocTab(ctx.id);
        if (then !== undefined) { then(true); }
      });
    } catch (e) {
      this.guardBusy = false;
      this.arkLog('CLOSE_GUARD_ERR ' + String(e));
      this.closeDocTab(ctx.id);
      if (then !== undefined) { then(true); }
    }
  }

  /**
   * 三按钮弹框（**自绘覆盖层**——2026-09-10 用户要求显式「取消」键后改过两版：
   * ①AlertDialog 仅两 action 键无取消；②CustomDialog 真机点击失效——按钮 onClick
   * 不触发、事件未达 ArkTS（uinput+手指双证，点击后无任何回调日志应用却退出）——
   * 页面层 Stack 覆盖层全量自绘：onClick 全在自己手里，零系统弹层依赖）。
   * 「取消」=什么都不做（关弹框、留文档）；蒙层点击亦=取消（autoCancel 语义）。
   * guardThen=窗口级回调节（requestCloseDoc then 透传；需存于页面字段——
   * @State 不支持函数闭包对象，双字段拆存）。
   */
  private showCloseGuardDialog(ctx: DocTabCtx, then?: (proceed: boolean) => void): void {
    let name = ctx.state.name;
    if (name.length === 0) {
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === ctx) {
          name = this.docTitles[i];
          break;
        }
      }
    }
    if (name.length === 0) {
      name = this.defaultDocName(ctx.state.ext);
    }
    this.guardDialogName = name;
    this.guardDialogCtx = ctx;
    this.guardDialogThen = then;
    this.guardDialogOn = true;
    this.arkLog('CLOSE_GUARD_DIALOG_ON tab=' + ctx.id);
  }

  /**
   * 「保存」动作：挂 defer → 触发页面 asc_Save()（40_save 原型覆写 → save:bin →
   * ArkTS x2t → 已命名=覆写目标 / 新建=系统另存为框）。完成信号：
   *   save:bin handler 同步完成（uri/sandbox）或 doSaveAs 完成（none）——再关闭。
   * 失败/取消/10s 超时（页面链断/引擎卡）→ 清 defer 不关（数据不丢优先）。
   */
  private saveAndClose(ctx: DocTabCtx, then?: (proceed: boolean) => void): void {
    if (this.closeGuardDefer !== null) {
      this.closeGuardDefer = null; // 防御（弹框互斥，理论上不双在途）
    }
    this.closeGuardDefer = { ctx: ctx, awaitingSaveAs: false, then: then };
    const js = '(function(){try{'
      + 'var ns=window.SSE||window.DE||window.PE;'
      + 'var m=ns&&ns.controllers&&ns.controllers.Main;'
      + 'var e=m&&m.api;'
      + 'if(e&&typeof e.asc_Save==="function"){e.asc_Save();return "ok";}'
      + 'return "noed";}catch(x){return "err";}})()';
    ctx.controller.runJavaScript(js, (err: BusinessError, res: string) => {
      // 同 requestCloseDoc：ArkWeb JSON 编码字符串返回值（带引号）——必须先解
      let rv: string = String(res);
      try {
        const pv2: string | number = JSON.parse(String(res)) as string | number;
        rv = String(pv2);
      } catch (pe2) {
        rv = String(res);
      }
      if (err || rv.indexOf('ok') < 0) {
        // 保存入口不可用（页面死/无 asc_Save）——不关（与保存失败同语义）
        this.arkLog('CLOSE_GUARD_SAVE_ERR tab=' + ctx.id + ' res=' + rv);
        this.clearCloseGuard(ctx, false);
      }
    });
    // 超时兜底：页面 save:bin 链断/引擎卡（awaitingSaveAs 在途=系统另存为框，不在此列）
    setTimeout(() => {
      if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx
        && !this.closeGuardDefer.awaitingSaveAs) {
        this.arkLog('CLOSE_GUARD_SAVE_TIMEOUT tab=' + ctx.id);
        this.clearCloseGuard(ctx, false);
      }
    }, 10000);
  }

  /**
   * 守卫 defer 消费（唯一出口）：ok=true → 关闭目标 tab（保存成功）；false → 不关
   *（取消/失败/超时）。then 继续窗口退出队列（proceed=ok；不关=终止队列语义由调用方
   * 解释——back 队列 read proceed，tab 级无 then）。
   */
  private clearCloseGuard(ctx: DocTabCtx, ok: boolean): void {
    const d = this.closeGuardDefer;
    if (d === null || d.ctx !== ctx) {
      return;
    }
    this.closeGuardDefer = null;
    if (ok) {
      // 保存真正落盘：清「保存中止」标记（下次守卫以页面 CanSave 为准）
      ctx.state.saveAborted = false;
      this.closeDocTab(ctx.id);
    } else {
      // 保存未完成（另存为取消/落盘失败/超时）：标记数据仍未保存——
      // 页面 CanSave 已复位（asc_Save 触发过），下次关闭守卫必须忽略 '0' 再弹框
      ctx.state.saveAborted = true;
      this.arkLog('CLOSE_GUARD_SAVE_INCOMPLETE tab=' + ctx.id);
    }
    if (d.then !== undefined) {
      d.then(ok);
    }
  }

  /**
   * 系统返回键 = 关闭窗口守卫（设计 §3.5）：收集全部 doc tab（从焦点起），逐个询问
   * 未保存（保存/不保存 → 继续下一个；取消 → 停，留在应用）；队列全处置完 →
   * terminateSelf 退出（返回键语义=关闭窗口）。无 doc tab/仅主页 → 放行系统退出。
   * 守卫弹框在途（defer/查找期）→ 拦截（不叠框）。
   */
  onBackPress(): boolean {
    if (this.p0On) {
      return false;
    }
    // 放映中：返回键 = 退出放映（tab 条隐藏时这是系统侧唯一出口；退放映 ≠ 关文档）。
    // 不自行改状态——注入官方公开 API EndDemonstration() 让引擎走完整退出流程
    // （End → SetFullscreen(false) → 桥回调恢复壳层），避免「tab 条回来了但放映
    // 画面还在」的半拍状态。
    if (this.fsMode) {
      this.exitPresentation();
      return true;
    }
    // 返回键与系统三键 ✕ 同语义（requestBackExit——系统 ✕ 经 EntryAbility
    // windowStageClose → 本方法）：返回 true=拦截（退出时机由守卫队列决定）；
    // false=放行系统默认（无文档/探针态）
    return this.requestBackExit();
  }

  /**
   * 关闭窗口（系统返回键 / 系统三键 ✕ 共用——✕ 经 EntryAbility windowStageClose 恒
   * 拦后调用本方法）：收集全部 doc tab（从焦点起），逐个询问未保存（保存/不保存 →
   * 继续下一个；取消 → 清队列停：留在应用）；队列全处置完 → terminateSelf 退出
   * （关闭窗口语义）；无 doc tab（仅主页）→ 直接退出。
   * 返回值恒定 true=本层已接管退出时机（onBackPress 拦截系统默认；系统 ✕ 侧由
   * EntryAbility 的 return true 拦截）；守卫在途（defer/查询/弹框）→ 同样 return
   * true 只挡不叠（弹框层自己消费返回键）。p0On 探针态由 onBackPress 先行放行。
   */
  private requestBackExit(): boolean {
    if (this.closeGuardDefer !== null || this.guardBusy) {
      return true; // 有在途守卫流程：弹框 layer 自己消费，本层只挡默认退出
    }
    const docCtxs: DocTabCtx[] = [];
    for (let i = 0; i < this.docTabs.length; i++) {
      if (this.docTabs[i].ctx.kind === 'doc') {
        docCtxs.push(this.docTabs[i].ctx);
      }
    }
    if (docCtxs.length === 0) {
      // 无文档：窗口 ✕ 语义=直接退出；返回键语义=放行系统退出——统一在此退出
      const ac = getContext(this) as common.UIAbilityContext;
      ac.terminateSelf();
      return true;
    }
    this.backQueue = docCtxs;
    this.processBackQueue();
    return true; // 退出时机由队列决定
  }

  /** 窗口退出队列处理（一次一个——多文档未保存不叠框）。
   * 注：队列串行由模态弹框保证——requestCloseDoc 返回后必有回调（查询/弹框 callback）；
   *   BUSY 直 return（弹框/保存在途）理论上不可达（上一元素回调前队列不动）；若可达
   *   队列会停（应用不退出）而非错关——以数据安全为先，可接受。 */
  private processBackQueue(): void {
    const next = this.backQueue.shift();
    if (next === undefined) {
      // 队列空：全部处置完（关/保存成功）→ 退出应用
      const ac = getContext(this) as common.UIAbilityContext;
      ac.terminateSelf();
      return;
    }
    this.requestCloseDoc(next, (proceed: boolean) => {
      if (!proceed) {
        this.backQueue = []; // 用户取消 → 停
        return;
      }
      this.processBackQueue();
    });
  }

  /**
   * 关闭 doc tab（file:close / tab ×）：移除节点（挂载即销毁）+ 标题同步。
   * 关闭后聚焦相邻（2026-09-09 用户需求）：关激活 tab → 选随后一个顶替原位的
   * （关尾 → 前一个）；关非激活 tab → 焦点保持指向原来那个（数组前移一位）。
   * 权威关闭（无守卫——守卫在 requestCloseDoc；本方法经守卫决策后触发）。
   */
  private closeDocTab(id: number): void {
    try {
      let idx = -1;
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx.id === id) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        return;
      }
      const wasFocus = this.focusTab === idx;
      // 打印临时文件**不在此清**：任务可能在系统打印框里排队未终态（printPdf 注释：
      // 文件须活到任务终态）。残留由任务终态回调 / 启动 sweepPrintFiles 兜底。
      const arr = this.docTabs.slice();
      arr.splice(idx, 1);
      this.docTabs = arr;
      const tArr = this.docTitles.slice();
      tArr.splice(idx, 1);
      this.docTitles = tArr;
      const aArr = this.docAccents.slice();
      aArr.splice(idx, 1);
      this.docAccents = aArr;
      if (wasFocus) {
        // 相邻归位：原位置（idx）由后一个顶替；关的是最后一个 → 前一个
        this.focusTab = Math.min(idx, this.docTabs.length - 1);
      } else if (this.focusTab > idx) {
        // 非激活关闭：数组前移，焦点保持指向同一文档
        this.focusTab = this.focusTab - 1;
      }
      this.arkLog('P1B_CLOSE_TAB id=' + id + ' focus=' + this.focusTab);
    } catch (e) {
      this.arkLog('P1A_CLOSE_TAB_ERR ' + String(e));
    }
  }

  /**
   * 主题色上报处理（页面 00_theme 0.10）：payload JSON {app,color}——color=当前主题
   * CSS 变量 --toolbar-header-<app> 的实际值（官方 colors-table-<theme>.less 定义
   * 为主题内配置，主题切换重报）。缓存到 docAccents（索引与 docTabs 对齐——选中
   * chip 颜色跟随文档页当前主题色，官方桌面特性）。
   */
  private onThemeReport(ctx: DocTabCtx, payload: string): string {
    try {
      const o = JSON.parse(payload) as Record<string, string>;
      const color = String(o['color'] ?? '').trim();
      if (color.length === 0) {
        return 'true';
      }
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === ctx) {
          const aArr = this.docAccents.slice();
          // 防御：上报到已关闭/未初始化 tab（race 时 docAccents 可能短于 docTabs）
          // ——下标缺失段补 ''（静态 accent 兜底），避免数组空洞
          if (i < aArr.length) {
            aArr[i] = color;
          } else {
            aArr.push(color);
          }
          this.docAccents = aArr;
          break;
        }
      }
      this.arkLog('THEME_COLOR tab=' + ctx.id + ' ' + color);
    } catch (e) {
      this.arkLog('THEME_COLOR_ERR ' + String(e));
    }
    return 'true';
  }

  /**
   * 放映全屏请求（页面 sdkjs 放映引擎 SetFullscreen 桥 → ascBridge → 本方法）。
   * 语义 = 官方桌面版：放映开始让出整屏（Pad 收 tab 条；PC 沉浸最大化），结束精确
   * 还原。幂等（引擎可能重复发同值——StartWaitReporter/Start 双路径）。
   * 判据日志：LSO_FULLSCREEN 1/0。
   */
  private onFullscreenReq(on: boolean): void {
    if (on === this.fsMode) {
      return;
    }
    this.fsMode = on;
    this.arkLog('LSO_FULLSCREEN ' + (on ? '1' : '0'));
    this.applyFsWindow(on);
  }

  /**
   * 窗口形态随放映切换（PC；Pad 已由 EntryAbility.applyWindowMode 沉浸，只切 tab
   * 条）。参照 ../wineohos .../VirtualDesktopAbility.ets:78-127（PC 虚拟桌面全屏）：
   *   进入 = maximize(ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)——用 DISABLE_HOVER
   *     变体而非默认 ENTER_IMMERSIVE：铺满的同时鼠标贴屏幕边缘不唤出标题栏/dock
   *     （wineohos 全屏游戏同因；放映时鼠标划到边缘不该弹系统 UI）。
   *   退出 仅当仍处 FULL_SCREEN（说明用户没手动退过全屏）才还原——FLOATING/
   *     SPLIT_SCREEN → recover() 回浮动；本已是 MAXIMIZE/FULL_SCREEN →
   *     maximize(EXIT_IMMERSIVE) 保持最大化、只退沉浸。用户放映中自行退出全屏
   *     （系统手势）→ 读到的当前态已非 FULL_SCREEN → 不干预（不再动用户调好的窗口）。
   * 时序：fire-and-forget（桥同步、窗口 API 异步）——失败仅日志，不阻断放映。
   */
  private applyFsWindow(on: boolean): void {
    try {
      const dt = deviceInfo.deviceType;
      if (dt === 'tablet' || dt === 'phone') {
        return; // Pad：窗口已沉浸（EntryAbility.applyWindowMode），此处只切 tab 条
      }
      const actx = this.abilityCtx;
      if (actx === undefined) {
        this.arkLog('LSO_FS_WIN no context');
        return;
      }
      window.getLastWindow(actx).then((mw: window.Window) => {
        try {
          if (on) {
            this.fsPreStatus = mw.getWindowStatus();
            this.arkLog('LSO_FS_WIN pre=' + this.fsPreStatus);
            mw.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)
              .then(() => {
                this.arkLog('LSO_FS_WIN enter ok');
              })
              .catch((e: BusinessError) => {
                this.arkLog('LSO_FS_WIN enter err ' + e.code + ' ' + e.message);
              });
          } else {
            const cur = mw.getWindowStatus();
            const pre = this.fsPreStatus;
            this.fsPreStatus = -1;
            this.arkLog('LSO_FS_WIN cur=' + cur + ' pre=' + pre);
            if (cur !== window.WindowStatusType.FULL_SCREEN) {
              return; // 用户已自行退出全屏 → 不干预
            }
            if (pre === window.WindowStatusType.MAXIMIZE
              || pre === window.WindowStatusType.FULL_SCREEN) {
              mw.maximize(window.MaximizePresentation.EXIT_IMMERSIVE)
                .then(() => {
                  this.arkLog('LSO_FS_WIN exit-immersive ok');
                })
                .catch((e: BusinessError) => {
                  this.arkLog('LSO_FS_WIN exit-immersive err ' + e.code + ' ' + e.message);
                });
            } else {
              mw.recover()
                .then(() => {
                  this.arkLog('LSO_FS_WIN recover ok');
                })
                .catch((e: BusinessError) => {
                  this.arkLog('LSO_FS_WIN recover err ' + e.code + ' ' + e.message);
                });
            }
          }
        } catch (e2) {
          this.arkLog('LSO_FS_WIN inner err ' + String(e2));
        }
      }).catch((e: BusinessError) => {
        this.arkLog('LSO_FS_WIN getwin err ' + e.code + ' ' + e.message);
      });
    } catch (e) {
      this.arkLog('LSO_FS_WIN err ' + String(e));
    }
  }

  /**
   * 退出放映（返回键路径；2026-09-11）。注入官方公开 API `window.editor.
   * EndDemonstration()`（sdkjs api.js:10023 导出为公开成员；web-apps 放映控制条
   * ✕ 按钮 DocumentPreview.js:246 同款调用）——引擎走完整退出流程：
   * DemonstrationManager.End → SetFullscreen(false) → 桥回调 → 壳层还原。
   * 兜底：注入后 1s 仍未见桥回调（实例已关/API 缺失等）→ 自查恢复壳层，保证用户
   * 不会卡在「tab 条隐藏」态（幂等：fsMode 已 false 则无操作）。
   */
  private exitPresentation(): void {
    let sent = 0;
    for (let i = 0; i < this.docTabs.length; i++) {
      const c = this.docTabs[i].ctx;
      if (c.kind === 'doc' && c.state.ext === 'pptx' && c.attached) {
        sent++;
        c.js('(function(){try{if(window.editor&&window.editor.EndDemonstration){'
          + 'window.editor.EndDemonstration();console.error("LSO_END_DEMO ok");}'
          + 'else{console.error("LSO_END_DEMO noapi");}}catch(e){'
          + 'console.error("LSO_END_DEMO err "+e);}})();', '');
      }
    }
    this.arkLog('LSO_END_DEMO sent=' + sent);
    setTimeout(() => {
      if (this.fsMode) {
        this.arkLog('LSO_END_DEMO timeout force-exit');
        this.onFullscreenReq(false);
      }
    }, 1000);
  }

  /** tab 切换（DocTabHost.onSwitch）：非激活实例打点（P0 判据复用：后台实例活） */
  private onSwitchTab(idx: number): void {
    // 兜底：放映中切 tab（正常态 tab 条已收起点不到；防御 openNewTabEntry 等程序化
    // 切换）→ 先退放映全屏，避免壳层停在「tab 条隐藏」态而切不回。
    if (this.fsMode) {
      this.onFullscreenReq(false);
    }
    for (let i = 0; i < this.docTabs.length; i++) {
      const c = this.docTabs[i].ctx;
      if (i !== idx && c.attached) {
        c.js('(function(){try{console.error("P1A_ALIVE ' + c.kind + c.id
          + ' rd="+document.readyState);}catch(e){console.error("P1A_ALIVE_ERR "+e);}})();', '');
      }
    }
  }

  build() {
    Stack() {
      if (this.p0On) {
        // P0 探针分支：p0tabs=1（ability 启动参数）挂载多实例验证骨架；产品态恒 else
        P0TabsProbe({ tabs: $p0Tabs })
      } else {
        // P1b 容器：主页常驻（恒第一）+ doc tab 多开（NodeContainer 节点复用=切回零重建）
        DocTabHost({
          tabs: $docTabs,
          focus: $focusTab,
          titles: $docTitles,
          accents: $docAccents,
          // 放映全屏：true 时收起 tab 条（Web 区自动吸顶铺满）
          fsMode: $fsMode,
          // tab × = 未保存守卫入口（2026-09-09：查询 asc_isDocumentModified → 三按钮框）
          onCloseDoc: (id: number) => {
            const c = this.findCtx(id);
            if (c !== null) {
              this.requestCloseDoc(c);
            } else {
              this.arkLog('CLOSE_DOC_PAIR_NULL id=' + id);
            }
          },
          onSwitch: (idx: number) => this.onSwitchTab(idx)
        })
      }
      // —— 未保存守卫弹框（自绘覆盖层；Stack 顶层压住全部组件）——
      if (this.guardDialogOn) {
        // 蒙层=取消（autoCancel 同语义）：整体遮罩点击关闭弹框、不动文档
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            this.guardDialogAction('cancel');
          })
        // 弹框卡片（居中）
        Column({ space: 4 }) {
          Text('未保存的文档')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2B3B4D')
          Text('文档「' + this.guardDialogName + '」有未保存的修改。\n是否保存数据再退出？')
            .fontSize(14).fontColor('#5A6572').textAlign(TextAlign.Center)
            .margin({ top: 12 })
          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .backgroundColor('#F7F7F7').fontColor('#2B3B4D')
              .onClick(() => {
                this.guardDialogAction('cancel');
              })
            Button('不保存')
              .layoutWeight(1)
              .backgroundColor('#F7F7F7').fontColor('#2B3B4D')
              .onClick(() => {
                this.guardDialogAction('discard');
              })
            Button('保存')
              .layoutWeight(1)
              .backgroundColor('#0064E7').fontColor(Color.White)
              .onClick(() => {
                this.guardDialogAction('save');
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .padding(24)
        .width(420)
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层取消）
        })
      }
    }
  }

  /** 守卫弹框三按钮/蒙层动作分发（自绘层唯一出口；同版三回调语义：
   *  save=守卫保存链 / discard=丢弃关闭+继续队列 / cancel=不动文档） */
  private guardDialogAction(act: string): void {
    if (!this.guardDialogOn) {
      return;
    }
    const ctx = this.guardDialogCtx;
    const then = this.guardDialogThen;
    this.guardDialogOn = false;
    this.guardDialogCtx = null;
    this.guardDialogThen = undefined;
    this.guardBusy = false;
    if (ctx === null) {
      this.arkLog('CLOSE_GUARD_ACTION_CTX_NULL act=' + act);
      if (then !== undefined) {
        then(false);
      }
      return;
    }
    if (act === 'save') {
      this.arkLog('CLOSE_GUARD_SAVE_BTN tab=' + ctx.id);
      this.saveAndClose(ctx, then);
    } else if (act === 'discard') {
      this.arkLog('CLOSE_GUARD_DISCARD tab=' + ctx.id);
      this.closeGuardDefer = null;
      this.closeDocTab(ctx.id);
      if (then !== undefined) {
        then(true);
      }
    } else {
      this.arkLog('CLOSE_GUARD_CANCEL tab=' + ctx.id);
      if (then !== undefined) {
        then(false); // 取消=什么都不做（队列停/不关文档）
      }
    }
  }
}
