import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { loadRaw } from '../common/rawfileLoader';
import { x2tConvertSync, x2tVersion } from '../common/x2t';

/**
 * 注册给页面 JS 的保存桥（window.AscSaveBridge.save(docy) -> Promise<number>）。
 * 页面侧 BinaryFileWriter(model).Write(false) 产出的 DOCY 串（"DOCY;v5;<len>;"+base64，
 * 与 core BinDocxRW::CDocxSerializer.loadFromFile 输入契约一致，纯 ASCII）。
 * 本端：写沙箱 in.bin（UTF-8 文本即 DOCY 原内容）→ x2t doct_bin2docx → out.docx → 校验 zip 头。
 * 转换走 fromDoctBin（CDocxSerializer，纯 C++ 无 V8）；checker 以文件头 "DOCY" 内容识别 →
 * AVS_OFFICESTUDIO_FILE_CANVAS_WORD → auto → TCD_DOCT_BIN2，扩展名不影响。
 * r 通过 asyncMethodList 走异步通道：页面端 .then 拿到 Promise 解决值。
 */
class AscSaveProxy {
  private targetPath: string;

  constructor(targetPath: string) {
    this.targetPath = targetPath;
  }

  save(docy: string): Promise<number> {
    return new Promise<number>((resolve) => {
      try {
        if (!docy || docy.length === 0) {
          console.error('SAVE_BRIDGE_EMPTY');
          resolve(0);
          return;
        }
        const dir = this.targetPath.substring(0, this.targetPath.lastIndexOf('/'));
        const inPath = dir + '/in.bin';
        // DOCY 串为纯 ASCII（签名;v版本;长度; + base64 体），writeSync(string) 按 UTF-8 写，无失真
        console.error('SAVE_BRIDGE_GOT len=' + docy.length + ' head=' + docy.substring(0, 20));
        const f = fs.openSync(inPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, docy);
        fs.closeSync(f);
        // x2t 单文件 DOCY → docx（doct_bin2docx → BinDocxRW::CDocxSerializer，纯 C++ 无 V8）
        const xml = `<Convert><m_sFileFrom>${inPath}</m_sFileFrom><m_sFileTo>${this.targetPath}</m_sFileTo></Convert>`;
        const rc = x2tConvertSync(xml);
        console.error('SAVE_BRIDGE_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
        if (rc !== 0) {
          resolve(-1);
          return;
        }
        // 校验 out.docx zip 头（0x50 0x4b）
        const st = fs.statSync(this.targetPath);
        const o = fs.openSync(this.targetPath, fs.OpenMode.READ_ONLY);
        const mkBuf = new ArrayBuffer(4);
        fs.readSync(o.fd, mkBuf);
        fs.closeSync(o);
        const mk = new Uint8Array(mkBuf);
        console.error('SAVE_BRIDGE_OUT size=' + st.size + ' mk=0x'
          + mk[0].toString(16).padStart(2, '0') + mk[1].toString(16).padStart(2, '0')
          + (mk[0] === 0x50 && mk[1] === 0x4b ? ' zipok' : ' ZIPBAD'));
        resolve(docy.length);
      } catch (e) {
        console.error('SAVE_BRIDGE_ERR ' + String(e));
        resolve(-1);
      }
    });
  }
}

/** base64 → ArrayBuffer（ArkTS 无内置解码；页面 docx 字节经 bridge 上行） */
function b64ToBuf(b64: string): ArrayBuffer {
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const clean = b64.replace(/[^A-Za-z0-9+/=]/g, '');
  let n = clean.indexOf('=');
  if (n < 0) {
    n = clean.length;
  }
  const pad = n % 4;
  const bytes = Math.floor(n / 4) * 3 + (pad === 2 ? 1 : pad === 3 ? 2 : 0);
  const out = new Uint8Array(bytes);
  let bi = 0;
  for (let i = 0; i < n; i += 4) {
    const c1 = B64.indexOf(clean.charAt(i));
    const c2 = B64.indexOf(clean.charAt(i + 1));
    const c3 = (i + 2 < n) ? B64.indexOf(clean.charAt(i + 2)) : 0;
    const c4 = (i + 3 < n) ? B64.indexOf(clean.charAt(i + 3)) : 0;
    const ch = (c1 << 18) | (c2 << 12) | (c3 << 6) | c4;
    out[bi++] = (ch >> 16) & 0xFF;
    if (bi < bytes) {
      out[bi++] = (ch >> 8) & 0xFF;
    }
    if (bi < bytes) {
      out[bi++] = ch & 0xFF;
    }
  }
  return out.buffer.slice(0, bytes);
}

/**
 * ArrayBuffer → base64（与 b64ToBuf 互逆）。
 * DOCY v10 为 raw 二进制（含 \x00 等字节），字符串直传经 runJavaScript 会损坏
 * （实测页面 FNV 与磁盘不符），base64 纯 ASCII 传输无损，页面侧 atob 还原。
 */
function bufToB64(ab: ArrayBuffer): string {
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const u8 = new Uint8Array(ab);
  let out = '';
  for (let i = 0; i < u8.length; i += 3) {
    const b1 = u8[i];
    const b2 = i + 1 < u8.length ? u8[i + 1] : -1;
    const b3 = i + 2 < u8.length ? u8[i + 2] : -1;
    out += B64.charAt(b1 >> 2);
    out += B64.charAt(((b1 & 3) << 4) | (b2 >= 0 ? (b2 >> 4) : 0));
    out += b2 >= 0 ? B64.charAt(((b2 & 15) << 2) | (b3 >= 0 ? (b3 >> 6) : 0)) : '=';
    out += b3 >= 0 ? B64.charAt(b3 & 63) : '=';
  }
  return out;
}

/**
 * 注册给页面 JS 的打开桥（window.AscConvertBridge.convertDocxToDocy(b64docx)）。
 * 页面 openDocument 钩子发现 PK(docx) 字节 → 本端：写沙箱 open-in.docx →
 * x2t docx2doct_bin（TCD_DOCX2DOCT_BIN，.bin 后缀自动分派；DOCY;v10;0;+raw 二进制）
 * → open-in.bin → base64 读回 → runJavaScript 回调页面 window.__oobDocy
 * → 页面 e.openDocument({bSerFormat:true, data:Uint8Array}) → BinaryFileReader 直读 DOCY
 * （Web 构建 OpenDocumentFromZip 的 CDocument.fromZip 在官方源码树也无定义，此路绕开；
 *  页面入口用 Uint8Array 输入路径，与 DocumentServer 前端 HTTP 下载形态一致）。
 */
class AscConvertProxy {
  private controller: webview.WebviewController;
  private dir: string;

