// 桥对象：通过 WebviewController.registerJavaScriptProxy(new AscAPI(...), 'Asc', ['getDocument']) 注入。
// JS 侧调用 window.Asc.getDocument()（同步返回内部格式文档 JSON 字符串）。
// POC-1 只演示桥的可通性；真实 Asc.* 方法（open/save/convert 等）在 Task 2/3 扩展。
export class AscAPI {
  private doc: string;

  constructor(docJson: string) {
    this.doc = docJson;
  }

  // JS -> ArkTS 方向：getDocument 同步返回文档数据
  getDocument(): string {
    return this.doc;
  }
}
