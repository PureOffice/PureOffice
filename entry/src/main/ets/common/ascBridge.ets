// 桥对象：通过 WebviewController.registerJavaScriptProxy(new AscAPI(...), 'AscDesktopEditor',
//   ['getDocument','execCommand','report'], ['report']) 注入。
// JS 侧即 window.AscDesktopEditor.{getDocument,execCommand,report}。
// 与 ONLYOFFICE 桌面契约对齐：desktopinit.js 期望 window.AscDesktopEditor，
// 并且 window.desktop = window.AscDesktopEditor；Desktop.js 调 native.execCommand(...)。
// getDocument/report 为 POC 演示/诊断用（on_native_message 通道的替代原型）。
export class AscAPI {
  private doc: string;

  constructor(docJson: string) {
    this.doc = docJson;
  }

  // JS -> ArkTS 方向：getDocument 同步返回文档数据
  getDocument(): string {
    return this.doc;
  }

  // JS -> ArkTS 方向：桌面命令协议（desktopinit.js: window.desktop.execCommand('webapps:entry', ...)）
  execCommand(cmd: string, param: string): void {
    console.error('[bridge] execCommand: ' + cmd + ' param=' + param);
  }

  // JS -> ArkTS 方向：诊断通道（async 方法，JS 侧拿到 Promise）
  report(msg: string): Promise<string> {
    console.error('[bridge:report] ' + msg);
    return new Promise<string>((resolve) => {
      resolve('ok');
    });
  }
}