  constructor(controller: webview.WebviewController, filesDir: string) {
    this.controller = controller;
    this.dir = filesDir;
  }

  convert(b64: string, ext: string): number {
    try {
      if (!b64 || b64.length === 0) {
        console.error('CONV_BRIDGE_EMPTY');
        return 0;
      }
      const ab = b64ToBuf(b64);
      const extSafe = (ext === 'xlsx' || ext === 'pptx') ? ext : 'docx';
      const inDocx = this.dir + '/open-in.' + extSafe; // 后缀决定 x2t 转换器（docx/xlsx/pptx -> *_bin）
      const inBin = this.dir + '/open-in.bin';
      const f = fs.openSync(inDocx, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, ab);
      fs.closeSync(f);
      const xml = `<Convert><m_sFileFrom>${inDocx}</m_sFileFrom><m_sFileTo>${inBin}</m_sFileTo></Convert>`;
      const rc = x2tConvertSync(xml);
      console.error('CONV_BRIDGE_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        console.error('CONV_BRIDGE_FAIL rc=' + rc);
        this.controller.runJavaScript('window.__oobDocy && window.__oobDocy(null)', () => {
        });
        return -1;
      }
      const st = fs.statSync(inBin);
      const o = fs.openSync(inBin, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(st.size);
      fs.readSync(o.fd, buf);
      fs.closeSync(o);
      const docyB64 = bufToB64(buf);
      console.error('CONV_BRIDGE_OK bin=' + st.size + ' b64=' + docyB64.length);
      this.controller.runJavaScript('window.__oobDocy && window.__oobDocy(' + JSON.stringify(docyB64) + ')',
        (err: BusinessError, res: string) => {
          if (err) {
            console.error('CONV_BRIDGE_CB_ERR ' + err.code + ' ' + err.message);
          }
        });
      return 1;
    } catch (e) {
      console.error('CONV_BRIDGE_ERR ' + String(e));
      return -1;
    }
  }
}

@Entry
@Component
struct EditorPage {
  controller: webview.WebviewController = new webview.WebviewController();
  private resourceManager: resourceManager.ResourceManager | undefined = undefined;
  private savePath: string = '';
  private ascSaveProxy: AscSaveProxy = new AscSaveProxy('');
  private ascConvertProxy: AscConvertProxy | undefined = undefined;
  private hostFilesDir: string = '';
  private probePath: string = '';
  private webLogPath: string = '';
  private probeTimer: number = -1;
  // 真机自动验证驱动（迭代1闭环自检）；正式产品入口为壳层按钮，可置 false
  private autoTest: boolean = true;

