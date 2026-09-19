import { BusinessError, deviceInfo, print } from '@kit.BasicServicesKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { promptAction, window } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { x2tConvertSync, X2T_RC_NEED_PASSWORD, X2T_RC_BAD_PASSWORD, X2T_RC_DRM_UNSUPPORTED } from '../common/x2t';
import { AscNativeBridge, AscNativeDispatch, AscCommandHandler } from '../common/ascBridge';
import { Smoke } from '../common/smoke';
import { getLaunchOptions, setWindowCloseHandler, setWantUriHandler, takeLaunchUri } from '../entryability/EntryAbility';
import { b64ToBuf, readFileBuf, writeFileBuf, x2tXml, x2tXmlFont, u8ToStr } from '../common/bytes';
import { appendRecent, RECENT_TYPE_DOCX, RECENT_TYPE_XLSX, RECENT_TYPE_PPTX } from '../common/recents';
import { encodeUrlParam, pickFontFile, importFontFile, listFontItems, removeFont,
  MAX_FONTS, FontListItem } from '../common/userFonts';
import { specOf, pickerSuffixes, pickerFilterOption, editorAppOf, needsSaveAsPrompt, isLossySave, checkSaveOut } from '../common/formats';
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

/** 图片替换/插入的默认后缀集（accept 给不出可用后缀时兜底） */
const IMAGE_SUFFIXES: string[] = ['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp',
  '.tif', '.tiff', '.svg'];

/**
 * ArkWeb accept 类型 → picker 后缀过滤。页面 `<input type=file>` 的 accept 由 sdkjs
 * 图片属性给出（形如 '.png,.jpg' 或 'image/*'）；picker 只认后缀形态，通配/空则用
 * 图片后缀集兜底（插入图片是当前唯一的页面侧文件选择场景）。
 *
 * 与 formats.pickerFilterOption 同一条约束：fileSuffixFilters 的每个元素 = 下拉里的
 * 一个**选项**且默认只选中第一项，逐后缀传元素会让用户只看到第一种后缀的图片
 * → 合并进单个选项（后缀逗号分隔）。
 */
