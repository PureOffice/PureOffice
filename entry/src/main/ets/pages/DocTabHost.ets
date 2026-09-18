import { webview } from '@kit.ArkWeb';
import { BuilderNode, NodeController, UIContext } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { loadRaw } from '../common/rawfileLoader';
import { resourceManager } from '@kit.LocalizationKit';
import { specOf } from '../common/formats';

/**
 * PC（2in1/pc）tab 条高度=37（用户 2026-09-09 拍板：与 setWindowDecorHeight
 * 合法最小 37 / 悬浮标题栏固定 37vp 对齐；Pad 保持 32）
 */
const IS_PC: boolean = deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'pc';
const TAB_BAR_H: number = IS_PC ? 37 : 32;

/** PC 文档页整体放大倍数（ArkUI 渲染层缩放，见 buildDocWeb 注）。主页不放大。
 *  2026-09-18 用户拍板 1.2——倍数越大清晰度与可视区代价越高（渲染按缩小后的尺寸算）。 */
const PAGE_ZOOM_PC: number = 1.2;

/** 是否对该实例应用 PC 放大（仅 PC 的文档 tab；主页与 Pad 保持原尺寸） */
function pcZoomOn(ctx: DocTabCtx): boolean {
  return IS_PC && ctx.kind === 'doc';
}

/**
 * 多文档 Tab 容器（P1a：容器骨架——单文档 tab + 常驻主页）。
 * 结构对齐 P0 已验证的 Harmonix 骨架（Tabs+ForEach+NodeContainer；
 * 节点复用=保活，见 docs/ONLYOFFICE_MULTITAB_DESIGN.md §5/§9.1）：
 *   DocTabCtx   每个实例的上下文（url/controller/装配回调）
 *   DocTabNode  NodeController（BuilderNode 只 build 一次——切换复用）
 *   DocTabHost  容器组件：自绘 tab 条（主页 chip 恒第一 + doc chip×N + ×）
 *
 * 装配（onControllerAttached 整段）由 EditorPage 以 onInstanceReady(ctx) 注入
 * ——装配逻辑与业务都留在 EditorPage（P1a 状态单例，P1b 再 per-tab 化）。
 */

/** 实例装载回调：Web onControllerAttached 后执行（EditorPage 灌入完整装配） */
export type CtxReady = (ctx: DocTabCtx) => void;

/**
 * 文档身份状态（per-tab 单一事实源；原 EditorPage 单例字段下沉——多文档并存的核心）。
 * saveBinRaw/doSaveAs/save:as 全部只经 ctx.state 读写。
 */
export class DocTabState {
  /** 当前文档名（保存回写源文件/另存为默认名/tab 标题） */
  name: string = '';
  /** 当前扩展名 docx/xlsx/pptx（转换器选择） */
  ext: string = 'docx';
  /** 保存目标 'none'（新建无身份）/ 'sandbox' | 'uri' */
  saveTarget: string = 'none';
  /** 真实保存位置（uri 或沙箱工作副本） */
  savePath: string = '';
  /** 有待打开文档（LocalStartOpen 注入守卫） */
  pendingOpen: boolean = false;
  /** 保存被中止/失败（2026-09-09 未保存关闭守卫）：asc_Save 触发后引擎即复位
   *  canSave——但另存为取消/落盘失败=数据未保存、页面 CanSave 却已 false——
   *  ArkTS 侧记忆此态，守卫查询时忽略页面 '0'（真数据未落盘，必须再弹框） */
  saveAborted: boolean = false;
  /** 密文文档密码（非空 = 该 tab 打开的是密码保护文档）。打开链解密成功后写入；
   *  保存链据此下发 m_sSavePassword，否则产物是明文——加密文档保存一次即被静默
   *  降级为明文（2026-09-12 实测：密文 docx 打开后保存产物为明文 zip）。 */
  pwd: string = '';
}

