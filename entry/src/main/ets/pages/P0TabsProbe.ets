import { webview } from '@kit.ArkWeb';
import { BuilderNode, NodeController, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { loadRaw } from '../common/rawfileLoader';
import { AscNativeBridge, AscNativeDispatch, AscCommandHandler } from '../common/ascBridge';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * P0 探针（2026-09-08 多文档 Tab 方案 A 的阶段0四项验证）——
 * docs/ONLYOFFICE_MULTITAB_DESIGN.md §9：多 Web 实例并存/节点复用保活/内存/
 * localStorage 跨实例/onInterceptRequest 并发。门控：ability 启动参数 p0tabs=1
 * （EditorPage 读取；产品态不挂载本组件，零变化）。
 *
 * 骨架对齐社区成熟先例（harmoninux/Harmonix 终端多 tab）：
 *   Tabs(barHeight 0, scrollable false) + ForEach(TabContent) +
 *   NodeContainer(item.node) —— 节点保活由 NodeController/BuilderNode 缓存完成
 * （makeNode 只 build 一次；切 tab 复用同一 FrameNode → Web 组件不重建）。
 *
 * 验证打点（页面 console → onConsole → web_console.txt）：
 *   P0_ALIVE_T<n>    切换后 runJavaScript 回填（页面仍在）
 *   P0_TAB<n>_PAGEEND / _CONSOLE / _QUERY  实例活动轨迹
 *   P0_LS_<键>       跨实例 localStorage 读取
 */

/** 探针消息出口（EditorPage.arkLog 同语义；日志带 [P0T<n>] 前缀区分实例） */
export type P0Log = (msg: string) => void;

/** P0 探针命令处理器（noop——探针不响应业务命令，只打点） */
class P0NoopHandler implements AscCommandHandler {
  private t: number;
  private lg: P0Log;

  constructor(t: number, log: P0Log) {
    this.t = t;
    this.lg = log;
  }

  onCommand(cmd: string, param: string, userFlag?: number): string {
    this.lg('[P0T' + this.t + '] cmd ' + cmd + ' (noop)');
    return 'true';
  }
}

/** HTML 装饰安全函数（最小转义） */
function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** 每 tab 上下文：url + 独立 WebviewController + 装配（每实例独立桥/拦截器） */
export class P0TabCtx {
  id: number = 0;
  title: string = '';
  url: string = '';
  attached: boolean = false;
  controller: webview.WebviewController = new webview.WebviewController();
  resMgr: resourceManager.ResourceManager | null = null;
  filesDir: string = '';
  log: P0Log;
  /** onControllerAttached（每实例一次）——装配逻辑对 P0 保持零依赖（handler 统一返回值） */
  onAttached: () => void;

  constructor(id: number, title: string, url: string, resMgr: resourceManager.ResourceManager,
    filesDir: string, log: P0Log) {
    this.id = id;
    this.title = title;
    this.url = url;
    this.resMgr = resMgr;
    this.filesDir = filesDir;
    this.log = log;
    this.onAttached = () => {
      if (this.attached) {
        return;
      }
      this.attached = true;
      try {
        const d = new AscNativeDispatch(this.filesDir, ((m: string) => log('[P0T' + id + '] ' + m)));
        d.setHandler(new P0NoopHandler(id, log));
        d.setRawReader((p: string) => {
          const raw = this.resMgr?.getRawFileContentSync(p);
          return raw ? (raw as Uint8Array) : null;
        });
        const b = new AscNativeBridge(d);
        this.controller.registerJavaScriptProxy(b, 'AscNative', ['_call', '_onReady'], []);
        log('[P0T' + id + '] bridge armed');
      } catch (e) {
        log('[P0T' + id + '] bridge err ' + String(e));
      }
    };
  }

  /** runJavaScript 探针（异步回填日志：P0_ALIVE 判据） */
  probe(tag: string): void {
    const js = '(function(){try{console.error('
      + '"P0_ALIVE_T' + this.id + ' ' + tag + ' rd="+document.readyState+" ls_ui="+'
      + '(localStorage.getItem("ui-theme-id")||"NULL")+" mod="+'
      + '(window.DE&&window.DE.controllers&&window.DE.controllers.Main&&window.DE.controllers.Main._state?'
      + '(window.DE.controllers.Main._state.isDocModified?"MOD":"CLEAN"):"NO_MAIN"));}catch(e){'
      + 'console.error("P0_ALIVE_T' + this.id + ' ERR "+e);}})();';
    this.controller.runJavaScript(js, (err: BusinessError, res: string) => {
      if (err) {
        this.log('[P0T' + this.id + '] probe err ' + err.code + ' ' + err.message);
      }
    });
  }
}

/** Web 内容构建（文件级 @Builder——BuilderNode/wrapBuilder 要求） */
@Builder
function buildP0Web(ctx: P0TabCtx) {
  Web({ src: ctx.url, controller: ctx.controller })
    .javaScriptAccess(true)
    .domStorageAccess(true)
    .fileAccess(true)
    .onInterceptRequest((event) =>
      loadRaw(event.request, ctx.resMgr!, ctx.filesDir, ctx.filesDir + '/media',
        ((m: string) => ctx.log('[P0T' + ctx.id + '] ' + m))) as WebResourceResponse)
    .onControllerAttached(() => {
      ctx.onAttached();
    })
    .onPageEnd(() => {
      ctx.log('[P0T' + ctx.id + '] PAGE_END ' + ctx.controller.getUrl());
    })
    .onConsole((event: OnConsoleEvent) => {
      const line = event.message.getSourceId() + ':' + event.message.getLineNumber()
        + ' ' + event.message.getMessage();
      ctx.log('[P0T' + ctx.id + '] [web] ' + line);
      return false;
    })
    .onErrorReceive((err: OnErrorReceiveEvent) => {
      ctx.log('[P0T' + ctx.id + '] Web error: ' + JSON.stringify(err));
    })
    .width('100%')
    .height('100%')
}

/** NodeController：makeNode 缓存 BuilderNode（复用=保活的机制核心） */
export class P0WebNode extends NodeController {
  private webNode: BuilderNode<[P0TabCtx]> | null = null;
  private ctx: P0TabCtx;

  constructor(ctx: P0TabCtx) {
    super();
    this.ctx = ctx;
  }

  makeNode(context: UIContext): FrameNode | null {
    if (this.webNode !== null) {
      return this.webNode.getFrameNode();
    }
    this.webNode = new BuilderNode(context);
    this.webNode.build(wrapBuilder<[P0TabCtx]>(buildP0Web), this.ctx);
    return this.webNode.getFrameNode();
  }
}

/** 探针 tab 配对：内容上下文 + 其 NodeController（节点复用载体） */
export class P0TabPair {
  ctx: P0TabCtx;
  node: P0WebNode;

  constructor(ctx: P0TabCtx) {
    this.ctx = ctx;
    this.node = new P0WebNode(ctx);
  }
}

/** P0 探针主页面：tab 条（自绘）+ Tabs 内容容器 */
@Component
export struct P0TabsProbe {
  // @Link：NodeController 为原生对象，@Prop 深拷贝会破坏节点引用（Harmonix 同型）
  @Link tabs: P0TabPair[];
  @State focusIndex: number = 0;
  private tabsCtr: TabsController = new TabsController();

  aboutToAppear(): void {
    webview.WebviewController.setWebDebuggingAccess(true);
  }

  build() {
    Column() {
      // —— 自绘 tab 条（HomeSheets 简化：标题 chip + 激活态高亮；P0 无关闭键）——
      Row({ space: 8 }) {
        ForEach(this.tabs, (item: P0TabPair, index: number) => {
          Text(esc(item.ctx.title))
            .fontSize(14)
            .fontColor(this.focusIndex === index ? Color.White : '#CCCCCC')
            .backgroundColor(this.focusIndex === index ? Color.Blue : '#444444')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(6)
            .onClick(() => {
              this.tabsCtr.changeIndex(index);
              this.focusIndex = index;
            })
            .layoutWeight(1)
        }, (item: P0TabPair) => 'p0-' + item.ctx.id.toString())
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 8 })
      .backgroundColor('#222222')

      // —— 内容容器：Tabs 只做 index 切换；保活交给 NodeController 节点复用 ——
      Tabs({ barPosition: BarPosition.Start, index: this.focusIndex, controller: this.tabsCtr }) {
        ForEach(this.tabs, (item: P0TabPair, index: number) => {
          TabContent() {
            NodeContainer(item.node)
              .width('100%')
              .height('100%')
          }
        }, (item: P0TabPair) => 'p0c-' + item.ctx.id.toString())
      }
      .scrollable(false)
      .barHeight(0)
      .layoutWeight(1)
      .onChange((index: number) => {
        this.focusIndex = index;
        // 切回时对**另一实例**打点（验证保活——被切走的不动，页面仍在）
        for (let i = 0; i < this.tabs.length; i++) {
          if (i !== index) {
            this.tabs[i].ctx.probe('switched-from-T' + index);
          }
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
