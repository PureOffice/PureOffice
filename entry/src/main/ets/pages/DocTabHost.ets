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

export class DocTabCtx {
  id: number;
  kind: string; // 'home' | 'doc'
  title: string;
  url: string;
  attached: boolean = false;
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
  private tabsCtr: TabsController = new TabsController();
  onCloseDoc: (id: number) => void = () => {
  };
  onSwitch: (index: number) => void = () => {
  };

  build() {
    Column() {
      // —— 自绘 tab 条 ——
      Row({ space: 8 }) {
        ForEach(this.tabs, (item: DocTabPair, index: number) => {
          Row({ space: 4 }) {
            // 切换绑定在标题文本（× 为独立兄弟节点——点击互不干扰/无冒泡）
            Text(item.ctx.kind === 'home' ? '主页' : item.ctx.title)
              .fontSize(14)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.focus === index ? Color.White : '#CCCCCC')
              .constraintSize({ maxWidth: 240 })
              .onClick(() => {
                this.tabsCtr.changeIndex(index);
                this.focus = index;
                this.onSwitch(index);
              })
            if (item.ctx.kind === 'doc') {
              // 关闭钮：独立节点 + 大触区（矩形 >=40x40 物理）
              Text('×')
                .fontSize(16)
                .fontColor(this.focus === index ? Color.White : '#999999')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  this.onCloseDoc(item.ctx.id);
                })
            }
          }
          .justifyContent(FlexAlign.Center)
          .padding({ left: 14, right: 8, top: 6, bottom: 6 })
          .borderRadius(6)
          .backgroundColor(this.focus === index ? Color.Blue : '#444444')
          .constraintSize({ maxWidth: 340 })
        }, (item: DocTabPair) => item.ctx.kind + '-' + item.ctx.id.toString())
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 8 })
      .backgroundColor('#222222')

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