export class DocTabCtx {
  id: number;
  kind: string; // 'home' | 'doc'
  title: string;
  url: string;
  attached: boolean = false;
  /** 放映全屏态副本（EditorPage 随放映同步；buildDocWeb 的 @Builder 拿不到组件 @Link，
   *  而 onInterceptKeyboardAttach 回调在运行时读它决定是否放行系统软键盘） */
  fsMode: boolean = false;
  /** per-tab 文档身份（home 实例空态——不使用） */
  state: DocTabState = new DocTabState();
  controller: webview.WebviewController = new webview.WebviewController();
  resMgr: resourceManager.ResourceManager | null = null;
  filesDir: string = '';
  log: (m: string) => void;
  onReady: CtxReady | null;
  /** onPageEnd 回调（EditorPage 注入：m7 直达/页面错误采集；每实例一次） */
  onPageEndCb: CtxReady | null;
  /** Web 组件 onControllerAttached 回调（仅第一次——节点复用时不重装配） */
  onAttached: () => void;
  /**
   * 页面侧文件选择器请求（ArkWeb onShowFileSelector）。
   * 引擎的插入图片/插入文档走 web 形态的 `<input type=file>`（editorscommon.js
   * `GetUploadInput`）——ArkWeb 里必须由宿主接管才会弹选择器，否则 click() 无反应。
   * EditorPage 注入实现：弹系统 picker → 拷入本 tab 工作目录 → handleFileList(路径)。
   * 缺省空实现 = 取消（回填空列表）。
   */
  onPickFile: (result: FileSelectorResult, acceptTypes: string[]) => void = () => {
  };

  constructor(id: number, kind: string, title: string, url: string,
    resMgr: resourceManager.ResourceManager, filesDir: string, log: (m: string) => void,
    onReady: CtxReady | null, onPageEndCb: CtxReady | null = null) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.url = url;
    this.resMgr = resMgr;
    this.filesDir = filesDir;
    this.log = log;
    this.onReady = onReady;
    this.onPageEndCb = onPageEndCb;
    this.onAttached = () => {
      if (this.attached) {
        return;
      }
      this.attached = true;
      try {
        if (this.onReady !== null) {
          this.onReady(this);
        }
      } catch (e) {
        this.log('[' + this.kind + (this.id) + '] attach err ' + String(e));
      }
    };
  }

  /**
   * per-tab 工作目录（多文档隔离的**目录**级实现）。
   * 为何要目录（2026-09-12）：x2t 转换时把文档内嵌媒体解包到「工作文件所在目录/media」
   * （DocxSerializer setSrcPath(bin 目录)），而原先所有 tab 的临时文件平铺在 filesDir
   * 根、只靠文件名后缀区分 → 媒体全落同一个 `filesDir/media/` → 两个 tab 打开不同文档
   * 且图名相同（都叫 image1.png）时互相覆盖（显示/保存都拿错图，静默）。
   * 收进 per-tab 目录后 x2t 自然解包到 `<tabDir>/media/`，隔离无需额外代码。
   * 目录首次取用时创建（mkdirSync 非递归，此处仅一级；已存在则忽略）。
   */
  tabDir(): string {
    const d = this.filesDir + '/t' + this.id;
    try {
      fs.mkdirSync(d);
    } catch (e) {
      // 已存在——正常路径
    }
    return d;
  }

  /** per-tab 临时文件路径（工作目录内——多文档隔离） */
  tabPath(base: string): string {
    return this.tabDir() + '/' + base;
  }

  /** runJavaScript 帮助（打点/守卫共用；错误留痕） */
  js(code: string, tag: string): void {
    this.controller.runJavaScript(code, (err: BusinessError, res: string) => {
      if (err) {
        this.log('[' + this.kind + this.id + '] ' + tag + ' err ' + err.code + ' ' + err.message);
      } else if (tag !== '') {
        this.log('[' + this.kind + this.id + '] ' + tag + ' -> ' + res);
      }
    });
  }
}

