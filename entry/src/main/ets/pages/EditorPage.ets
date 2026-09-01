import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { AscAPI } from '../common/ascBridge';
import { loadRaw } from '../common/rawfileLoader';

@Entry
@Component
struct EditorPage {
  controller: webview.WebviewController = new webview.WebviewController();
  private resourceManager: resourceManager.ResourceManager | undefined = undefined;
  private docJson: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.resourceManager = ctx.resourceManager;
    // 同步预读内部格式文档，供 JS 侧 window.Asc.getDocument() 返回（桥演示用）
    try {
      const buf = this.resourceManager.getRawFileContentSync('onlyoffice/document.json');
      const decoder = new util.TextDecoder();
      this.docJson = decoder.decodeToString(buf);
    } catch (e) {
      console.error('read document.json failed: ' + String(e));
    }
  }

  build() {
    Column() {
      Web({ src: 'onlyoffice://editor.html', controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onInterceptRequest((event) => loadRaw(event.request, this.resourceManager!))
        .onControllerAttached(() => {
          // 注入 Asc 桥：JS 侧 window.Asc.getDocument() 同步取文档数据
          this.controller.registerJavaScriptProxy(new AscAPI(this.docJson), 'Asc', ['getDocument']);
        })
        .onPageEnd(() => {
          const js = `document.title = 'bridge:' + (typeof window.Asc === 'object' && typeof window.Asc.getDocument === 'function' ? 'ok' : 'none');`;
          this.controller.runJavaScript(js);
        })
        .onErrorReceive((err: OnErrorReceiveEvent) => {
          console.error('Web error: ' + JSON.stringify(err));
        })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
