import { webview } from '@kit.ArkWeb';
import { BuilderNode, NodeController, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { loadRaw } from '../common/rawfileLoader';
import { resourceManager } from '@kit.LocalizationKit';

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
}

export class DocTabCtx {
  id: number;
  kind: string; // 'home' | 'doc'
  title: string;
  url: string;
  attached: boolean = false;
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

  /** per-tab 临时文件名（多文档隔离——共享名互踩必现级 bug，2026-09-08） */
  tabPath(base: string): string {
    const dot = base.lastIndexOf('.');
    if (dot > 0) {
      return this.filesDir + '/' + base.substring(0, dot) + '.' + this.id + '.' + base.substring(dot + 1);
    }
    return this.filesDir + '/' + base + '.' + this.id;
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

/** Web 内容构建（文件级 @Builder——BuilderNode/wrapBuilder 要求） */
@Builder
function buildDocWeb(ctx: DocTabCtx) {
  Web({ src: ctx.url, controller: ctx.controller })
    .javaScriptAccess(true)
    .domStorageAccess(true)
    .fileAccess(true)
    .onInterceptRequest((event) =>
      loadRaw(event.request, ctx.resMgr!, ctx.filesDir, ((m: string) => ctx.log('[' + ctx.kind + ctx.id + '] ' + m))) as WebResourceResponse)
    .onControllerAttached(() => {
      ctx.onAttached();
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
    .width('100%')
    .height('100%')
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
  private tabsCtr: TabsController = new TabsController();
  onCloseDoc: (id: number) => void = () => {
  };
  onSwitch: (index: number) => void = () => {
  };

  build() {
    Column() {
      // —— 自绘 tab 条（紧凑 32vp；产品中性浅色系——word/cell/slide 三编辑器主题
      //   各不同色（蓝/绿/紫），固定深蓝灰与当前编辑器不协调（2026-09-08 用户指出）；
      //   浅底+官方品牌蓝胶囊与三格式/任意主题都和谐）——
      Row({ space: 6 }) {
        ForEach(this.tabs, (item: DocTabPair, index: number) => {
          Row({ space: 2 }) {
            // 切换绑定在标题文本（× 为独立兄弟节点——点击互不干扰/无冒泡）
            Text(this.titles[index])
              .fontSize(12)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.focus === index ? Color.White : '#5A6572')
              .constraintSize({ maxWidth: 200 })
              .onClick(() => {
                this.tabsCtr.changeIndex(index);
                this.focus = index;
                this.onSwitch(index);
              })
            if (item.ctx.kind === 'doc') {
              // 关闭钮：独立节点 + 大触区（≥44px 物理）；激活态时与标题同色
              Text('×')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.focus === index ? Color.White : '#9AA3AD')
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .onClick(() => {
                  this.onCloseDoc(item.ctx.id);
                })
            }
          }
          .justifyContent(FlexAlign.Center)
          .padding({ left: 12, right: 6, top: 4, bottom: 4 })
          .borderRadius(16)
          .backgroundColor(this.focus === index ? '#4B71A5' : '#E8EAEE')
          .constraintSize({ maxWidth: 320 })
        }, (item: DocTabPair) => item.ctx.kind + '-' + item.ctx.id.toString())
      }
      .width('100%')
      .height(32)
      .padding({ left: 10, right: 10 })
      .backgroundColor('#FFFFFF')

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