/** NodeController：makeNode 缓存 BuilderNode（节点复用=保活的机制核心） */
export class DocTabNode extends NodeController {
  private webNode: BuilderNode<[DocTabCtx]> | null = null;
  private ctx: DocTabCtx;

  constructor(ctx: DocTabCtx) {
    super();
    this.ctx = ctx;
  }

  makeNode(context: UIContext): FrameNode | null {
    if (this.webNode !== null) {
      return this.webNode.getFrameNode();
    }
    this.webNode = new BuilderNode(context);
    this.webNode.build(wrapBuilder<[DocTabCtx]>(buildDocWeb), this.ctx);
    return this.webNode.getFrameNode();
  }
}

/** tab 项：内容 ctx + 节点（NodeContainer 对接） */
export class DocTabPair {
  ctx: DocTabCtx;
  node: DocTabNode;

  constructor(ctx: DocTabCtx) {
    this.ctx = ctx;
    this.node = new DocTabNode(ctx);
  }
}

/**
 * 文档类型 accent 兜底（页面 00_theme 0.10 上报前/失败时：docx 蓝 / xlsx 绿 /
 * pptx 紫近似——与官方 colors-table 各 app 主色呼应）。
 */
function accentColor(state: DocTabState): string {
  // 按族取色（新增格式自动归族——.xls 与 .xlsx 同色、.doc 与 .docx 同色）
  const spec = specOf(state.ext);
  const family = spec !== null ? spec.family : 'word';
  if (family === 'cell') {
    return '#3E8D5F';
  }
  if (family === 'slide') {
    return '#8E5EB8';
  }
  return '#4B71A5';
}

/**
 * hex 混色（#RRGGBB，#RRGGBB，w=第二个色占比 0..1）——非激活 chip 观感
 * （用户决策 2026-09-09：hex 混色回朝，且混浅=w 0.8 更接近白，比初版 0.4 更低调；
 * 白底版方案已撤回）。转换失败原样返回。
 */
function hexBlend(a: string, b: string, w: number): string {
  try {
    const pa = a.length === 7 ? a.substring(1) : a;
    const pb = b.length === 7 ? b.substring(1) : b;
    if (pa.length !== 6 || pb.length !== 6) {
      return a;
    }
    const r = Math.round(parseInt(pa.substring(0, 2), 16) * (1 - w) + parseInt(pb.substring(0, 2), 16) * w);
    const g = Math.round(parseInt(pa.substring(2, 4), 16) * (1 - w) + parseInt(pb.substring(4, 6), 16) * w);
    const bl = Math.round(parseInt(pa.substring(4, 6), 16) * (1 - w) + parseInt(pb.substring(4, 6), 16) * w);
    const h = (n: number): string => {
      const s = n.toString(16).toUpperCase();
      return s.length === 1 ? '0' + s : s;
    };
    return '#' + h(r) + h(g) + h(bl);
  } catch (e) {
    return a;
  }
}

/** 该 tab 的主题色（页面上报值优先；空=静态 accent 兜底） */
function accentOf(accent: string, state: DocTabState): string {
  if (accent !== undefined && accent.length > 0 && accent !== '') {
    return accent;
  }
  return accentColor(state);
}