function imageSuffixesFrom(accept: string[]): string[] {
  const out: string[] = [];
  for (const a of accept) {
    const t = a.trim().toLowerCase();
    if (t.startsWith('.') && t.length > 1) {
      out.push(t);
    } else if (t.indexOf('image/') === 0) {
      for (const suf of IMAGE_SUFFIXES) {
        out.push(suf);
      }
    }
  }
  return ['图片|' + (out.length > 0 ? out : IMAGE_SUFFIXES).join(',')];
}
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
  /** 「打开方式」待处理 uri（文件管理器交付；welcome 就绪后消费——与 m7 直达同理，
   *  避开 welcome 加载竞争）。空串=无待办 */
  private pendingWantUri: string = '';
  /** welcome 实例是否已首次加载完成（消费待办 uri 的门槛） */
  private homeReady: boolean = false;
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

  /** 格式提示覆盖层（不支持格式的告知 / 不能原地保存的格式另存确认；与守卫框互斥） */
  @State fmtDialogOn: boolean = false;
  @State fmtDialogText: string = '';
  private fmtDialogCtx: DocTabCtx | null = null;
  private fmtDialogOut: ArrayBuffer | null = null;
  /** 提示模式：false=「不能原地保存」→确认后另存为；true=csv「丢格式」→确认后原地回写 */
  private fmtDialogLossy: boolean = false;

  /** 文档密码弹框（自绘覆盖层，同守卫框；密文文档打开链需要用户输入密码）。
   *  pwdValue 绑定 TextInput；回调 null=取消（放弃打开该文档）。 */
  @State pwdDialogOn: boolean = false;
  @State pwdDialogMsg: string = '';
  @State pwdValue: string = '';
  private pwdDialogRetry: boolean = false;
  private pwdDialogCb: ((pwd: string | null) => void) | null = null;

  /** 字体管理弹层（自绘覆盖层，同守卫框；欢迎页侧栏「字体管理」入口）。
   *  rows 每次刷新**整体重建**——@State 只观测数组自身的增删，不观测数组内对象的
   *  属性变更，就地改字段不会重渲染。 */
  @State fontMgrOn: boolean = false;
  @State fontMgrRows: FontListItem[] = [];
  @State fontMgrBusy: boolean = false;
  /** 导入阶段：'' 空闲 / 'pick' 系统选择器在途 / 'import' 读+落盘（按钮文案跟着走） */
  @State fontMgrStage: string = '';

  /** 手机原生主页「关于」弹层（自绘覆盖层）：合规内容与 Web 版 About 一致
   *  （品牌/版本/AGPL 行/源码与声明行——CREDIT、SOURCE_LINE 同源文案的 ArkTS 版）。
   *  licText 非空=正在查看对应文本（LICENSE/NOTICE 全文，点行进入、返回键/关闭出）。 */
  @State phoneAboutOn: boolean = false;
  @State phoneAboutVer: string = '';
  @State phoneAboutLicKind: string = '';
  @State phoneAboutLicText: string = '';

  /** 官方欢迎页（loginpage）：欢迎/最近文件列表 + 新建卡片
   *  lang=zh-CN：loginpage 界面语言由 URL 参数决定（utils.inParams.lang；
   *  未传时回退英文——2026-09-05 用户目标「默认中文」） */
  private homeUrl(): string {
    return 'http://localhost/onlyoffice/index.html?v=' + this.pageVer
      + '&lang=zh-CN'
      // 注：zoom=1.2 只在文档页（editorUrl）拼——2026-09-05 用户：主界面不放大，
      // 文档页面才放大（LSO_PAGE_ZOOM 由 ascshim 00_boot 按参数设 html CSS zoom）
      + (this.m7Target.length > 0 ? '&m7open=' + encodeURIComponent(this.m7Target) : '')
      // m7type = 样本的 FileFormat 枚举（30_open.js 3.55b 用它填 recents type——
      // 页面侧不再自持第二份格式表）
      + (this.m7Target.length > 0 ? this.m7SampleType() : '');
  }

  /** m7 样本的 FileFormat 枚举（'&m7type=<hex>'；表查不到兜底 docx） */
  private m7SampleType(): string {
    const dot = this.m7Target.lastIndexOf('.');
    const spec = dot > 0 ? specOf(this.m7Target.substring(dot + 1)) : null;
    return '&m7type=' + (spec !== null ? spec.recentType : 0x41).toString(16);
  }

  /**
   * 编辑器页 URL —— 官方编辑器应用页（apps/<app>/main/index.html，顶层加载；
   * POC 打开链 v12 真机成功渲染的页面/构建组合）。页面经 Gateway init 后接收
   * openDocumentFromBinary 字节（官方 api.js/Gateway/loadBinary 链）。
   * 注：官方面向 API 调用方的桌面壳页（api/documents/index.html + iframe）组合已实测
   * 到 openDocument 前链；引擎模型初始化依赖 B 架构运行时序，本阶段以顶层页打开（后续 M4+ 返回 iframe 结构）。
   */
  private editorUrl(type: string, title: string, sidVal?: number): string {
    // type = 源扩展名或家族代表名——页面与引擎只认家族（doct_bin 签名 DOCY/XLSY/
    // PPTY），.doc/.rtf 等一律按 word 家族打开；查不到（防御）按 word 兜底
    const specU = specOf(type);
    const family = specU !== null ? specU.family : 'word';
    const fileType = specU !== null ? specU.fileType : 'docx';
    const app = editorAppOf(family);
    let url = 'http://localhost/onlyoffice/webapps/apps/' + app + '/main/index.html?v=' + this.pageVer
      + '&fileType=' + fileType + '&isDesktop=false&docType=' + fileType + '&lang=zh-CN&title=' + encodeURIComponent(title)
      // sid=实例唯一化（2026-09-05 修复「关闭文档后再新建显示旧内容」：相同 URL 的
      // 二次导航 ArkWeb 复用引擎实例——页面事件照常（LSO_OPEN_DOCUMENT_OK 收到新模板
      // 字节 len=1086）但旧文档模型残留（真机实锤：新建「未命名的文档」显示 demo-cn 7 页
      // 内容）；sid 强制全新导航。P1b 起 sid=tabId（单调递增，比 Date.now 更保唯一；
      // 语义=tab 标识）。禁止回退为固定 URL（v= 仅防 HTTP 缓存，不防复用）。
      + '&sid=' + (sidVal !== undefined ? sidVal : Date.now())
      // 源文件名交给页面做**媒体预解包**（48_mediaunpack：xlsx 的 xl/media/* 不被 x2t
      // 导出到工作目录，页面在文档注入前自己解出来落盘）。新建文档时 title 是默认名
      // （无 OOXML 后缀）→ 页面侧直接跳过，无额外网络请求。
      + '&src=' + encodeURIComponent(title);
    // M7 验收态：自动打开后追加 m7auto=1（ascshim：模型就绪→序列化→save:bin→x2t 落盘）
    if (this.m7Target.length > 0) {
      url = url + '&m7auto=1'
        // AI 联网验证 key 走页面 URL 传递（2026-09-08：启动参数链路在 1.4 上不可达
        // ——见 smoke.ets m7args 头注；URL 是 Web 侧已知可靠通道）
        + (Smoke.key.length > 0 ? '&m7key=' + encodeURIComponent(Smoke.key) : '')
        // AI 插件自动点击门控（2026-09-11）：默认**不**拼 m7ai → prof-snap 不切 AI tab、
        // 不点 Chatbot（否则聊天窗弹出遮挡常规验收截图）；需验 AI 插件链时显式 m7ai=1
        + (Smoke.ai ? '&m7ai=1' : '')
        // autosave 语义保存（userFlag=0）验收门控：仅显式 m7autosave=1 时拼——
        // 产品路径的保存恒为用户保存（见 30_open.js m7autosave 段）
        + (Smoke.autosave ? '&m7autosave=1' : '')
        // 插入图片验收门控（m7img）：模型就绪后走上传汇合点插入内置小图（见 47_img/30_open）
        + (Smoke.img.length > 0 ? '&m7img=' + Smoke.img : '');
    }
    // 输入焦点抑制（ascshim 29_inputfocus 段）：非 PC 形态关掉 sdkjs「界面事件把焦点
    // 拉回隐藏输入代理」的副作用——它在 ArkWeb 上会拉起系统软键盘（点工具栏即弹）。
    // PC 保留原行为：那边靠它维持物理键盘输入，且不弹软键盘。
    const dtFocus = deviceInfo.deviceType;
    if (dtFocus !== '2in1' && dtFocus !== 'pc') {
      url = url + '&nofocus=1';
    }
    // 用户自导入字体清单（common/userFonts.encodeUrlParam；空清单不拼）。
    // 字体注册表必须在 sdk-all.js 的 checkAllFonts() 之前就位（之后表被删），
    // 页面加载时同步可得的通道只有 URL——故走参数而非桥或异步请求（对应解析见
    // ascshim 20_bridge / 09_fonts 的 lsofonts 段）。
    const uf = encodeUrlParam(this.hostFilesDir);
    if (uf.length > 0) {
      url = url + '&lsofonts=' + encodeURIComponent(uf);
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
    if (cmd === 'font:manage') {
      // 欢迎页侧栏「字体管理」（40_save 注入项 → AscNative.execCommand）：打开弹层，
      // 查看/导入/删除都在里面。增删只落沙箱与清单，生效在**新打开的文档**
      // （URL 参数注册，见 editorUrl）。
      this.openFontManager();
      return 'true';
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
        && !this.closeGuardDefer.awaitingSaveAs && !this.fmtDialogOn) {
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
    if (cmd === 'media:put') {
      // 插入图片链：47_img.js 覆写 AscCommon.UploadImageFiles 后发来（官方 web 形态
      // 此处 POST DocumentServer 上传服务，本壳无服务器 → 宿主落盘）。param 形如
      // '<ext>|<base64>'，返回写入的文件名（页面据此建模型引用 media/<name>）。
      return this.putMedia(ctx, param);
    }
    if (cmd === 'media:unpack') {
      // 文档内嵌媒体预解包（48_mediaunpack.js：xlsx 的 xl/media/* 不被 x2t 导出到
      // 工作目录，由页面在文档注入前解出并落盘）。param 用原名，与 bin 里的引用对齐。
      return this.putMediaNamed(ctx, param);
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

  /** 另存为命令体（per-tab：临时文件带 ctx 后缀——多文档隔离）。
   *  目标后缀/格式对/产物校验与 saveBinRaw 同源查 formats 表：源扩展名直接当产物后缀
   *  是死路——x2t 无 bin→doc/.xls/.ppt/.txt 通路，csv 的 TCD_XLST_BIN2CSV 又缺 switch
   *  case（方向判定失败 → 命令返回 false，用户点「另存为」无任何反应）。 */
  private saveAsBin(ctx: DocTabCtx, param: string): string {
    try {
      const abS = b64ToBuf(param);
      if (abS === null || abS.byteLength === 0) {
        this.arkLog('SAVE_AS_B64_BAD len=' + param.length);
        return 'false';
      }
      const srcExt = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const specA = specOf(srcExt);
      const extA = specA !== null ? specA.saveExt : 'docx';
      const checkA = specA !== null ? specA.check : 'zip';
      const inA = ctx.tabPath('saveas-in.bin');
      const outA = ctx.tabPath('saveas-out.' + extA);
      if (!writeFileBuf(inA, abS)) {
        this.arkLog('SAVE_AS_WRITE_ERR ' + inA);
        return 'false';
      }
      // 同 saveBinRaw：先删产物槽，防 x2t 未写出新产物时读回上一次的旧文件
      try {
        fs.unlinkSync(outA);
      } catch (e) {
        // 不存在=首次另存为的正常情形
      }
      const pwdAs = ctx.state.pwd.length > 0
        ? '<m_sSavePassword>' + ctx.state.pwd + '</m_sSavePassword>' : '';
      const rcA = x2tConvertSync((specA !== null && specA.saveFrom > 0)
        ? x2tXml(inA, outA, specA.saveFrom, specA.saveTo, pwdAs)
        : x2tXml(inA, outA, 0, 0, pwdAs));
      this.arkLog('SAVE_AS_X2T rc=0x' + (rcA >>> 0).toString(16) + ' tab=' + ctx.id);
      if (rcA !== 0) {
        this.arkLog('SAVE_AS_X2T_FAIL');
        return 'false';
      }
      const outBufA = readFileBuf(outA);
      if (outBufA === null) {
        this.arkLog('SAVE_AS_SUBMISS ' + outA);
        return 'false';
      }
      const badA = checkSaveOut(new Uint8Array(outBufA), checkA);
      this.arkLog('SAVE_AS_OUT size=' + outBufA.byteLength + ' check=' + checkA
        + (badA === null ? ' ok' : ' BAD:' + badA));
      if (badA !== null) {
        return 'false';
      }
      // forceExt：系统保存框默认名与后缀按表定（.doc tab 另存 → sample.docx，
      // 不传会拿源扩展名当目标名 → 名实不符）
      this.doSaveAs(ctx, outBufA, extA);
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
   * 打开本地文件（系统文件选择器）：可打开格式由 formats 表派生进 fileSuffixFilters
   * ——选择器按后缀**硬过滤**（非白名单后缀不出现在列表里），故此处选不到不支持格式；
   * 选中后交 handleLocalUri 统一处理（与「打开方式」同一条处理链）。
   */
  private async openLocalFile(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      // 可打开格式由 formats 表派生（新增格式自动进入选择器过滤）；必须单选项
      //（多元素 = 下拉多选项且默认只选中第一项，弹窗只列 .docx——见 formats.pickerFilterOption）
      opts.fileSuffixFilters = pickerFilterOption();
      const uris = await dvp.select(opts);
      if (uris.length === 0) {
        this.arkLog('OPEN_LOCAL_CANCEL');
        return;
      }
      this.handleLocalUri(uris[0]);
    } catch (e) {
      this.arkLog('OPEN_LOCAL_ERR ' + String(e));
    }
  }

  /**
   * 本地文件 uri 统一处理（两个来源共用：系统选择器、「打开方式」want.uri）：
   * 授权 uri 仅临时可读——读入内存即固化（openNewTabEntry 写沙箱，此后与源文件无
   * 关联）；后缀不在 formats 表 → 显式提示（不得静默：从文件管理器交付的文件必须
   * 得到明确回应——picker 硬过滤挡不住这条路，它是用户拿到不支持格式的唯一入口）。
   */
  private handleLocalUri(uri: string): void {
    let label = uri.substring(uri.lastIndexOf('/') + 1);
    try {
      // **先判后缀再读字节**：文件管理器「打开方式」候选含一切文件（skill 声明
      // type:*/*），先 readFileBuf 会把几百 MB 的视频/压缩包整个读进内存才拦
      try {
        label = decodeURIComponent(label);
      } catch (de) {
        // uri 尾段编码异常：按原样判后缀（不值得因此整体失败）
      }
      // 文件名清洗：decodeURIComponent 会把 %2F 还原成 '/'，而 name 直接参与
      // `hostFilesDir + '/' + name` 拼路径——带分隔符的名字可越出工作副本目录
      //（沙箱内自伤：覆盖 recents.json/web_console.txt 等同级文件）。
      // 与 printOutPath 同款清洗；此处就地改，后续 ctx.state.name 即已净化
      label = label.replace(/[\\/]/g, '_');
      let ext = '';
      const dot = label.lastIndexOf('.');
      if (dot > -1) {
        ext = label.substring(dot + 1).toLowerCase();
      }
      if (specOf(ext) === null) {
        // 未支持格式：显式提示（不再静默 return——用户须知道发生了什么）
        this.arkLog('OPEN_LOCAL_EXTBAD label=' + label + ' ext=' + ext);
        this.showFormatNotice('暂不支持该格式：' + label);
        return;
      }
      const ab = readFileBuf(uri);
      if (ab === null) {
        // 读失败（授权过期/文件已删/目录 uri）：同样要出口——本入口无前置过滤，
        // 静默会让用户以为「点了没反应」
        this.arkLog('OPEN_LOCAL_READERR uri=' + uri);
        this.showFormatNotice('无法打开：' + label);
        return;
      }
      this.arkLog('OPEN_LOCAL_OK label=' + label + ' uri=' + uri + ' size=' + ab.byteLength);
      // userUri=真实位置（选择器/文件管理器授权 uri）——保存目标=用户原文件（覆盖式保存）
      this.openNewTabEntry(ab, ext, label, true, false, uri);
    } catch (e) {
      this.arkLog('OPEN_LOCAL_ERR ' + String(e));
      this.showFormatNotice('无法打开：' + label);
    }
  }

  /** 「打开方式」待办 uri 消费（welcome 就绪门槛；幂等——无待办则无操作） */
  private consumeWantUri(): void {
    if (this.pendingWantUri.length === 0) {
      return;
    }
    const u = this.pendingWantUri;
    this.pendingWantUri = '';
    this.arkLog('WANT_URI_CONSUME ' + u);
    this.handleLocalUri(u);
  }

  /** 待办 uri 兜底：welcome 异常（加载失败/卡死）时超时直接消费——用户点了
   *  「打开方式」不能永远无反应（正常轮次 onPageEnd 先到，本定时器空转一次；
   *  重复挂载无害：consumeWantUri 幂等） */
  private armWantUriFallback(): void {
    setTimeout((): void => {
      this.consumeWantUri();
    }, 10000);
  }

  /** open:recent → 沙箱文件 x2t 转换 + 编辑器导航（转换器按输入扩展名自动选择，.bin 输出） */
  private openRecent(param: string): string {
    try {
      const o = JSON.parse(param) as Record<string, Object>;
      const path = String(o['path'] ?? '');
      const name = String(o['name'] ?? '');
      if (path.length === 0) {
        this.arkLog('OPEN_RECENT_NOPATH ' + param);
        return 'false';
      }
      // 文件名以 path 尾部为准（loginpage recents 的 name 字段可能被截断/缺失）
      const base = path.substring(path.lastIndexOf('/') + 1);
      const label = base.length > 0 ? base : name;
      // 源格式以**文件名后缀**为准（recents.type 是展示枚举、非格式判据）；后缀缺失
      // 或不支持 → 显式提示（不得兜底 docx：静默按 docx 打开 = 静默错误）
      let ext = '';
      const i = label.lastIndexOf('.');
      if (i > 0) {
        ext = label.substring(i + 1).toLowerCase();
      }
      if (ext.length === 0 || specOf(ext) === null) {
        this.arkLog('OPEN_RECENT_EXTBAD label=' + label + ' ext=' + ext);
        this.showFormatNotice('暂不支持该格式：' + label);
        return 'false';
      }
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
  private async doSaveAs(ctx: DocTabCtx, outBuf: ArrayBuffer, forceExt?: string): Promise<void> {
    try {
      const aCtx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(aCtx);
      const opts = new picker.DocumentSaveOptions();
      // 目标后缀：forceExt 优先（不能原地保存的格式：.doc → .docx），否则同格式
      const targetExt = (forceExt !== undefined && forceExt.length > 0) ? forceExt : ctx.state.ext;
      // 默认名：已保存文档=当前名**换目标后缀**（.doc → .docx）——原名直接带上会把
      // docx 字节写成 .doc 名；新建=语言包中文未命名（defaultDocName）
      let defName = '';
      if (ctx.state.name.length > 0) {
        const dn = ctx.state.name.lastIndexOf('.');
        defName = (dn > 0 ? ctx.state.name.substring(0, dn) : ctx.state.name) + '.' + targetExt;
      } else {
        defName = this.defaultDocName(targetExt);
      }
      opts.newFileNames = [defName];
      // 后缀限定（DocumentSaveOptions.fileSuffixChoices，**不是** SelectOptions 的
      // fileSuffixFilters——字段名不同）：防用户手改扩展名产生「名实不符」文件
      opts.fileSuffixChoices = ['.' + targetExt];
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
          if (specOf(e2) !== null) {
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
      // 编辑器内顶部标题栏同步：官方标题只在打开链注入一次（ascshim 的
      // document.title → onDocInfo → Header.setDocumentCaption），另存为改名后
      // 官方 UI 仍显示旧名——走同一个官方入口刷新（该函数内部同时维护
      // caption/扩展名/只读后缀三个状态，直接改 DOM 会与其状态脱节）。
      if (base.length > 0) {
        ctx.js('(function(){try{'
          + 'var ns=window.SSE||window.DE||window.PE;'
          + 'var m=ns&&ns.controllers&&ns.controllers.Main;'
          + 'var a=(m&&typeof m.getApplication==="function")?m.getApplication():null;'
          + 'var vp=(a&&typeof a.getController==="function")?a.getController("Viewport"):null;'
          + 'var hd=(vp&&typeof vp.getView==="function")?vp.getView("Common.Views.Header"):null;'
          + 'if(hd&&typeof hd.setDocumentCaption==="function"){hd.setDocumentCaption('
          + JSON.stringify(base) + ');}'
          + 'console.error("LSO_TITLE_SET");'
          + '}catch(x){console.error("LSO_TITLE_ERR "+x);}})()', 'titleSet');
      }
      if (ctx.state.name.length > 0) {
        const specA = specOf(ctx.state.ext);
        const typeNum = specA !== null ? specA.recentType : RECENT_TYPE_DOCX;
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
   * 插入图片落盘（47_img.js 覆写 AscCommon.UploadImageFiles 后的宿主端）。
   * param = '<ext>|<base64>'；字节写进**本 tab** 的 media/ 目录——与打开链 x2t 解包
   * 同处、保存链也从这里取图（DocxSerializer 按 bin 同级 media/ 取图），三条链共用
   * 一个目录是"插入的图保存后还在"的前提。返回文件名；失败返回 '""'（页面按上传
   * 错误提示，不静默）。
   * 命名 insert<N>.<ext>：与引擎自解包的 image<N>.* 区分，编号取目录现状（避免覆盖
   * 已插入的图——同名会让两张图互相顶替）。
   */
  private putMedia(ctx: DocTabCtx, param: string): string {
    try {
      const bar = param.indexOf('|');
      if (bar <= 0) {
        this.arkLog('IMG_PUT_BADPARAM');
        return '""';
      }
      const ext = param.substring(0, bar).replace(/[^a-z0-9]/g, '');
      const buf = b64ToBuf(param.substring(bar + 1));
      if (ext.length === 0 || buf.byteLength === 0) {
        this.arkLog('IMG_PUT_EMPTY ext=' + ext + ' len=' + buf.byteLength);
        return '""';
      }
      const dir = ctx.tabDir() + '/media';
      try {
        fs.mkdirSync(dir);
      } catch (e) {
        // 目录已存在
      }
      let n = 1;
      try {
        for (const nm of fs.listFileSync(dir)) {
          const m = nm.match(/^insert([0-9]+)\./);
          if (m !== null) {
            const v = parseInt(m[1], 10);
            if (v >= n) {
              n = v + 1;
            }
          }
        }
      } catch (e) {
        // 目录为空/不可列（首次插入即此）
      }
      const name = 'insert' + n + '.' + ext;
      if (!writeFileBuf(dir + '/' + name, buf)) {
        this.arkLog('IMG_PUT_WRITE_ERR ' + dir + '/' + name);
        return '""';
      }
      this.arkLog('IMG_PUT ok tab=' + ctx.id + ' ' + name + ' bytes=' + buf.byteLength);
      return name;
    } catch (e) {
      this.arkLog('IMG_PUT_ERR ' + String(e));
      return '""';
    }
  }

  /**
   * 文档内嵌媒体按**原名**落盘（48_mediaunpack.js 预解包后发来；与 putMedia 的区别是
   * 名字必须保持 zip 里的原始文件名——bin 里的图片引用就是这个名字，改名等于对不上）。
   * 形态校验从严（单段文件名 + 图片后缀）：名字来自文档 zip，与用户输入同等不可信。
   */
  private putMediaNamed(ctx: DocTabCtx, param: string): string {
    try {
      const bar = param.indexOf('|');
      if (bar <= 0) {
        return '""';
      }
      const name = param.substring(0, bar);
      if (!/^[A-Za-z0-9_]+\.(png|jpg|jpeg|gif|bmp|webp|tif|tiff|svg|emf|wmf)$/.test(name)) {
        this.arkLog('MEDIA_UNPACK_BADNAME ' + name);
        return '""';
      }
      const buf = b64ToBuf(param.substring(bar + 1));
      if (buf.byteLength === 0) {
        return '""';
      }
      const dir = ctx.tabDir() + '/media';
      try {
        fs.mkdirSync(dir);
      } catch (e) {
        // 目录已存在
      }
      if (!writeFileBuf(dir + '/' + name, buf)) {
        this.arkLog('MEDIA_UNPACK_WRITE_ERR ' + name);
        return '""';
      }
      this.arkLog('MEDIA_UNPACK ok tab=' + ctx.id + ' ' + name + ' bytes=' + buf.byteLength);
      return name;
    } catch (e) {
      this.arkLog('MEDIA_UNPACK_ERR ' + String(e));
      return '""';
    }
  }

  /**
   * 插入图片的宿主文件选择器（DocTabHost.onShowFileSelector → ctx.onPickFile）。
   * ArkWeb 不接管 `<input type=file>` 的 click 时页面侧**静默无反应**——接收管后由
   * 宿主弹系统 picker，把选中文件先拷进本 tab 工作目录再回填路径：picker 授权的 uri
   * 页面侧读不到（FileReader 需要沙箱内可读路径），拷入后也与源文件解耦（源文件被
   * 删/移动不影响已插入的图）。
   */
  private pickFileForWeb(ctx: DocTabCtx, result: FileSelectorResult, accept: string[]): void {
    this.doPickFile(ctx, result, accept);
  }

  private async doPickFile(ctx: DocTabCtx, result: FileSelectorResult,
    accept: string[]): Promise<void> {
    try {
      const aCtx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(aCtx);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = imageSuffixesFrom(accept);
      const uris = await dvp.select(opts);
      if (uris.length === 0) {
        this.arkLog('PICKFILE_CANCEL tab=' + ctx.id + ' accept=' + accept.join(','));
        result.handleFileList([]);
        return;
      }
      const ab = readFileBuf(uris[0]);
      if (ab === null) {
        this.arkLog('PICKFILE_READERR ' + uris[0]);
        result.handleFileList([]);
        return;
      }
      let base = uris[0].substring(uris[0].lastIndexOf('/') + 1);
      try {
        base = decodeURIComponent(base);
      } catch (de) {
        // 尾段编码异常：按原样用（与 handleLocalUri 同策略）
      }
      base = base.replace(/[\\/]/g, '_');
      const dst = ctx.tabDir() + '/' + base;
      if (!writeFileBuf(dst, ab)) {
        this.arkLog('PICKFILE_WRITE_ERR ' + dst);
        result.handleFileList([]);
        return;
      }
      this.arkLog('PICKFILE_OK tab=' + ctx.id + ' ' + base + ' bytes=' + ab.byteLength);
      result.handleFileList([dst]);
    } catch (e) {
      this.arkLog('PICKFILE_ERR ' + String(e));
      try {
        result.handleFileList([]);
      } catch (e2) {
        // 回填失败（页面已销毁等）——页面按取消处理
      }
    }
  }

  /** 打开字体管理弹层。入口只在欢迎页侧栏，但弹层是页面级状态、与 tab 无关
   *  （文档页被触发也照常显示）。 */
  private openFontManager(): void {
    this.refreshFontRows();
    this.fontMgrOn = true;
    this.arkLog('FONT_MGR_OPEN n=' + this.fontMgrRows.length);
  }

  private closeFontManager(): void {
    this.fontMgrOn = false;
    this.arkLog('FONT_MGR_CLOSE');
  }

  /** 重建列表（打开弹层时、导入后、删除后各调一次）。 */
  private refreshFontRows(): void {
    this.fontMgrRows = listFontItems(this.hostFilesDir);
  }

  /** 手机原生主页「关于」弹层：版本号取自包信息（与 57_about 发的 app:version
   *  同源——AppScope versionName）。 */
  private phoneAboutOpen(): void {
    if (this.phoneAboutVer.length === 0) {
      try {
        const bi = bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        this.phoneAboutVer = bi.versionName;
      } catch (e) {
        this.arkLog('PHONE_ABOUT_VER_ERR ' + String(e));
      }
    }
    this.phoneAboutLicKind = '';
    this.phoneAboutLicText = '';
    this.phoneAboutOn = true;
  }

  /** 查看 LICENSE / NOTICE 全文（随包 rawfile/onlyoffice/licenses/，与 Web 版
   *  About 许可行同一事实源——55_lic.js 弹层语义的原生版）。 */
  private phoneAboutShowLic(kind: string): void {
    try {
      const raw = this.resourceManager!.getRawFileContentSync(
        'onlyoffice/licenses/' + kind + '.txt') as Uint8Array;
      this.phoneAboutLicText = u8ToStr(raw);
      this.phoneAboutLicKind = kind;
    } catch (e) {
      this.arkLog('PHONE_ABOUT_LIC_ERR ' + kind + ' ' + String(e));
    }
  }

  /**
   * 删除前的确认：**系统原生 AlertDialog**，不是自绘列表内确认条。
   * 删除是不可逆动作，这里正好只要两个键（取消/删除），落在 AlertDialog 的能力内——
   * 项目里"原生弹层别用"的记录只针对 CustomDialog 的**自定义按钮**（真机点击失效）
   * 和 AlertDialog 的键数上限（三键场景才不够），不等于原生弹窗整体不可用。
   */
  private fontMgrDeleteConfirm(id: string, family: string): void {
    AlertDialog.show({
      title: '删除字体',
      message: '将删除「' + family + '」。\n用该字体排版的文档再打开时会回退为宋体。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
          this.arkLog('FONT_MGR_DEL_CANCEL id=' + id);
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C0392B',
        action: () => {
          this.fontMgrDelete(id);
        }
      }
    });
  }

  /** 确认后的删除：清单与磁盘由 removeFont 收敛，结果 toast 需要交代生效时机
   *  （字体表在页面加载时经 URL 参数注册，故只影响新打开的文档）。 */
  private fontMgrDelete(id: string): void {
    const r = removeFont(this.hostFilesDir, id);
    this.arkLog('FONT_MGR_DEL id=' + id + ' ok=' + r.ok + ' ' + r.msg);
    this.refreshFontRows();
    promptAction.showToast({
      message: r.ok ? (r.msg + '，新打开的文档将不再包含该字体') : r.msg,
      duration: 3000
    });
  }

  /**
   * 弹层内的导入，两段分明：**选择**（系统 picker 在途）与**导入**（读+落盘）。
   * 拆开是为了按钮文案如实——合成一段时按钮只能一路显示「导入中」，而那段里
   * 用户其实还停在系统选择器里，什么都没开始导。busy 全程禁点（选择器在途重复
   * 点会叠起多个）。
   */
  private async fontMgrImport(): Promise<void> {
    if (this.fontMgrBusy) {
      return;
    }
    const aCtx = getContext(this) as common.UIAbilityContext;
    const rm = this.resourceManager;
    if (rm === undefined) {
      promptAction.showToast({ message: '导入失败：资源未就绪', duration: 3000 });
      return;
    }
    this.fontMgrBusy = true;
    try {
      this.fontMgrStage = 'pick';
      this.arkLog('FONT_MGR_STAGE pick');
      const uri = await pickFontFile(aCtx);
      if (uri.length === 0) {
        this.arkLog('LSO_UFONT_IMPORT ok=false msg=已取消导入');
        promptAction.showToast({ message: '已取消导入', duration: 3000 });
        return;
      }
      this.fontMgrStage = 'import';
      this.arkLog('FONT_MGR_STAGE import');
      // 导入整段走异步 IO + native 哈希（见 userFonts / bytes），调用线程不阻塞：
      // 状态照常渲染、界面照常响应，不需要「让出一帧」之类的补丁。
      const r = await importFontFile(this.hostFilesDir, rm, uri);
      this.arkLog('LSO_UFONT_IMPORT ok=' + r.ok + ' msg=' + r.msg);
      promptAction.showToast({ message: r.msg, duration: 3000 });
    } finally {
      this.fontMgrStage = '';
      this.fontMgrBusy = false;
      this.refreshFontRows();
    }
  }

  /** 导入按钮文案（跟着阶段走，见 fontMgrImport） */
  private fontMgrBtnText(): string {
    if (this.fontMgrStage === 'pick') {
      return '选择字体文件…';
    }
    if (this.fontMgrStage === 'import') {
      return '导入中…';
    }
    return '导入字体';
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

  /**
   * per-tab 工作目录启动清扫（`t<id>`，DocTabCtx.tabDir）。
   * 与 sweepPrintFiles 同款兜底：进程崩溃/强杀时 tab 未走正常关闭路径 → 目录连同
   * 其中的 x2t 解包媒体（media/）一起残留。启动时刻无活跃 tab，可整体清。
   * 只认 `t<数字>` 形态（避免误伤其它 t 开头的文件）。
   */
  private sweepTabDirs(): void {
    try {
      const names = fs.listFileSync(this.hostFilesDir);
      for (const n of names) {
        if (!/^t\d+$/.test(n)) {
          continue;
        }
        const dir = this.hostFilesDir + '/' + n;
        try {
          const inner = fs.listFileSync(dir);
          for (const f of inner) {
            try {
              fs.unlinkSync(dir + '/' + f);
            } catch (e) {
              // 占用中/已删/子目录——忽略（残留由下次启动再试）
            }
          }
          fs.rmdirSync(dir);
        } catch (e) {
          // 非目录/非空——忽略
        }
      }
    } catch (e) {
      // 目录不可读——非致命
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
      // 目标后缀取自 formats 表：不能原地保存的格式（doc/xls/ppt/txt）saveExt 指向
      // 家族代表名（.doc → .docx）——x2t 无 bin→doc 通路（见 formats.ets 表头注释）
      const srcExt = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const srcSpec = specOf(srcExt);
      const extU = srcSpec !== null ? srcSpec.saveExt : 'docx';
      const outCheck = srcSpec !== null ? srcSpec.check : 'zip';
      const inP = ctx.tabPath('in.bin');
      const outP = ctx.tabPath('save.' + extU);
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('SAVE_BIN_WRITE_ERR ' + inP);
        return 'false';
      }
      // 先删产物槽：x2t 返 0 却没写出新产物时（罕见），下方读回的是**上一次保存**
      // 的旧文件——会通过校验并被当成新内容写盘（静默落旧数据）
      try {
        fs.unlinkSync(outP);
      } catch (e) {
        // 不存在=首次保存的正常情形
      }
      // x2t doct_bin2docx（checker 以文件头 DOCY 内容识别，.bin 后缀无碍；POC 保存链实证）。
      // saveFrom ≠ 0 的格式要显式给出格式对（方向表与转换器 switch 不一致，见 formats.ets）
      // 密文文档：保存时同密码重加密（x2t 的 m_sSavePassword，见 lib/common.h
      // dir2zipMscrypt——有该参数则产物为密文，否则明文落盘）
      const pwdSave = ctx.state.pwd.length > 0
        ? '<m_sSavePassword>' + ctx.state.pwd + '</m_sSavePassword>' : '';
      const rc = x2tConvertSync((srcSpec !== null && srcSpec.saveFrom > 0)
        ? x2tXml(inP, outP, srcSpec.saveFrom, srcSpec.saveTo, pwdSave)
        : x2tXml(inP, outP, 0, 0, pwdSave));
      this.arkLog('SAVE_BIN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        return 'false';
      }
      // 产物校验按表分派（zip/rtf/size）——原硬编码 ZIP 头会把 rtf/csv 误判为坏产物
      const outBuf = readFileBuf(outP);
      if (outBuf === null) {
        this.arkLog('SAVE_BIN_SUBMISS ' + outP);
        return 'false';
      }
      const bad = checkSaveOut(new Uint8Array(outBuf), outCheck);
      this.arkLog('SAVE_BIN_OUT size=' + outBuf.byteLength + ' check=' + outCheck
        + (bad === null ? ' ok' : ' BAD:' + bad));
      if (bad !== null) {
        return 'false';
      }
      // 新文件首次保存 = 另存为（官方桌面语义：无文件身份 → 弹系统保存对话框选位置；
      // 2026-09-05 用户「点保存应弹保存位置，却直接保存了」）。x2t 产物 outBuf 交接给
      // doSaveAs（async：dvp.save → uri 落盘 + 沙箱同步 + recents + 复位 isNewUnsaved）。
      // 对话框异步期间先回 'true'（保存受理）；取消=未保存（isNewUnsaved 仍 true，
      // 下次保存再弹）。
      // 不能原地保存的格式（doc/xls/ppt/txt）：产物已生成但不落盘——先弹提示，
      // 确认后走 doSaveAs（强制 saveExt）。禁止回写：savePath 指向源 .doc，覆盖
      // 会把 docx 字节写进 .doc 文件（名实不符）。新建（saveTarget='none'）本就走
      // 另存为，不需此提示。
      if (userSaved && ctx.state.saveTarget !== 'none' && isLossySave(ctx.state.ext)) {
        // csv「丢格式」提示：csv 只承载纯文本，编辑器里新加的合并单元格/颜色/列宽
        // 写不回去（官方 Excel 保存 csv 亦提示）。与「不能原地保存」不同——确认后
        // 走**原地回写**（目标格式不变），故单列提示模式；不确认则本次不落盘。
        this.fmtDialogCtx = ctx;
        this.fmtDialogOut = outBuf;
        this.fmtDialogLossy = true;
        this.fmtDialogText = '「.' + ctx.state.ext + '」只保存文本内容，'
          + '合并单元格/颜色/列宽等格式将丢失。';
        this.fmtDialogOn = true;
        // 守卫「保存」在途：复用 awaitingSaveAs 语义（本段不消费 defer，确认由
        // commitSavedLocal 收尾 / 取消走 fmtDialogAction 的 clearCloseGuard）
        if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx) {
          this.closeGuardDefer.awaitingSaveAs = true;
        }
        this.arkLog('FMT_DIALOG_ON ext=' + ctx.state.ext + ' lossy tab=' + ctx.id);
        return 'true';
      }
      if (userSaved && ctx.state.saveTarget !== 'none' && needsSaveAsPrompt(ctx.state.ext)) {
        this.fmtDialogCtx = ctx;
        this.fmtDialogOut = outBuf;
        this.fmtDialogText = '「.' + ctx.state.ext + '」格式不支持保存，将以「.'
          + extU + '」格式另存。';
        this.fmtDialogOn = true;
        // 守卫「保存」在途：复用 awaitingSaveAs 语义（本段不消费 defer，成功由
        // doSaveAs 尾消费 / 取消走 fmtDialogAction 的 clearCloseGuard）
        if (this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx) {
          this.closeGuardDefer.awaitingSaveAs = true;
        }
        this.arkLog('FMT_DIALOG_ON ext=' + ctx.state.ext + ' to=' + extU + ' tab=' + ctx.id);
        // 对话框异步期间先回 'true'（保存受理）——与 doSaveAs 同一模式
        return 'true';
      }
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
        return this.commitSavedLocal(ctx, outBuf, userSaved);
      }
      ctx.state.saveAborted = false;
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_BIN_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 保存落盘（原地回写 + 引擎工作副本同步 + 引擎水位复位 + recents 补录）。
   * saveBinRaw 的常规路径与「格式提示确认后」路径（csv 丢格式提示）共用——提示框的
   * 中断点在 x2t 产物之后，用户确认后无需重新序列化，落盘与收尾即可。
   */
  private commitSavedLocal(ctx: DocTabCtx, outBuf: ArrayBuffer, userSaved: boolean): string {
    try {
      // 「不能原地保存」的格式永不回写源文件——**与 userSaved 无关**：autosave
      // 走同一约束，否则 .doc 会被 docx 字节原地覆盖（名实不符）。用户保存路径
      // 已在上方提示分支转另存为；autosave 此处仅同步沙箱工作副本（静默）
      let uriFailed = false;
      if (!needsSaveAsPrompt(ctx.state.ext)
        && ctx.state.saveTarget === 'uri' && ctx.state.savePath.length > 0) {
        // 已另存为：覆写真实位置（用户数据=savePath uri）
        const okUri = writeFileBuf(ctx.state.savePath, outBuf);
        this.arkLog('SAVE_BIN_URI ok=' + okUri + ' uri=' + ctx.state.savePath + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
        if (!okUri) {
          // 原位置不可写（授权过期/只读交付 uri）：**不中断**——继续写沙箱工作副本
          // 保住本次编辑，末尾显式告知另存出口（静默失败=用户以为已保存）
          this.arkLog('SAVE_BIN_URI_ERR ' + ctx.state.savePath);
          uriFailed = true;
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
      // 引擎「已保存」水位复位：本保存链是 ArkTS 侧序列化（不经引擎 asc_Save），引擎
      // History 的 SavedIndex 停在旧值 → Have_Changes() 恒真 → 关闭守卫把已保存的文档
      // 再判一次「未保存」（重复弹框；覆写幂等故不丢数据，但每存必弹一次）。
      // 对齐官方 _onSaveCallbackInner 的收尾：Reset_SavedIndex(true) 把已保存点推进到
      // 当前（Local 形态语义：Index == UserSavedIndex 即无变更），CheckChangedDocument
      // 同步 isDocumentModified / CanSave 两个标志位。
      ctx.js('(function(){try{'
        + 'var h=window.AscCommon&&window.AscCommon.History;'
        + 'if(h&&typeof h.Reset_SavedIndex==="function"){h.Reset_SavedIndex(true);}'
        + 'var ns=window.SSE||window.DE||window.PE;'
        + 'var m=ns&&ns.controllers&&ns.controllers.Main;'
        + 'var e=m&&m.api;'
        + 'if(e&&typeof e.CheckChangedDocument==="function"){e.CheckChangedDocument();}'
        + 'console.error("LSO_SAVED_INDEX_RESET");'
        + '}catch(x){console.error("LSO_SAVED_INDEX_ERR "+x);}})()', 'saveReset');
      if (uriFailed) {
        this.showFormatNotice('原文件不可写（授权已过期或只读），内容已留在应用内；'
          + '请用「文件 → 另存为」保存到其他位置');
      }
      // 保存成功 = 文件身份成立（官方桌面语义：保存后的文件进「最近使用」；
      // 新建在打开链已禁 recents（openNewTabEntry addRecent=false）——用户保存即补录；
      // appendRecent 同名去旧置顶，已打开文件的保存同样刷新置顶。
      // 仅用户保存补录（自动保存/autosave 不打扰列表——2026-09-05 用户实测后修正）。
      if (userSaved) {
        const specR = specOf(ctx.state.ext);
        const saveType = specR !== null ? specR.recentType : RECENT_TYPE_DOCX;
        // recents.path：真实位置优先（uri），否则沙箱（打开链/兼容）
        const recentPath = ctx.state.saveTarget === 'uri' ? ctx.state.savePath : srcP;
        if (appendRecent(this.hostFilesDir, ctx.state.name, recentPath, saveType)) {
          this.arkLog('RECENTS_APPEND_SAVE name=' + ctx.state.name);
        }
      }
      // 保存真正落盘（URI/沙箱覆写完成）→ 清「保存中止」标记（2026-09-09 review：
      // 仅守卫消费路径清不够——另存为取消后用户**手动** Ctrl+S 保存成功的场景，
      // saveAborted 残留会导致下次关闭误弹框；落盘终点统一复位，幂等）
      ctx.state.saveAborted = false;
      // 完成提示只给用户主动保存：官方桌面语义保存完成是静默的（协同链的反馈=
      // 「正在保存」mask），而本地链是同步桥——官方 mask 建立即销毁（同一帧内），
      // 用户全程看不到任何反馈。三类不弹：autosave（官方语义，不打扰）；关闭守卫
      // 触发的保存（tab 即将关闭，toast 会残留到下一个界面造成误导）；uri 写失败
      // （上方已有「请另存为」告知，再弹「已保存」自相矛盾）。
      if (userSaved && !uriFailed
        && !(this.closeGuardDefer !== null && this.closeGuardDefer.ctx === ctx)) {
        promptAction.showToast({ message: '已保存', duration: 3000 });
      }
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_BIN_LOCAL_ERR ' + String(e));
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
      // 插入图片：页面 <input type=file> 的宿主端（onShowFileSelector → 系统 picker）
      ctx.onPickFile = ((r: FileSelectorResult, a: string[]) => this.pickFileForWeb(ctx, r, a));
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
      // 密文文档（密码保护）：x2t 探测到 CFB 密文后走解密分支，未给密码/密码错返回
      // 可恢复错误码（见 x2t.ets 常量）——弹框收取密码后带 <m_sPassword> 重转同一对
      // 临时文件（inP 已落盘，不必重读源文件）。m7pwd 门控 = 验收态直接给首轮密码，
      // 产品路径恒为空串（走弹框）。openBinTo ≠ 0 的格式要显式给出格式对（方向表与
      // 转换器 switch 不一致，见 formats.ets）。
      const specOpen = specOf(extU);
      let failed = false;
      const attempt = (pwd: string): void => {
        const pwdExtra = pwd.length > 0 ? '<m_sPassword>' + pwd + '</m_sPassword>' : '';
        const rc = x2tConvertSync((specOpen !== null && specOpen.openBinTo > 0)
          ? x2tXml(inP, outP, specOpen.recentType, specOpen.openBinTo, specOpen.openExtra + pwdExtra)
          : x2tXml(inP, outP, 0, 0, pwdExtra));
        this.arkLog('OPEN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ') tab=' + ctx.id);
        if (rc === 0) {
          this.finishOpenTab(ctx, outP, extU, name, addRecent, newDoc, userUri, pwd);
          return;
        }
        const rcU = rc >>> 0;
        if (rcU === X2T_RC_NEED_PASSWORD || rcU === X2T_RC_BAD_PASSWORD) {
          this.showPwdDialog(rcU === X2T_RC_BAD_PASSWORD, (p: string | null) => {
            if (p === null) {
              this.arkLog('OPEN_PWD_CANCEL tab=' + ctx.id);
              return;
            }
            attempt(p);
          });
          return;
        }
        failed = true;
        this.arkLog('OPEN_X2T_FAIL ext=' + extU + ' rc=0x' + rcU.toString(16));
        if (rcU === X2T_RC_DRM_UNSUPPORTED) {
          this.showFormatNotice('该文档使用了暂不支持的加密方式，无法打开。');
        }
      };
      attempt(Smoke.pwd);
      // 'true' = 已受理（转换成功或密码框在途；失败态在 failed 上）
      return failed ? 'false' : 'true';
    } catch (e) {
      this.arkLog('OPEN_CONVERT_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 打开链收尾（转换成功后）：读 doct_bin 字节 → per-tab 身份赋值 → 追加 tab 并聚焦。
   * 与 openNewTabEntry 拆开的原因：密文文档的转换可能因密码交互**异步**重试——收尾
   * 逻辑必须能由重试回调触发，不能只活在 openNewTabEntry 的同步栈内。
   */
  private finishOpenTab(ctx: DocTabCtx, outP: string, extU: string, name: string,
    addRecent: boolean, newDoc: boolean, userUri: string | undefined, pwd: string): void {
    const buf = readFileBuf(outP);
    if (buf === null) {
      this.arkLog('OPEN_BIN_MISS ' + outP);
      return;
    }
      // per-tab 身份赋值（原保存链单例字段→ctx.state）
      // 密文文档密码：本轮转换成功即证明该密码可解此文档（普通文档恒为空串）——
      // 记进 tab 状态供保存链复用（保存时下发 m_sSavePassword，否则产物落成明文）
      ctx.state.pwd = pwd;
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
          const specN = specOf(extU);
          const typeNum = specN !== null ? specN.recentType : RECENT_TYPE_DOCX;
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
    // URL 必须指向**本 tab 的工作目录**（t<id>/）：临时产物由 openNewTabEntry 写在
    // ctx.tabPath 下，按旧的 filesDir/<name> 取会命中上一轮同名残留——文件存在所以
    // 不报错，页面静默装载陈旧内容（图不渲染、保存回写旧模型）。sz 校验是同一问题
    // 的第二道闸：内容长度与本轮产物不符即报错，不再静默。
    let binSz = 0;
    try {
      binSz = fs.statSync(docC.tabPath('open-in.bin')).size;
    } catch (e) {
      this.arkLog('LSO_BIN_STAT_ERR ' + String(e));
    }
    const js = '(function(){'
      + 'try{var x=new XMLHttpRequest();'
      + 'x.open("GET","http://localhost/userfile/t' + docC.id + '/open-in.bin?v="+Date.now(),true);'
      + 'x.responseType="arraybuffer";'
      + 'x.onload=function(){try{var ab=x.response;'
      + 'if(!ab||!ab.byteLength){console.error("LSO_XHR_EMPTY st="+x.status);return;}'
      + 'if(' + binSz + '&&ab.byteLength!==' + binSz + '){'
      + 'console.error("LSO_OPEN_STALE got="+ab.byteLength+" want=' + binSz + '");return;}'
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
      // 焦点链路取证探针（纯观测、不触发动作，与插件链验收无关）：排查「点工具栏 /
      // 切 tab 后系统软键盘被唤起」类问题看 LSO_FOCUS 前缀判据（见 focus-probe.js）。
      const fprobe = Smoke.readScript(this.resourceManager, 'focus-probe.js');
      if (fprobe === null) {
        this.arkLog('SMOKE_FOCUSPROBE_MISSING');
      } else {
        const c3 = docC;
        setTimeout(() => {
          if (!closedTab()) {
            c3.js(fprobe, '');
          }
        }, 8000);
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
    this.sweepTabDirs();
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
    // 「打开方式」（文件管理器/其他应用交付文档）：热启动经 handler 送达、冷启动取
    // 启动 uri（take=只消费一次，避免重复打开）。两条路都先排队，welcome 就绪后经
    // consumeWantUri 进打开链——与 m7 直达同门槛，避开 welcome 加载竞争。
    setWantUriHandler((u: string): void => {
      this.pendingWantUri = u;
      if (this.homeReady) {
        this.consumeWantUri();
      } else {
        // 热启动与冷启动对称兜底：welcome 卡死时同样不能静默吞掉用户操作
        this.armWantUriFallback();
      }
    });
    const launchWantUri = takeLaunchUri();
    if (launchWantUri !== null && launchWantUri.length > 0) {
      this.pendingWantUri = launchWantUri;
      this.armWantUriFallback();
    }
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
        // 与 doc 实例同款注入（欢迎页的上传入口若有 <input type=file> 同样接管）
        homeCtx.onPickFile = ((r: FileSelectorResult, a: string[]) =>
          this.pickFileForWeb(homeCtx, r, a));
        // 手机原生主页入口（buildHomePhone 仅 phone 的 home tab 渲染；Web 欢迎页
        // 形态不触发）。全部复用现有链：新建/打开/字体管理与 Web 入口同一落点。
        homeCtx.onNewFile = ((ext: string) => {
          this.openNewFile(ext);
        });
        homeCtx.onOpenLocal = (() => {
          this.openLocalFile();
        });
        homeCtx.onFontMgr = (() => {
          this.openFontManager();
        });
        homeCtx.onAbout = (() => {
          this.phoneAboutOpen();
        });
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
    // 清单 = formats 表派生（每种可打开格式一个 sample.<ext>）+ 专用样本——新增格式
    // 自动带上样本（原硬编码四文件清单在扩格式后会静默漏拷：m7open 走沙箱路径读不到）
    const names: string[] = ['m7-open-test.docx', 'sample-img.docx', 'sample-img.pptx',
      'sample-img.xlsx'];
    for (const suf of pickerSuffixes()) {
      names.push('sample' + suf);
    }
    for (const name of names) {
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
    // M7 诊断直达：welcome（首页）完成加载后触发样本打开（避开加载竞争；仅 home）。
    // 「打开方式」待办 uri 同点消费（同一门槛：welcome 就绪）
    if (ctx.kind === 'home' && cu.indexOf('/main/index.html') < 0) {
      this.homeReady = true;
      this.consumeWantUri();
      if (this.m7DirectQueued) {
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
    if (this.guardBusy || this.closeGuardDefer !== null || this.fmtDialogOn) {
      // 查询/弹框/保存在途（含格式提示框）：不叠新询问（弹框模态应在 UI 层挡住；
      // 防御路径=日志留证）。fmtDialogOn 必须挡：提示框在途放行关闭会留「幽灵另存」
      // ——fmtDialogCtx 指向已移除实例，用户点「继续」照样弹系统框并落盘
      this.arkLog('CLOSE_GUARD_BUSY tab=' + ctx.id);
      return;
    }
    this.guardBusy = true;
    try {
      // 判据 = canSave || isDocumentModified || Have_Changes（2026-09-12 修订）：
      // 引擎真正的「有未保存变更」判据是 AscCommon.History.Have_Changes()——Local 形态
      // 即 `Index != SavedIndex`（编辑推进 Index，官方保存收尾 Reset_SavedIndex 复位；
      // 见 sdkjs word/Editor/History.js 与 word/Local/api.js）。
      // 此前用 asc_getCanUndo 兜底，是因为 canSave/isDocumentModified 在本链时序下不
      // 刷新（2026-09-10 实测编辑后 cs=0 im=0 uu=1，而保存产物含编辑内容）；但 canUndo
      // 说的是「已保存点之前仍可撤销」——保存不清栈 → 每存必弹一次未保存框（保存幂等
      // 不丢数据，纯体验问题）。现由保存链成功收尾复位水位（saveBinRaw 的
      // Reset_SavedIndex），判据改用 Have_Changes；uu 降为打点。
      // isDocumentModified()=原型方法三引擎均有（word/slide 为 isDocumentModify 属性；
      // cell 另有 asc_ 前缀版）。返回管道串 vcs|im|uu|hc。
      const query = '(function(){try{'
        + 'var ns=window.SSE||window.DE||window.PE;'
        + 'var m=ns&&ns.controllers&&ns.controllers.Main;'
        + 'var e=m&&m.api;'
        + 'var cs="na",im="na",uu="nu",hc="nh";'
        + 'try{cs=(e&&typeof e.asc_isDocumentCanSave==="function")?(e.asc_isDocumentCanSave()?"1":"0"):"na";}catch(x){cs="x";}'
        + 'try{im=(e&&typeof e.isDocumentModified==="function")?(e.isDocumentModified()?"1":"0"):"na";}catch(x){im="x";}'
        + 'try{uu=(e&&typeof e.asc_getCanUndo==="function")?(e.asc_getCanUndo()?"1":"0"):"nu";}catch(x){uu="x";}'
        + 'try{hc=(window.AscCommon&&window.AscCommon.History&&typeof window.AscCommon.History.Have_Changes==="function")?(window.AscCommon.History.Have_Changes()?"1":"0"):"nh";}catch(x){hc="x";}'
        + 'return "v"+cs+"|"+im+"|"+uu+"|"+hc;'
        + '}catch(x){return "vj|j|j|j";}})()';
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
        // 得 "vcs|im|uu|hc" 拼接串再拆；**v = cs || im || hc**（hc 见上：引擎 Local 形态
        // 的未保存判据）。任一项查询不可用时按 '0' 处理——只有明确的 '1' 才拦。
        let v: string = String(res);
        let diag: string = 'na';
        try {
          const pv = String(JSON.parse(String(res)) as string).trim();
          const parts = pv.split('|');
          const cs = parts[0].replace(/^v/, '');
          const im = parts[1] ?? '?';
          const uu = parts[2] ?? '?';
          const hc = parts[3] ?? '?';
          diag = 'cs=' + cs + ' im=' + im + ' uu=' + uu + ' hc=' + hc;
          v = (cs === '1' || im === '1' || hc === '1') ? '1' : '0';
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
        && !this.closeGuardDefer.awaitingSaveAs && !this.fmtDialogOn) {
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
   * 系统返回键，按窗口形态分叉：
   *  - Pad（系统默认窗口形态，2026-09-18 起不再常驻沉浸）= **回桌面**（切后台）。
   *    平板惯例是「返回上一级」，而本应用是单页面（main_pages.json 仅 EditorPage）无路由上级；
   *    沿用 PC 的关窗语义会一口气关掉全部文档并退出应用（2026-09-12 用户报告）。
   *    切后台文档与 tab 原地保留、回前台即续，故不询问未保存（文档并未关闭）。
   *  - PC = 关闭窗口守卫（设计 §3.5）：收集全部 doc tab（从焦点起），逐个询问
   *    未保存（保存/不保存 → 继续下一个；取消 → 停，留在应用）；队列全处置完 →
   *    terminateSelf 退出。无 doc tab/仅主页 → 直接退出。
   * 探针态放行系统默认；放映中两侧一致=退放映。
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
    const dt = deviceInfo.deviceType;
    if (dt === 'tablet' || dt === 'phone') {
      return this.backToDesktop();
    }
    // PC：返回键与系统三键 ✕ 同语义（requestBackExit——系统 ✕ 经 EntryAbility
    // windowStageClose → 本方法）：返回 true=拦截（退出时机由守卫队列决定）；
    // false=放行系统默认（无文档/探针态）
    return this.requestBackExit();
  }

  /**
   * Pad 返回键 = 回桌面：切后台（UIAbilityContext.moveAbilityToBackground，@since 12；
   * 可能失败码 16000065=非前台、16000066=Wukong 模式）。失败仅记日志、不再动作——
   * 事件已消费（应用留在原地），不回落关窗守卫：那会违背本次返回意图、成批关文档。
   */
  private backToDesktop(): boolean {
    let ac = this.abilityCtx;
    if (ac === undefined) {
      ac = getContext(this) as common.UIAbilityContext;
    }
    this.arkLog('LSO_BACK_BG call');
    ac.moveAbilityToBackground()
      .then(() => {
        this.arkLog('LSO_BACK_BG ok');
      })
      .catch((e: BusinessError) => {
        this.arkLog('LSO_BACK_BG err ' + e.code + ' ' + e.message);
      });
    return true;
  }

  /**
   * 关闭窗口（PC 返回键 / 系统三键 ✕ 共用——✕ 经 EntryAbility windowStageClose 恒
   * 拦后调用本方法；Pad 返回键不走本链=回桌面，见 onBackPress）：收集全部 doc tab
   * （从焦点起），逐个询问未保存（保存/不保存 →
   * 继续下一个；取消 → 清队列停：留在应用）；队列全处置完 → terminateSelf 退出
   * （关闭窗口语义）；无 doc tab（仅主页）→ 直接退出。
   * 返回值恒定 true=本层已接管退出时机（onBackPress 拦截系统默认；系统 ✕ 侧由
   * EntryAbility 的 return true 拦截）；守卫在途（defer/查询/弹框）→ 同样 return
   * true 只挡不叠（弹框层自己消费返回键）。p0On 探针态由 onBackPress 先行放行。
   */
  private requestBackExit(): boolean {
    if (this.closeGuardDefer !== null || this.guardBusy || this.fmtDialogOn) {
      return true; // 有在途守卫流程/格式提示框：弹框 layer 自己消费，本层只挡默认退出
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
    // 同步到各 tab ctx（DocTabHost 的 onInterceptKeyboardAttach 回调运行时读它——
    // Pad 放映中拦截系统软键盘，见该回调注释）
    for (const p of this.docTabs) {
      p.ctx.fsMode = on;
    }
    this.arkLog('LSO_FULLSCREEN ' + (on ? '1' : '0'));
    this.applyFsWindow(on);
  }

  /**
   * 窗口形态随放映切换（PC：窗口级全屏；Pad：临时隐藏系统栏——两平台都须自行进出
   * 沉浸，不再依赖 EntryAbility 的常驻沉浸）。参照 ../wineohos
   * .../VirtualDesktopAbility.ets:78-127（PC 虚拟桌面全屏）：
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
      const actx = this.abilityCtx;
      if (actx === undefined) {
        this.arkLog('LSO_FS_WIN no context');
        return;
      }
      if (dt === 'tablet' || dt === 'phone') {
        // Pad：放映期临时隐藏系统栏（2026-09-18 用户要求 Pad 不再常驻沉浸 →
        // EntryAbility 恢复系统默认形态，故此处须自行进出沉浸，否则放映画面
        // 会被状态栏/导航条遮挡）。退出放映即还原系统栏。
        window.getLastWindow(actx).then((mw: window.Window) => {
          mw.setWindowLayoutFullScreen(on).catch((e: BusinessError) => {
            this.arkLog('LSO_FS_WIN pad layout err ' + e.code);
          });
          mw.setSpecificSystemBarEnabled('status', !on).catch((e: BusinessError) => {
            this.arkLog('LSO_FS_WIN pad status err ' + e.code);
          });
          mw.setSpecificSystemBarEnabled('navigationIndicator', !on).catch((e: BusinessError) => {
            this.arkLog('LSO_FS_WIN pad nav err ' + e.code);
          });
        }).catch((e: BusinessError) => {
          this.arkLog('LSO_FS_WIN pad win err ' + e.code);
        });
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
      const cSpec = specOf(c.state.ext);
      if (c.kind === 'doc' && cSpec !== null && cSpec.family === 'slide' && c.attached) {
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
          onSwitch: (idx: number) => this.onSwitchTab(idx),
          // tab 条「+」新建：类型菜单 → 与 create:new 同一条通路（openNewFile →
          // 空模板 → openNewTabEntry 开新 tab 并聚焦），不新增任何新建逻辑
          onNewDoc: (ext: string) => {
            this.arkLog('TAB_NEW_MENU ext=' + ext);
            this.openNewFile(ext);
          }
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
        .width('92%')
        .constraintSize({ maxWidth: 420 })
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层取消）
        })
      }
      // —— 格式提示覆盖层（不支持格式告知 / 不能原地保存的格式另存确认）——
      if (this.fmtDialogOn) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            this.fmtDialogAction('cancel');
          })
        Column({ space: 4 }) {
          Text('格式提示')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2B3B4D')
          Text(this.fmtDialogText)
            .fontSize(14).fontColor('#5A6572').textAlign(TextAlign.Center)
            .margin({ top: 12 })
          Row({ space: 12 }) {
            if (this.fmtDialogCtx === null) {
              // 告知层（无保存上下文）：单按钮——此语境下「继续」无任何可执行的后续，
              // 双按钮只会让人以为点错了还能挽救（设计文档 §7 单按钮语义）
              Button('知道了')
                .layoutWeight(1)
                .backgroundColor('#0064E7').fontColor(Color.White)
                .onClick(() => {
                  this.fmtDialogAction('ok');
                })
            } else {
              // 保存确认层：有后续动作（转另存），保留取消/继续二选一
              Button('取消')
                .layoutWeight(1)
                .backgroundColor('#F7F7F7').fontColor('#2B3B4D')
                .onClick(() => {
                  this.fmtDialogAction('cancel');
                })
              Button('继续')
                .layoutWeight(1)
                .backgroundColor('#0064E7').fontColor(Color.White)
                .onClick(() => {
                  this.fmtDialogAction('ok');
                })
            }
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .padding(24)
        .width('92%')
        .constraintSize({ maxWidth: 420 })
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层取消）
        })
      }
      // —— 文档密码覆盖层（密文文档：无密码/密码错时弹；自绘同守卫框，回车=确定）——
      if (this.pwdDialogOn) {
        // 蒙层=取消（不打开该文档）
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            this.pwdDialogAction('cancel');
          })
        Column({ space: 4 }) {
          Text('文档受密码保护')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2B3B4D')
          Text(this.pwdDialogMsg)
            .fontSize(14).fontColor('#5A6572').textAlign(TextAlign.Center)
            .margin({ top: 12 })
          TextInput({ placeholder: '请输入密码', text: this.pwdValue })
            .type(InputType.Password)
            .width('100%')
            .margin({ top: 16 })
            .onChange((v: string) => {
              this.pwdValue = v;
            })
            .onSubmit(() => {
              this.pwdDialogAction('ok');
            })
          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .backgroundColor('#F7F7F7').fontColor('#2B3B4D')
              .onClick(() => {
                this.pwdDialogAction('cancel');
              })
            Button('确定')
              .layoutWeight(1)
              .backgroundColor('#0064E7').fontColor(Color.White)
              .onClick(() => {
                this.pwdDialogAction('ok');
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .padding(24)
        .width('92%')
        .constraintSize({ maxWidth: 420 })
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层取消）
        })
      }
      // —— 字体管理弹层（自绘覆盖层，同守卫框；欢迎页侧栏「字体管理」入口）——
      if (this.fontMgrOn) {
        // 蒙层=关闭（管理界面无未保存数据，不需要守卫语义）
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            this.closeFontManager();
          })
        Column({ space: 4 }) {
          // 标题行：左标题 + 右关闭。蒙层点击也能关，但**显式出口不能省**——只靠
          // 点空白处关闭是常见疑惑点（用户会盯着卡片找关闭按钮）。
          Row() {
            Text('字体管理')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2B3B4D')
              .layoutWeight(1)
            Text('×')
              .fontSize(22).fontColor('#7A8794')
              .padding({ left: 12, right: 4, top: 2, bottom: 6 })
              .onClick(() => {
                this.closeFontManager();
              })
          }
          .width('100%')
          if (this.fontMgrRows.length === 0) {
            Text('还没有导入字体')
              .fontSize(14).fontColor('#5A6572')
              .margin({ top: 32, bottom: 32 })
          } else {
            List({ space: 0 }) {
              ForEach(this.fontMgrRows, (r: FontListItem) => {
                ListItem() {
                  Column({ space: 2 }) {
                    Row({ space: 10 }) {
                      Text(r.family)
                        .fontSize(15).fontColor('#2B3B4D')
                        .layoutWeight(1).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Button('删除')
                        .fontSize(13).height(30)
                        .backgroundColor('#F7F7F7').fontColor('#C0392B')
                        .onClick(() => {
                          this.fontMgrDeleteConfirm(r.id, r.family);
                        })
                    }
                    .width('100%')
                    Text(r.sub)
                      .fontSize(12).fontColor('#7A8794')
                      .width('100%').maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .padding({ top: 10, bottom: 10, left: 4, right: 4 })
                }
              }, (r: FontListItem) => r.id)
            }
            .width('100%')
            .height(260)
            .margin({ top: 12 })
          }
          Button(this.fontMgrBtnText())
            .width('100%').height(38)
            .enabled(!this.fontMgrBusy && this.fontMgrRows.length < MAX_FONTS)
            .backgroundColor(this.fontMgrRows.length < MAX_FONTS ? '#0064E7' : '#C9D2DC')
            .fontColor(Color.White)
            .margin({ top: 16 })
            .onClick(() => {
              this.fontMgrImport();
            })
          if (this.fontMgrRows.length >= MAX_FONTS) {
            Text('已达上限 ' + MAX_FONTS + ' 个')
              .fontSize(12).fontColor('#7A8794')
              .margin({ top: 6 })
          }
        }
        .padding(24)
        .width('92%')
        .constraintSize({ maxWidth: 520 })
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层关闭）
        })
      }
      // —— 手机原生主页「关于」弹层（自绘覆盖层）——
      // 合规内容与 Web 版 About 同一事实源（build_editors_ohos CREDIT/SOURCE_LINE
      // 的 ArkTS 复刻）：AGPL-3.0 行 + 「完整源码与第三方声明」行，点行看随包全文。
      if (this.phoneAboutOn) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            if (this.phoneAboutLicKind !== '') {
              this.phoneAboutLicKind = '';
              this.phoneAboutLicText = '';
            } else {
              this.phoneAboutOn = false;
            }
          })
        Column({ space: 12 }) {
          Row() {
            Text(this.phoneAboutLicKind !== '' ? this.phoneAboutLicKind : '关于')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2B3B4D')
              .layoutWeight(1)
            Text('×')
              .fontSize(22).fontColor('#7A8794')
              .padding({ left: 12, right: 4, top: 2, bottom: 6 })
              .onClick(() => {
                if (this.phoneAboutLicKind !== '') {
                  this.phoneAboutLicKind = '';
                  this.phoneAboutLicText = '';
                } else {
                  this.phoneAboutOn = false;
                }
              })
          }
          .width('100%')
          if (this.phoneAboutLicKind === '') {
            Column({ space: 10 }) {
              Text('Pure Office')
                .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2B3B4D')
              Text('版本 ' + this.phoneAboutVer)
                .fontSize(13).fontColor('#7A8794')
              Text('基于 ONLYOFFICE DesktopEditors（AGPL-3.0）')
                .fontSize(13).fontColor('#5A6572')
                .width('100%')
              Row({ space: 16 }) {
                Text('许可全文')
                  .fontSize(13).fontColor('#0064E7')
                  .onClick(() => {
                    this.phoneAboutShowLic('LICENSE');
                  })
                Text('完整源码与第三方声明')
                  .fontSize(13).fontColor('#0064E7')
                  .onClick(() => {
                    this.phoneAboutShowLic('NOTICE');
                  })
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .margin({ top: 8 })
          } else {
            Scroll() {
              Text(this.phoneAboutLicText)
                .fontSize(12).fontColor('#2B3B4D')
                .width('100%')
            }
            .height(360)
            .width('100%')
          }
        }
        .padding(24)
        .width('92%')
        .constraintSize({ maxWidth: 520 })
        .backgroundColor(Color.White)
        .borderRadius(12)
        .onClick(() => {
          // 吞掉卡片内点击（不穿透蒙层关闭）
        })
      }
    }
  }

  /**
   * 格式提示动作（自绘层唯一出口）：ok=继续 / cancel 或蒙层=关闭。
   * 用途两类：① 不支持格式的告知；② 不能原地保存的格式在保存时的「提示 → 另存」
   * 确认（另存分支见 saveBinRaw 的 needsSaveAsPrompt 段）。
   */
  private fmtDialogAction(act: string): void {
    if (!this.fmtDialogOn) {
      return;
    }
    const ctx = this.fmtDialogCtx;
    const out = this.fmtDialogOut;
    const lossy = this.fmtDialogLossy;
    this.fmtDialogOn = false;
    this.fmtDialogCtx = null;
    this.fmtDialogOut = null;
    this.fmtDialogText = '';
    this.fmtDialogLossy = false;
    if (ctx === null) {
      // 告知层（不支持格式 / 保存链异常）无保存上下文：关闭即可，无落盘动作。
      // 但 defer 在途时必须消费——本层会出现在守卫「保存」链中途（如源文件不可写），
      // 不消费则 defer 永久残留 → requestBackExit 恒拦，tab 关不掉、返回键与系统 ✕
      // 全无响应。取 ok=false：这类告知都意味着内容没落到用户文件，关 tab 会连带
      // 掐断提示里指的那条出口（另存为）。
      this.arkLog('FMT_DIALOG_CTX_NULL act=' + act);
      const d = this.closeGuardDefer;
      if (d !== null) {
        this.clearCloseGuard(d.ctx, false);
      }
      return;
    }
    // tab 已被移除（守卫竞态/兜底）：绝不为已关闭的文档落盘——否则用户会在
    // 「已经关掉」的文档之外凭空得到一份另存文件（且标题刷新找不到 ctx）
    if (this.findCtx(ctx.id) === null) {
      this.arkLog('FMT_DIALOG_CTX_GONE tab=' + ctx.id + ' act=' + act);
      this.clearCloseGuard(ctx, false);
      return;
    }
    if (act !== 'ok' || out === null) {
      // 取消/蒙层：数据未落盘（同另存为取消语义——守卫在途则不关）
      this.arkLog('FMT_DIALOG_CANCEL ext=' + ctx.state.ext + ' tab=' + ctx.id);
      ctx.state.saveAborted = true;
      this.clearCloseGuard(ctx, false);
      return;
    }
    const spec = specOf(ctx.state.ext);
    if (lossy) {
      // csv「丢格式」提示的「继续」= 直接落盘（原地回写，保存目标格式不变）
      this.arkLog('FMT_DIALOG_CONFIRM_LOSSY ext=' + ctx.state.ext + ' tab=' + ctx.id);
      this.commitSavedLocal(ctx, out, true);
      return;
    }
    const targetExt = spec !== null ? spec.saveExt : 'docx';
    this.arkLog('FMT_DIALOG_CONFIRM ext=' + ctx.state.ext + ' to=' + targetExt + ' tab=' + ctx.id);
    this.doSaveAs(ctx, out, targetExt);
  }

  /**
   * 文档密码弹框（密文文档打开链；自绘覆盖层，与守卫框同因——CustomDialog 真机
   * 点击失效、AlertDialog 无取消键）。cb(null) = 取消（放弃打开该文档）；
   * cb(密码) = 重转。isRetry 仅决定提示文案（"密码错误"）。
   */
  private showPwdDialog(isRetry: boolean, cb: (pwd: string | null) => void): void {
    if (this.pwdDialogOn) {
      return; // 互斥：弹框在途时不再叠框
    }
    this.pwdDialogRetry = isRetry;
    this.pwdDialogMsg = isRetry ? '密码错误，请重新输入。' : '该文档已加密，请输入打开密码。';
    this.pwdValue = '';
    this.pwdDialogCb = cb;
    this.pwdDialogOn = true;
    this.arkLog('OPEN_PWD_DIALOG_ON retry=' + isRetry);
  }

  /** 密码弹框动作：ok=提交输入值 / cancel 或蒙层=取消。空输入按取消处理——
   *  对密文文档空密码无意义（x2t 收到空密码会回落试默认口令，属另一语义，
   *  不该由"没输入就点确定"触发）。 */
  private pwdDialogAction(act: string): void {
    if (!this.pwdDialogOn) {
      return;
    }
    const cb = this.pwdDialogCb;
    const val = this.pwdValue;
    const retry = this.pwdDialogRetry;
    this.pwdDialogOn = false;
    this.pwdDialogCb = null;
    this.pwdValue = '';
    this.pwdDialogMsg = '';
    this.pwdDialogRetry = false;
    if (cb === null) {
      return;
    }
    if (act !== 'ok' || val.length === 0) {
      this.arkLog('OPEN_PWD_CANCEL act=' + act + ' empty=' + (val.length === 0));
      cb(null);
      return;
    }
    this.arkLog('OPEN_PWD_SUBMIT len=' + val.length + ' retry=' + retry);
    cb(val);
  }

  /** 不支持格式的告知层（复用格式覆盖层 UI；文案由调用方给定） */
  private showFormatNotice(text: string): void {
    this.fmtDialogCtx = null;
    this.fmtDialogOut = null;
    this.fmtDialogText = text;
    this.fmtDialogOn = true;
    this.arkLog('FMT_NOTICE ' + text);
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