  // 状态探针（诊断通道，不依赖 hilog）：每 2s 读页面 DOM 标记/模型就绪 → 沙箱 probe.txt。
  //   页面侧标记由 index.html 探针（data-gi/go/lm/...）维护；model 存在性 = 文档打开完成。
  private startProbe(): void {
    if (this.probeTimer >= 0) {
      return;
    }
    this.probeTimer = setInterval(() => {
      const snap = "(function(){var g=document.documentElement;var e=window.Asc&&(window.Asc.editor||window.editor);" +
        "var m=e&&e.WordControl?!!e.WordControl.m_oLogicDocument:false;" +
        "var surl='-';try{surl=e&&e.CoAuthoringApi&&e.CoAuthoringApi._CoAuthoringApi?String(e.CoAuthoringApi._CoAuthoringApi._url):'-';}catch(x){surl='E';}" +
        "var diof='-';try{diof=e&&e.DocInfo?String(e.DocInfo.get_OfflineApp()):'-';}catch(x){diof='E';}" +
        "return JSON.stringify({fet:g.getAttribute('data-fet'),xhr:g.getAttribute('data-xhr'),xhr2:g.getAttribute('data-xhr2')," +
        "dl:g.getAttribute('data-dl'),gi:g.getAttribute('data-gi'),go:g.getAttribute('data-go')," +
        "dr:g.getAttribute('data-dr'),dcl:g.getAttribute('data-dcl'),rs:document.readyState," +
        "lb:g.getAttribute('data-lb'),lc:g.getAttribute('data-lc'),lm:g.getAttribute('data-lm'),model:m," +
        "msgepOK:g.getAttribute('data-msgepOK'),msgeprr:(g.getAttribute('data-msgeprr')||'-').slice(0,200)," +
        "moep:g.getAttribute('data-moep'),moepLic:g.getAttribute('data-moepLic'),moepLicERR:(g.getAttribute('data-moepLicERR')||'').slice(0,120)," +
        "mld2:g.getAttribute('data-mld2'),mld2OK:g.getAttribute('data-mld2OK'),mld2ERR:(g.getAttribute('data-mld2ERR')||'').slice(0,200)," +
        "surl:surl,diof:diof,mload:g.getAttribute('data-mload')," +
        "pf:(window.__pf||[]).join('|').slice(0,2000)," +
        "pfTail:(window.__pf||[]).join('|').slice(-400)," +
        "pages:(function(){var e=window.Asc&&(window.Asc.editor||window.editor);if(!e||!e.WordControl||!e.WordControl.m_oLogicDocument){return '-';}var d=e.WordControl.m_oLogicDocument;var pc=0;try{pc=d.Get_PagesCount?d.Get_PagesCount():-1;}catch(x){pc='E';}var p1=0;try{var dr=e.WordControl.m_oDrawingDocument; p1=(dr&&dr.pages&&dr.pages.length)||(dr&&dr.m_oPages&&dr.m_oPages.length)||0;}catch(x){p1='E';}var mx=-1,tx='-';try{var o=d.Objects;if(o){if(o instanceof Array){mx=o.length;}else{var k=0;for(var q in o){k++;}mx=k;}}}catch(x){mx='E';}tx='-';return JSON.stringify({pc:pc,pr:p1,ld:d.IsLoadingDocument?d.IsLoadingDocument():'-',mx:mx,tx:tx});})(),drk:(function(){var e=window.Asc&&(window.Asc.editor||window.editor);var dr=e&&e.WordControl?e.WordControl.m_oDrawingDocument:null;if(!dr){return '-';}var k=[];for(var q in dr){if(/page|draw|canvas|view|redraw|recalc|paint/i.test(q)){k.push(q+':'+(dr[q]&&dr[q].length!==undefined?dr[q].length:typeof dr[q]));}}return k.join('|');})(),dom:(function(){var out={css:document.styleSheets.length,bg:'',canv:[],sk:''};try{out.bg=getComputedStyle(document.body).backgroundColor;}catch(x){}try{out.canv=[].slice.call(document.querySelectorAll('canvas')).slice(0,6).map(function(c){try{var st=getComputedStyle(c);return c.width+'x'+c.height+'/'+st.display+st.visibility+':'+st.cssWidth;}catch(x){return 'E';}});}catch(x){}try{var l=document.querySelector('#editor-loading,#id-loading,.loading,html[data-loading]');out.sk=l?String((l||{}).id||(l.className||'')).slice(0,40):'-';}catch(x){}return JSON.stringify(out);})()," +
        "title:document.title," +
        "cell:(function(){var e9=window.Asc&&(window.Asc.editor||window.editor);if(!e9){return '-';}var out={};try{out.wb=e9.wb?'obj':'nil';}catch(x){out.wb='E';}try{out.wbn=e9.wb&&e9.wb.wsViews?Object.keys(e9.wb.wsViews).length:0;}catch(x){out.wbn='E';}try{out.zm=e9.wb&&e9.wb.defaults&&e9.wb.defaults.worksheetView?e9.wb.defaults.worksheetView.zoom:-1;}catch(x){out.zm='E';}try{out.ctrl=e9.controller?'obj':'nil';}catch(x){out.ctrl='E';}try{var cv=document.getElementById('editor_sdk');out.sdk=cv?(cv.offsetWidth+'x'+cv.offsetHeight):'nil';}catch(x){out.sdk='E';}try{var cw=document.getElementById('ws-canvas');out.cw=cw?(cw.offsetWidth+'x'+cw.offsetHeight):'nil';}catch(x){out.cw='E';}return JSON.stringify(out);})()," +
        "tag:(document.body?document.body.innerText.substring(0,120):'')});})()";
      this.controller.runJavaScript(snap, (err: BusinessError, res: string) => {
        if (!err && res && res !== '') {
          try {
            const f = fs.openSync(this.probePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
            fs.writeSync(f.fd, new Date().toLocaleTimeString() + ' ' + res);
            fs.closeSync(f);
          } catch (e) {
            // 探针写失败不影响主流程
          }
        }
      });
    }, 2000);
  }

  // —— 正式壳层功能：页面侧 window.OOHost（open/mark/save）统一驱动入口 ——
  private pageJS(fn: string): void {
    this.controller.runJavaScript(fn, (err: BusinessError, res: string) => {
      if (err) {
        console.error('OOH_SHELL ' + fn.substring(0, 40) + ' ERR ' + err.code + ' ' + err.message);
      }
    });
  }

  /** 当前编辑器文件类型（docx/xlsx/pptx）；决定页面（editor 应用目录）与转换桥后缀 */
  private docType: string = 'docx';

  private openSandbox(type?: string): void {
    const t = type || this.docType;
    // 真文件打开：userfile/ 前缀由 rawfileLoader 从沙箱 filesDir 读取（样本由 copySandboxSamples 同步）
    this.pageJS("OOHost.open('http://localhost/userfile/sample." + t + "?v=' + Date.now())");
  }

  private editorUrl(type: string): string {
    const app = type === 'xlsx' ? 'spreadsheeteditor'
      : type === 'pptx' ? 'presentationeditor' : 'documenteditor';
    return 'http://localhost/onlyoffice/webapps/apps/' + app + '/main/index.html?v=54&docType=' + type;
  }

  /** 切换编辑器页面（word/xlsx/pptx 各一）并更新当前文件类型 */
  private openEditorPage(type: string): void {
    this.docType = type;
    this.controller.loadUrl(this.editorUrl(type));
  }

  private markDoc(): void {
    this.pageJS('OOHost.mark()');
  }

  private saveDoc(): void {
    this.pageJS('OOHost.save()');
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.resourceManager = ctx.resourceManager;
    this.hostFilesDir = ctx.filesDir;
    this.savePath = ctx.filesDir + '/save.docx';
    this.probePath = ctx.filesDir + '/probe.txt';
    this.webLogPath = ctx.filesDir + '/web_console.txt';
    try {
      const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(f); // 每次启动清空 web 日志（避免无限增长/读旧日志）
    } catch (e) {
      // 忽略
    }
    this.copySandboxSamples(); // 样本 docx/xlsx/pptx：rawfile → 沙箱 filesDir（userfile/ 链路；外部 hdc push 受 DAC 拒）
    this.tryNativeSaveStep1(); // 临时 POC item1：native x2t docx->docx 保存转换实锤（验证后撤）
    // 探针在 WebController 就绪后启动（onControllerAttached 里保底 startProbe）
  }

  /** rawfile 样本复制到沙箱 filesDir（open 链走 userfile/ 前缀；编辑/转换产物也在 filesDir） */
  private copySandboxSamples(): void {
    if (!this.resourceManager) {
      return;
    }
    for (const name of ['sample.docx', 'sample.xlsx', 'sample.pptx']) {
      try {
        const raw = this.resourceManager.getRawFileContentSync('onlyoffice/' + name) as Uint8Array;
        const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        const f = fs.openSync(this.hostFilesDir + '/' + name, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, ab);
        fs.closeSync(f);
      } catch (e) {
        console.error('SAMPLE_COPY_ERR ' + name + ' ' + String(e));
      }
    }
  }

  // 临时 POC item1：native x2t 把沙箱 docx 重序列化为 docx（保存=转换），真机验证 rc=0 + zip 头。
  // 输入为原始 rawfile 文档（非编辑内容），仅证明 native x2t 转换核心对 docx->docx 真机可用。
  // 走格式库重序列化，不依赖 V8（docx->PDF 那类 doctrenderer 依赖才卡）。
  private tryNativeSaveStep1(): void {
    const dir = this.savePath.substring(0, this.savePath.lastIndexOf('/'));
    const inPath = dir + '/in.docx';
    const outPath = dir + '/out.docx';
    // A: 读 rawfile 原始 docx（Word 2007+ zip，27128B/PK 头），规整为干净 ArrayBuffer。
    //    getRawFileContentSync 在部分 SDK 返回 Uint8Array；writeSync 拒 Uint8Array（POC-2 坑），
    //    故此处统一规整：Uint8Array -> 拷贝其底层 buffer 的干净 ArrayBuffer。
    let rawAb: ArrayBuffer = new ArrayBuffer(0);
    try {
      // getRawFileContentSync 真机返回 Uint8Array（rawfileLoader 同款用法）；writeSync 拒 Uint8Array，
      // 故参照 rawfileLoader 规整为精确长度 ArrayBuffer 再写。
      const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/document.docx') as Uint8Array;
      rawAb = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      console.error('X2T_A_GET len=' + rawAb.byteLength);
    } catch (e) {
      console.error('X2T_A_ERR ' + String(e));
      return;
    }
    // B: 写沙箱 in.docx
    try {
      const f = fs.openSync(inPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      const n = fs.writeSync(f.fd, rawAb);
      fs.closeSync(f);
      console.error('X2T_B_WRITE n=' + n + ' ver=' + x2tVersion());
    } catch (e) {
      console.error('X2T_B_ERR ' + String(e));
      return;
    }
    // C: x2t docx->docx（重序列化，走格式库不依赖 V8）
    try {
      const xml = `<Convert><m_sFileFrom>${inPath}</m_sFileFrom><m_sFileTo>${outPath}</m_sFileTo></Convert>`;
      const rc = x2tConvertSync(xml);
      console.error('X2T_C_RC 0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
    } catch (e) {
      console.error('X2T_C_ERR ' + String(e));
      return;
    }
    // D: 验证 out.docx zip 头（0x50 0x4b）
    try {
      const st = fs.statSync(outPath);
      const o = fs.openSync(outPath, fs.OpenMode.READ_ONLY);
      const mkBuf = new ArrayBuffer(4);
      fs.readSync(o.fd, mkBuf);
      fs.closeSync(o);
      const mk = new Uint8Array(mkBuf);
      const zipOk = (mk[0] === 0x50 && mk[1] === 0x4b);
      console.error('X2T_D_OUT size=' + st.size + ' mk=0x' + mk[0].toString(16).padStart(2, '0')
        + mk[1].toString(16).padStart(2, '0') + ' zip=' + zipOk);
    } catch (e) {
      console.error('X2T_D_ERR ' + String(e));
    }
  }

  build() {
    Column() {
      // 壳层工具条（正式功能入口，逐轮替代探针自动执行）：
      Row({ space: 8 }) {
        Text('OO 文档编辑器 (POC→MVP)').fontSize(14).fontColor('#333').margin({ left: 8 })
        Button('sample.docx', { type: ButtonType.Normal })
          .fontSize(13).backgroundColor('#2563eb').fontColor(Color.White)
          .onClick(() => this.openEditorPage('docx'))
        Button('sample.xlsx', { type: ButtonType.Normal })
          .fontSize(13).backgroundColor('#2563eb').fontColor(Color.White)
          .onClick(() => this.openEditorPage('xlsx'))
        Button('sample.pptx', { type: ButtonType.Normal })
          .fontSize(13).backgroundColor('#2563eb').fontColor(Color.White)
          .onClick(() => this.openEditorPage('pptx'))
        Button('打开', { type: ButtonType.Normal })
          .fontSize(13).backgroundColor('#0369a1').fontColor(Color.White)
          .onClick(() => this.openSandbox())
        Button('标记', { type: ButtonType.Normal })
          .fontSize(13).backgroundColor('#059669').fontColor(Color.White)
          .onClick(() => this.markDoc())
        Button('保存', { type: ButtonType.Normal })
          .fontSize(13).backgroundColor('#d97706').fontColor(Color.White)
          .onClick(() => this.saveDoc())
      }
      .width('100%').height(40).backgroundColor('#f1f5f9')

      // 注意：?v=N 是对 ArkWeb http cache 的 cache-bust——rawfileLoader 已剥离 query，
      // 每次提升版本号强制再次取新页面（此 SDK 无 webview.CacheMode 枚举）。
      // 初始页面按当前 docType（以后可改为 @State 响应式，当前用 loadUrl 切换）。
      Web({ src: this.editorUrl(this.docType), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onInterceptRequest((event) => loadRaw(event.request, this.resourceManager!, this.hostFilesDir))
        .onControllerAttached(() => {
          // 注意：不注入 AscDesktopEditor——sdk 初始化检测 window.AscDesktopEditor 决定走桌面还是
          // web 路径（apiBase.js:_init），桌面路径要求 CreateEditorApi（native 负责），
          // WebView 场景必须走 web 路径（当前真机已验证 web 路径可渲染）。
          // 这里只注册保存桥：让页面 JS 经 runJavaScript/saveLogicDocumentToZip 产出的 zip 字节
          // 通过 window.AscSaveBridge.save(b64) 回传 ArkTS 写沙箱，构成「编辑→保存」纯 JS 闭环。
          // 注意：registerJavaScriptProxy 注册的对象要到页面 (re)load 才出现在 window，
          // 故在 onControllerAttached（早于加载）注册才对本页生效。
          this.ascSaveProxy = new AscSaveProxy(this.savePath);
          this.controller.registerJavaScriptProxy(this.ascSaveProxy, 'AscSaveBridge', [], ['save']);
          // 打开桥：docx/xlsx/pptx(PK) → x2t *_bin → DOCY/XLSY/PPTY → 页面 OpenDocumentFromBin（打开弧）
          this.ascConvertProxy = new AscConvertProxy(this.controller, this.hostFilesDir);
          this.controller.registerJavaScriptProxy(this.ascConvertProxy, 'AscConvertBridge', [], ['convert']);
          this.startProbe(); // 页面 DOM 就绪后开始状态探针（写 probe.txt）
        })
        .onPageEnd(() => {
          // 用 console.error 而非 console.log：I 级日志随 app 切后台被丢弃，E 级稳定（与页面 [web] 同通道）
          console.error('PAGE_END url=' + this.controller.getUrl());
          // 迭代1（正式功能化）：注入 window.OOHost 页面功能库（open/mark/save）。
          //   POC-5「编辑→保存」全开源链从探针改为正式页面 API，由 ArkTS 壳层按钮驱动：
          //     OOHost.open(fileUrl)   re-postMessage openDocument（Gateway→Main.js loadDocument→asc_LoadDocument）
          //     OOHost.mark()          asc_AddText('OOH-<ts>') 编辑标记（验证「编辑」进成品）
          //     OOHost.save()          BinaryFileWriter(模型).Write(false)→DOCY;v5; → AscSaveBridge.put
          //   autoTest=true（当前真机验证期）：等模型就绪后自动走 打开→标记→保存 串行（按钮路径的同一函数）。
          const inject = `(function(){
if(window.__ooh_installed){return;}
window.__ooh_installed=true;
// XHR 自测（模拟 sdkjs asc_ajax 文档下载：GET + responseType=arraybuffer）。
//   data-xhr=userfile 测试（沙箱真文件）；data-xhr2=拦截链对照。
//   区分「XHR×拦截器不兼容」vs「编辑器下载链问题」。
var xhrTest=function(url,tag){
  try{
    var x=new XMLHttpRequest();
    x.open('GET',url,true);
    x.responseType='arraybuffer';
    x.onload=function(){document.documentElement.setAttribute('data-'+tag,
      JSON.stringify({ok:1,status:x.status,size:x.response?x.response.byteLength:-1}));};
    x.onerror=function(){document.documentElement.setAttribute('data-'+tag,JSON.stringify({ok:0,err:'onerror'}));};
    var guard=setTimeout(function(){if(x.readyState<4){try{x.abort();}catch(e){}}
      document.documentElement.setAttribute('data-'+tag,JSON.stringify({ok:0,err:'hang',rs:x.readyState}));},15000);
    x.onloadend=function(){clearTimeout(guard);};
    x.send(null);
  }catch(e){document.documentElement.setAttribute('data-'+tag,JSON.stringify({ok:0,err:String(e)}));}
};
xhrTest('http://localhost/userfile/sample.docx?v='+Date.now(),'xhr');
xhrTest('http://localhost/onlyoffice/document.docx?v='+Date.now(),'xhr2');
var getModel=function(){
  var e=window.Asc&&(window.Asc.editor||window.editor);
  if(!e||!e.WordControl){return null;}
  return e.WordControl.m_oLogicDocument;
};
window.OOHost={
  // 打开链（直连 API，不经 Gateway/coauth——Gateway 路线触发 CoAuthoringDisconnect 实测）：
  // 页面 fetch 沙箱文档字节 → e.openDocument({data:Uint8Array(PK)}) → hook 转 x2t → Uint8Array 打开。
  // 打开链 v3：XHR 取 PK 字节 → postMessage openDocumentFromBinary（Gateway loadBinary
  // = api.asc_openDocumentFromBytes(Uint8Array)）→ hook 拦 PK → x2t(*_bin) → __oobDocy
  // Uint8Array 打开。Gateway 命令走 loadBinary 不经 docInfo.url（不触发在线 coauth），
  // 且 loadDocument(_offline_) 已在 launch 建好 UI 链（toolbar）。
  gwTest:function(){
    // Gateway 分发诊断：手动发 openDocumentFromBinary（min PK 头）看 loadBinary 是否命中
    try{
      var pk=[0x50,0x4b,0x03,0x04,0x14,0x00,0x06,0x00];
      window.postMessage(JSON.stringify({command:'openDocumentFromBinary', data:pk}),'*');
      window.__pf.push('GW:testsent');
    }catch(e){window.__pf.push('GW:testERR:'+String(e));}
  },
  open:function(fileUrl){
    try{
      var x=new XMLHttpRequest();
      x.open('GET',fileUrl,true);
      x.responseType='arraybuffer';
      x.onload=function(){
        if(!x.response||!x.response.byteLength){console.error('OOH_OPEN_EMPTY');return;}
        try{
          var u8=new Uint8Array(x.response);
          var arr=Array.prototype.slice.call(u8);
          // 数据必须包成 {bytes:arr} 对象：Gateway commandMap = $me.trigger('xxx', data)，
          // jQuery.trigger 会把「数组」展开为多参数 → loadBinary 只收到数组首元素
          // （实测 type=[object Number]，字节全灭）。对象包装不展开。
          window.postMessage({command:'openDocumentFromBinary', data:{bytes:arr}},'*');
          console.error('OOH_OPENED_BIN len='+u8.length);
        }catch(xx){console.error('OOH_OPEN_ERR '+String(xx));}
      };
      x.onerror=function(){console.error('OOH_OPEN_NETERR');};
      x.send(null);
    }catch(x){console.error('OOH_OPEN2_ERR '+String(x));}
  },
  mark:function(){
    try{
      var e=window.Asc&&(window.Asc.editor||window.editor);
      var m=getModel();
      if(!m){console.error('OOH_MARK_NOMODEL');return;}
      var tag='OOH-'+Date.now();
      e.asc_AddText(tag);
      console.error('OOH_MARKED '+tag);
    }catch(x){console.error('OOH_MARK_ERR '+String(x));}
  },
  save:function(){
    try{
      var m=getModel();
      if(!m){console.error('OOH_SAVE_NOMODEL');return;}
      if(!window.native){window.native={Save_End:function(){}};}
      // 按编辑器类型选序列化器：word=BinaryFileWriter(DOCY)；xlsx=cell 版；pptx=BinaryPPTYWriter（如有）
      var w=null;
      if(window.AscCommonWord&&window.AscCommonWord.BinaryFileWriter){w=new AscCommonWord.BinaryFileWriter(m);}
      else if(window.AscCommonExcel&&window.AscCommonExcel.BinaryFileWriter){w=new AscCommonExcel.BinaryFileWriter(m);}
      else {console.error('OOH_SAVE_NOWRITER');return;}
      var docy=w.Write(false);
      console.error('OOH_DOCY len='+docy.length+' head='+docy.substring(0,24));
      window.AscSaveBridge.save(docy);
    }catch(x){console.error('OOH_SAVE_ERR '+String(x));}
  },
  forcePaint:function(){
    try{
      var e=window.Asc&&(window.Asc.editor||window.editor);
      if(!e){try{window.__pf.push('paint:noe');}catch(x){}return;}
      // 尺寸修正链：初始 #editor 容器可能为 0x0（CSS 未就绪时测尺寸）→ canvas 0x0 白页；
      // OnResize(true) 按容器重建 canvas 并全量重绘（等价官方 resize 事件入口）
      try{if(e.Resize)e.Resize();}catch(z0){}
      try{var wc=e.WordControl;if(wc&&wc.OnResize){wc.OnResize(true);}}catch(z1){}
      try{if(e.asc_setZoom)e.asc_setZoom(1);}catch(z){}
      try{window.__pf.push('paint:Resize');}catch(x){}
    }catch(x){}
  }
};
console.error('OOH_INSTALLED auto='+!!window.__ooh_autotest);
// 页面级错误采集：app 初始化失败时 onerror/unhandledrejection 是最直接证据
try{
  var _er0=window.onerror;
  window.onerror=function(msg,src,ln,cl,err){try{window.__pf.push('ERR:'+String(msg).slice(0,120)+'@'+String(src||'').slice(-40)+':'+ln);}catch(x){}if(_er0)return _er0.apply(this,arguments);return false;};
  window.addEventListener('unhandledrejection',function(ev){try{window.__pf.push('UHR:'+String(ev.reason&&ev.reason.message||ev.reason).slice(0,120));}catch(x){}});
}catch(e){}
if(window.__ooh_autotest){
  try{window.__pf.push('AT:on dt='+(window.__ooh_docType||'?'));}catch(e){}
  // 自动验证驱动（无 getModel 轮询——模型就绪由页面稳定时序覆盖）：
  // launch 空文档完成 (~5s) 后 open 真文件（PK→x2t→Uint8Array），再 标记→保存。
  setTimeout(function(){
    // hook 状态自查（open chain 前置诊断：openDocument 是否已被 hook / Gateway 是否可分发）
    try{
      var e4=window.Asc&&(window.Asc.editor||window.editor);
      console.error('HK:'+(e4?(e4._podd2?1:'0'):'noe')+(window.Asc&&window.Asc.editor?'/A':'/a')+(window.editor?'/W':'/w'));
    }catch(e){console.error('HKERR:'+String(e));}
    // gwTest 已撤（8 字节零数据触发 cell 解析错误弹窗，污染诊断）
  },5000);
  setTimeout(function(){
    // loading-mask 验证：官方 Main.js 在 layout:changed 后移除；若 app 初始化未完成会一直遮罩
    try{var lm=document.getElementById('loading-mask');if(lm){lm.parentNode.removeChild(lm);window.__pf.push('mask:removed');}}catch(e){}
    try{window.__pf.push('AT:open-start');}catch(e){}
    window.OOHost.open('http://localhost/userfile/sample.'+(window.__ooh_docType||'docx')+'?v='+Date.now());
  },9000);
  setTimeout(function(){ window.OOHost.mark(); },14500);
  setTimeout(function(){ window.OOHost.save(); },17500);
  // canvas 渲染诊断：模型已载但画布空白时，强制 repaint（zoom/sel 触发重绘）观察是否恢复
  setTimeout(function(){ window.OOHost.forcePaint(); },19500);
  try{window.__pf.push('AT:kick dt='+(window.__ooh_docType||'docx'));}catch(e){}
  console.error('OOH_TEST_KICKED dt='+(window.__ooh_docType||'docx'));
}
})();`;
          if (this.autoTest) {
            // 验证驱动开：先注入 autotest 标志 + 当前文件类型（页面轮询等模型就绪），再注入功能库
            this.pageJS('window.__ooh_autotest=true;window.__ooh_docType="' + this.docType + '";' + inject);
          } else {
            this.pageJS(inject);
          }
        })
        .onErrorReceive((err: OnErrorReceiveEvent) => {
          console.error('Web error: ' + JSON.stringify(err));
        })
        .onConsole((event: OnConsoleEvent) => {
          const line = event.message.getSourceId() + ':' + event.message.getLineNumber()
            + ' ' + event.message.getMessage();
          console.error('[web] ' + line);
          // 诊断：web 控制台全量落设备文件（hilog 抓取在部分环境不可用，文件最可靠）
          try {
            const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
            fs.writeSync(f.fd, line + '\n');
            fs.closeSync(f);
          } catch (e) {
            // 日志落盘失败不影响主流程
          }
          return false;
        })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