/** Web 内容构建（文件级 @Builder——BuilderNode/wrapBuilder 要求） */
@Builder
function buildDocWeb(ctx: DocTabCtx) {
  Web({ src: ctx.url, controller: ctx.controller })
    .javaScriptAccess(true)
    .domStorageAccess(true)
    .fileAccess(true)
    .onInterceptRequest((event) =>
      loadRaw(event.request, ctx.resMgr!, ctx.filesDir, ctx.tabDir() + '/media',
        ((m: string) => ctx.log('[' + ctx.kind + ctx.id + '] ' + m))) as WebResourceResponse)
    // 文件选择器（插入图片等 <input type=file> 的宿主实现）。同步 return true =
    // 已接管；实际选择与回填在 ctx.onPickFile 里异步完成（handleFileList 可在
    // 回调外调用）。不接管则 ArkWeb 无从弹选择器，页面 click() 静默无反应。
    .onShowFileSelector((event) => {
      try {
        ctx.onPickFile(event.result, event.fileSelector.getAcceptType());
      } catch (e) {
        ctx.log('[' + ctx.kind + ctx.id + '] pickfile err ' + String(e));
        try {
          event.result.handleFileList([]);
        } catch (e2) {
          // 回填失败——忽略（页面侧按取消处理）
        }
      }
      return true;
    })
    .onControllerAttached(() => {
      ctx.onAttached();
    })
    // Pad 放映中不放行系统软键盘：放映（含点击切页）会让页面内可编辑元素拿到焦点，
    // 系统随之拉起键盘、挤压放映画面（2026-09-18 1.6 真机现象）。此处按放映态拦截。
    // PC 不拦（无软键盘语义，且放映外仍需正常输入）。
    .onInterceptKeyboardAttach((_info: WebKeyboardCallbackInfo): WebKeyboardOptions => {
      if (!IS_PC && ctx.fsMode) {
        return { useSystemKeyboard: false };
      }
      return { useSystemKeyboard: true };
    })
    .onPageEnd(() => {
      ctx.log('[' + ctx.kind + ctx.id + '] PAGE_END ' + ctx.controller.getUrl());
      if (ctx.onPageEndCb !== null) {
        try {
          ctx.onPageEndCb(ctx);
        } catch (e) {
          ctx.log('[' + ctx.kind + ctx.id + '] pageend err ' + String(e));
        }
      }
    })
    .onConsole((event: OnConsoleEvent) => {
      const line = event.message.getSourceId() + ':' + event.message.getLineNumber()
        + ' ' + event.message.getMessage();
      ctx.log('[' + ctx.kind + ctx.id + '] [web] ' + line);
      return false;
    })
    .onErrorReceive((err: OnErrorReceiveEvent) => {
      ctx.log('[' + ctx.kind + ctx.id + '] Web error: ' + JSON.stringify(err));
    })
    // PC 文档页整体放大（ArkUI 渲染层）：布局尺寸缩到 1/f（Web 的 CSS 视口随之变窄，
    // 页面按更窄视口重排 = UI 相对变大），再以左上角为原点 scale(f) 放大回满。
    // 与页面侧 JS 改布局的区别：变换由 ArkUI 统一处理，Web 收到的事件坐标仍是自洽的
    // 布局坐标（无坐标系冲突）；代价是渲染分辨率按缩小后的尺寸算，放大后略糊。
    .width(pcZoomOn(ctx) ? (100 / PAGE_ZOOM_PC) + '%' : '100%')
    .height(pcZoomOn(ctx) ? (100 / PAGE_ZOOM_PC) + '%' : '100%')
    .scale(pcZoomOn(ctx)
      ? { x: PAGE_ZOOM_PC, y: PAGE_ZOOM_PC, centerX: '0%', centerY: '0%' }
      : { x: 1, y: 1 })
}

/**
 * 容器组件：顶部自绘 tab 条 + Tabs 内容区。
 * 主页 chip 恒第一（kind='home'，无 ×）；doc chip 带 ×（点击 → onCloseDoc）。
 * index 切换 = controller.changeIndex；切走/切回均不重建（节点复用）。
 */
@Component
export struct DocTabHost {
  @Link tabs: DocTabPair[];
  /** 活动 tab（EditorPage 受控：open 后自动切到新 doc；TabsController index 同步） */
  @Link focus: number;
  /** tab 标题平行数组（@State 元素级可观察——另存为改名即时刷新 chip 标题） */
  @Link titles: string[];
  /** tab 主题色平行数组（页面 00_theme 0.10 上报当前主题 CSS 变量值；''=回退静态 accent） */
  @Link accents: string[];
  /** 放映全屏态（EditorPage：sdkjs 放映引擎 SetFullscreen 桥驱动）——true 时整条
   *  自绘 tab 条不渲染，Tabs 内容区（layoutWeight 1）自动吸顶铺满整个窗口。
   *  2026-09-11：PPT 放映「只在 webview 内播、tab 栏还在」修复。 */
  @Link fsMode: boolean;
  private tabsCtr: TabsController = new TabsController();
  onCloseDoc: (id: number) => void = () => {
  };
  onSwitch: (index: number) => void = () => {
  };
  /** + 菜单选中（新建文档）：EditorPage 注入 → openNewFile（唯一新建通路） */
  onNewDoc: (ext: string) => void = () => {
  };

  /** 是否已有文档 tab（+ 的显示条件——只有主页时不显示） */
  private hasDocTab(): boolean {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].ctx.kind === 'doc') {
        return true;
      }
    }
    return false;
  }

  /** + 菜单项（数据驱动：系统渲染菜单，点击回调 action）。措辞取自官方中文
   *  语言包同族词条（Controllers/LeftMenu.newDocumentTitle 去掉「未命名的」）。 */
  private newMenuItems(): MenuElement[] {
    return [
      { value: '文档', action: () => { this.onNewDoc('docx'); } },
      { value: '电子表格', action: () => { this.onNewDoc('xlsx'); } },
      { value: '演示', action: () => { this.onNewDoc('pptx'); } }
    ];
  }

  build() {
    Column() {
      // —— 自绘 tab 条（官方桌面形态，2026-09-08 参考 .temp/desktop-example.png）：
      //   条底恒定浅色 #F7F7F7（官方 --background-normal，与欢迎页侧栏同色）；
      //   激活 chip = 该文档页当前主题色原色白字（00_theme 0.10 上报告 CSS 变量
      //   --toolbar-header-<app>，主题切换自动跟随）；非激活 = 同色混白 0.8；
      //   主页 chip = 与条底同色黑字（与侧栏贯通，无视觉分界）。
      // 用户决策 2026-09-09：tab item 之间无左右边距（官方桌面 chip 贴排观感）；
      // 不滚动/不 overflow——chip 以 flexShrink 收缩（见 chip 链），总宽恒≤可用
      // 宽→右 padding（150 避让三键区）常驻生效（Scroll/fit-content/固定宽溢出
      // 三种方案均被 ArkUI 溢出绘制击败，2026-09-09 用户实证）
      Row() {
        ForEach(this.tabs, (item: DocTabPair, index: number) => {
          Row({ space: 2 }) {
            // 标题区恒占满「剩余宽 − ×」——用户 2026-09-10 方案 B（标题左对齐、
            // × 定右）：layoutWeight(1) 后内层 Row 无剩余空间，chip 的
            // justifyContent(Center) 自然失效，× 恒贴右；标题短/长都不再带跑 ×
            //（此前无 layoutWeight：标题短时「标题+×」整体居中、× 漂向窗口中部）。
            // 主页 chip 特例（同用户拍板 2026-09-10）：无 × → 标题在 chip 内居中
            //（textAlign Center；doc chip 保持 Start 左对齐——× 定右已由
            // layoutWeight 保证）。
            Text(this.titles[index])
              .fontSize(12)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(item.ctx.kind === 'home' || this.focus !== index ? '#2B3B4D' : Color.White)
              .flexShrink(1)
              .layoutWeight(1)
              .textAlign(item.ctx.kind === 'home' ? TextAlign.Center : TextAlign.Start)
            if (item.ctx.kind === 'doc') {
              // 关闭钮：官方图标（HarmonyOS symbol——wineohos 同款惯例 SymbolGlyph），
              // 独立节点 + 大触区（≥44px 物理）；hitTestBehavior Block 拦截命中
              // 传播——点 × 不触发 chip 切换 onClick（ArkUI ClickEvent 无
              // stopPropagation；Block 是官方阻断方案，用户 2026-09-09 验证点）
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([this.focus === index ? Color.White : '#5A6572'])
                // 用户决策 2026-09-09：× 不再自留 right 内衬——chip 自身已有
                // right:6，叠加（6+10=16vp）使关闭钮贴右空隙过大；保留 left:10
                // 作它与标题的间距
                .padding({ left: 10, right: 0, top: 8, bottom: 8 })
                // 鼠标 hover 反馈：ArkUI 组件默认能力，用户 2026-09-09 拍板
                // Scale（悬停轻微放大——反馈强度优于 Auto 蒙层）
                .hoverEffect(HoverEffect.Scale)
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => {
                  this.onCloseDoc(item.ctx.id);
                })
            }
          }
          // 用户决策 2026-09-09：切换点击挂整个 chip（此前只挂标题 Text——chip
          // 空白/内衬区点击无响应；× 子节点已 stopPropagation 互斥）
          .onClick(() => {
            this.tabsCtr.changeIndex(index);
            this.focus = index;
            this.onSwitch(index);
          })
          // 原 justifyContent(Center) 已删（用户 2026-09-10 方案 B）：标题
          // layoutWeight(1) 占满剩余后无剩余空间，Center 恒不生效——留着误导。
          // 官方形态：chip = 固定宽块（doc≈160vp / home≈100vp；仅横向小内衬；
          // 通栏高、方角——参考图 .temp/desktop-example.png。禁止 layoutWeight/
          // stretch（曾导致 chip 撑满整行等宽——用户 2026-09-09 指正）。
          // 2026-09-09 二修正：**可收缩**（flexShrink 1 + minWidth 下限）——
          // tab 多时 chip 收窄而非溢出（先前固定 160 溢出覆盖到系统按钮区/
          // Scroll/fit-content 均被 ArkUI 溢出绘制打败——元素级 flex 收缩是
          // 官方语义，浏览器 tab 条同款）
          .width(item.ctx.kind === 'home' ? 100 : 160)
          .flexShrink(1)
          .padding({ left: 12, right: 6 })
          .borderRadius(0)
          .height(TAB_BAR_H)
          // chip 底色（用户决策 2026-09-09：**只有选中项才是文档主题色，条底恒定**）：
          // home=白底黑字（官方徽标 chip，细边分离）；doc 激活=该 tab 文档主题色
          // 原色（白字）；doc 非激活=同色混白 40%（降调观感）
          // 用户决策 2026-09-09（三改+修正）：主页 chip 底色=条底=下方侧栏背景
          // 同色 —— 官方源码实测：侧栏背景 = 根变量 --background-normal
          // #F7F7F7（theme-classic-light 不改写它；此前自拟 #F2F3F5 差 5 阶灰
          // 被用户肉眼抓出）；非激活 doc chip=文档色混白 0.8；激活=主题色原色
          .backgroundColor(item.ctx.kind === 'home' ? '#F7F7F7'
            : (this.focus === index
              ? accentOf(this.accents[index], item.ctx.state)
              : hexBlend(accentOf(this.accents[index], item.ctx.state), '#FFFFFF', 0.8)))
          // 用户决策 2026-09-09：主页 chip 无边框（白底黑字 + 条底浅灰反差已可辨）
          .border({ width: 0, color: Color.Transparent })
          // 收缩下限为**建议值**（实测 flexShrink 收缩可到 ≈73vp——constraintSize
          // minWidth 与 flexShrink 并存时以收缩结果为准；不承诺下限，标题省略号兜底）
          .constraintSize({ minWidth: item.ctx.kind === 'home' ? 72 : 96, maxWidth: 320 })
        }, (item: DocTabPair) => item.ctx.kind + '-' + item.ctx.id.toString())
        // ——「+」新建文档（有 doc tab 时才在）：点开系统菜单选类型 ——
        // 位置紧跟最后一个 chip（浏览器 tab 条同款）；不固定到条右端——PC 的右内衬
        // 150 是系统三键避让区，固定右端会与 chips 割裂。菜单用 ArkUI 官方
        // bindMenu：MenuElement 是数据描述、由系统渲染并回调 action，不经组件树
        // 事件分发（与 CustomDialog 那个「自定义按钮点击到不了 ArkTS」不同机制）。
        // 设计依据见 docs/superpowers/specs/2026-09-18-tab-new-button-design.md
        if (this.hasDocTab()) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(16)
            .fontColor(['#2B3B4D'])
            // 触区：宽 = 16 + 10×2 = 36vp，高给满条高（SymbolGlyph 无 textAlign，
            // 宽度只能由左右内衬撑出——与 × 同款做法）
            .padding({ left: 10, right: 10 })
            .height(TAB_BAR_H)
            .hoverEffect(HoverEffect.Scale)
            .bindMenu(this.newMenuItems())
        }
        // —— 系统三键区说明（2026-09-10 用户纠正+UI dump 实证）——
        // setWindowDecorVisible(false) **只隐藏标题栏，系统 −□✕ 三键仍在窗口
        // 右上角**（1.4 实测：三键 [2370,297]-[2560,335]，原生 38px 键距）。
        // 此前「decor 隐藏三键即不存在」为错误结论——取证样本 1.8（tablet
        // 沉浸窗口本无三键），与 decor 无关。故**不再自绘任何窗口键**。
        // 关闭窗口守卫由 WindowStage.on('windowStageClose') 拦截（EntryAbility
        // → requestBackExit，与返回键同链）。最小化/最大化=系统原生，零参与。
        // 三键在右 padding 150 内——下方 padding 正是避让其左缘。
      }
      // 显式 Start——chip 加 flexShrink 后进 flex 自由项上下文，Row 未显式设
      // justifyContent 时被默认居中（用户 2026-09-09 实证：tabs 跑到窗口中央）
      .justifyContent(FlexAlign.Start)
      .width('100%')
      .height(TAB_BAR_H)
      // 左右内衬：左 0（chip 贴窗口左缘）；右 PC=150 固定（HiSH 参考——PcIndex
      // 顶栏 padding{left:15,right:150}，150=系统三键区（−□✕）默认避让；Pad 无
      // 三键=0。chip 已可收缩（flexShrink）→ 不产生溢出绘制，padding 恒生效
      .padding({ left: 0, right: IS_PC ? 150 : 0 })
      // 条底恒定=官方 --background-normal #F7F7F7（2026-09-09 用户决策：不随
      // 激活文档换色——只有 chip 染色；与欢迎页侧栏同色，上下贯通无分界）
      .backgroundColor('#F7F7F7')
      // 放映全屏（2026-09-11）：Visibility.None = 隐藏且**不参与布局**（不占位）
      // ——与 if 条件渲染等价，但保持本段组件树结构稳定（放映进出不重建 chip）。
      // 条消失后 Tabs（layoutWeight 1）自动吸顶铺满整个窗口。
      .visibility(this.fsMode ? Visibility.None : Visibility.Visible)

      // —— 内容切换容器（barHeight 0；保活 = NodeContainer 节点复用）——
      Tabs({ barPosition: BarPosition.Start, index: this.focus, controller: this.tabsCtr }) {
        ForEach(this.tabs, (item: DocTabPair, index: number) => {
          TabContent() {
            NodeContainer(item.node)
              .width('100%')
              .height('100%')
          }
        }, (item: DocTabPair) => item.ctx.kind + '-c' + item.ctx.id.toString())
      }
      .scrollable(false)
      .barHeight(0)
      .layoutWeight(1)
      .onChange((index: number) => {
        this.focus = index;
      })
    }
    .width('100%')
    .height('100%')
  }
}
