import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { loadRaw } from '../common/rawfileLoader';
import { x2tConvertSync, x2tVersion } from '../common/x2t';
import { AscNativeBridge, AscNativeDispatch, AscCommandHandler } from '../common/ascBridge';

/** 页面 cache-bust：每次 rawfile 变更后递增（override rawfileLoader 剥离 query 的缓存） */
const VERSION_BUMP = 59;

/** 桌面命令处理器：loginpage sdk.command/open:recent → EditorPage 业务动作 */
class ShellCommandHandler implements AscCommandHandler {
  private owner: EditorPage;

  constructor(owner: EditorPage) {
    this.owner = owner;
  }

  onCommand(cmd: string, param: string): string {
    return this.owner.onShellCommand(cmd, param);
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

@Entry
@Component
struct EditorPage {
  controller: webview.WebviewController = new webview.WebviewController();
  private resourceManager: resourceManager.ResourceManager | undefined = undefined;
  private ascNative: AscNativeBridge | undefined = undefined;
  private hostFilesDir: string = '';
  private webLogPath: string = '';
  // —— 官方打开链（M3）暂存：open:recent → x2t → base64，等页面 LocalStartOpen() 就绪注入 ——
  private pendingOpenBase64: string = '';
  private pendingOpenLen: number = 0;
  private pendingOpenUrl: string = '';
  private pendingOpenName: string = '';
  // 当前打开文档名（M4 保存回写源文件用；不随 pendingOpenName 一次性清除）
  private currentOpenName: string = '';

  // —— 页面注入入口（runJavaScript）——
  private pageJS(fn: string): void {
    this.controller.runJavaScript(fn, (err: BusinessError, res: string) => {
      if (err) {
        console.error('OOH_SHELL ' + fn.substring(0, 40) + ' ERR ' + err.code + ' ' + err.message);
      }
    });
  }

  /** 当前编辑器文件类型（docx/xlsx/pptx）；决定页面（editor 应用目录）与转换桥后缀 */
  private docType: string = 'docx';
  /** 桌面链：true 时初始页 = 官方 loginpage 欢迎页；false 回退 POC 直接编辑器测试页 */
  private useDesktopHome: boolean = true;

  /** 官方欢迎页（loginpage）：欢迎/最近文件列表 + 新建卡片 */
  private homeUrl(): string {
    return 'http://localhost/onlyoffice/index.html?v=' + VERSION_BUMP;
  }

  /**
   * 编辑器页 URL —— 官方编辑器应用页（apps/<app>/main/index.html，顶层加载；
   * POC 打开链 v12 真机成功渲染的页面/构建组合）。页面经 Gateway init 后接收
   * openDocumentFromBinary 字节（官方 api.js/Gateway/loadBinary 链）。
   * 注：官方面向 API 调用方的桌面壳页（api/documents/index.html + iframe）组合已实测
   * 到 openDocument 前链；引擎模型初始化依赖 B 架构运行时序，本阶段以顶层页打开（后续 M4+ 返回 iframe 结构）。
   */
  private editorUrl(type: string, title: string): string {
    const app = type === 'xlsx' ? 'spreadsheeteditor'
      : type === 'pptx' ? 'presentationeditor' : 'documenteditor';
    return 'http://localhost/onlyoffice/webapps/apps/' + app + '/main/index.html?v=' + VERSION_BUMP
      + '&fileType=' + type + '&isDesktop=false&docType=' + type + '&lang=zh-CN&title=' + encodeURIComponent(title);
  }

  /**
   * 官方桌面命令（loginpage sdk.command → AscNative.execCommand 与 command 两入口 → 本函数）。
   *   open:recent —— 沙箱源文件 → x2t 转 doct_bin（DOCY;v10 二进制）→ base64 暂存 →
   *                   loadUrl 官方编辑外壳，等 LocalStartOpen 就绪注入
   *   create:new  —— 空文档（无字节），直接打开外壳（引擎 OfflineApp 空文档）
   * 返回 'true'/'false'：loginpage 不依赖返回值（C++ 侧真正动作已由本函数执行）。
   */
  onShellCommand(cmd: string, param: string): string {
    console.error('[ShellCommand] ' + cmd + ' ' + param.slice(0, 300));
    if (cmd === 'open:recent') {
      return this.openRecent(param);
    }
    if (cmd === 'create:new') {
      // 官方 create:new 参数：'word'|'cell'|'slide'（新建卡片）或 {template:...}（模板卡）
      const isCell = param.indexOf('cell') >= 0;
      const isSlide = param.indexOf('slide') >= 0;
      if (!isCell && !isSlide) {
        return this.openNewFile('docx');
      }
      console.error('CREATE_NEW_UNSUPPORTED ' + param + ' (cell/slide 新建 M4)');
      return 'false';
    }
    if (cmd === 'save:bin') {
      return this.saveBinRaw(param);
    }
    if (cmd === 'go:folder') {
      // 官方桌面"返回"（FileMenu 返回到文档列表）→ Desktop.process('goback')
      console.error('GOBACK -> welcome');
      this.controller.loadUrl(this.homeUrl());
      return 'true';
    }
    if (cmd === 'editor:event') {
      // 官方桌面"关闭文件"（FileMenu miExit → file:exit → Desktop.js:640）
      try {
        const oe = JSON.parse(param) as Record<string, Object>;
        if (String(oe['action']) === 'file:close') {
          console.error('CLOSE_FILE -> welcome');
          this.controller.loadUrl(this.homeUrl());
        }
      } catch (e) {
        console.error('EDITOR_EVENT_ERR ' + String(e));
      }
      return 'true';
    }
    // 其余桌面命令（open:folder / files:check ...）M5 登记降级，当前 no-op
    return 'true';
  }

  /** create:new（word）：空文档模板 → 与打开同管线注入（官方 C++ 对新建同样发 DocumentEndLoad） */
  private openNewFile(ext: string): string {
    try {
      const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/templates/empty.docx') as Uint8Array;
      const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      console.error('CREATE_NEW empty.docx len=' + ab.byteLength);
      return this.convertAndOpen(ab, ext, 'Unnamed.' + ext);
    } catch (e) {
      console.error('CREATE_NEW_ERR ' + String(e));
      return 'false';
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
      if (typeNum === 0x101) {
        ext = 'xlsx';
      } else if (typeNum === 0x81) {
        ext = 'pptx';
      } else {
        ext = 'docx';
      }
      // 扩展名兜底（recents 模型缺 type 时从文件名取）
      if (name.length > 0) {
        const i = name.lastIndexOf('.');
        if (i > 0 && (ext === '' || !name.startsWith(ext))) {
          ext = (name.substring(i + 1) === 'xlsx' || name.substring(i + 1) === 'pptx')
            ? name.substring(i + 1) : ext;
        }
      }
      if (path.length === 0) {
        console.error('OPEN_RECENT_NOPATH ' + param);
        return 'false';
      }
      // 文件名以 path 尾部为准（loginpage recents 的 name 字段可能被截断/缺失）
      const base = path.substring(path.lastIndexOf('/') + 1);
      // 1. 读源文件字节
      const st = fs.statSync(path);
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const ab = new ArrayBuffer(st.size);
      fs.readSync(f.fd, ab);
      fs.closeSync(f);
      return this.convertAndOpen(ab, ext, base.length > 0 ? base : name);
    } catch (e) {
      console.error('OPEN_RECENT_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * M4 保存链：ascshim checkSaveDocumentEvent 接管 → 官方 asc_nativeGetFileData
   * （BinaryFileWriter 序列化当前模型 → DOCY;v10 原始字节，与打开链 in.bin 同格式）
   * → base64 → execCommand('save:bin') 至此。本端：写沙箱 in.bin → x2t doct_bin2docx
   * → save.docx（zip 头校验 0x50 0x4b）→ 回写当前源文件（重开 recents 即编辑后内容）。
   */
  private saveBinRaw(b64: string): string {
    try {
      if (b64.length === 0) {
        console.error('SAVE_BIN_EMPTY');
        return 'false';
      }
      const ab = b64ToBuf(b64);
      const inP = this.hostFilesDir + '/in.bin';
      const outP = this.hostFilesDir + '/save.docx';
      const w = fs.openSync(inP, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(w.fd, ab);
      fs.closeSync(w);
      // x2t doct_bin2docx（checker 以文件头 DOCY 内容识别，.bin 后缀无碍；POC 保存链实证）
      const xml = `<Convert><m_sFileFrom>${inP}</m_sFileFrom><m_sFileTo>${outP}</m_sFileTo></Convert>`;
      const rc = x2tConvertSync(xml);
      console.error('SAVE_BIN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        return 'false';
      }
      const st = fs.statSync(outP);
      const o = fs.openSync(outP, fs.OpenMode.READ_ONLY);
      const mkBuf = new ArrayBuffer(2);
      fs.readSync(o.fd, mkBuf);
      fs.closeSync(o);
      const mk = new Uint8Array(mkBuf);
      const zipOk = mk[0] === 0x50 && mk[1] === 0x4b;
      console.error('SAVE_BIN_OUT size=' + st.size + ' mk=0x'
        + mk[0].toString(16).padStart(2, '0') + mk[1].toString(16).padStart(2, '0')
        + (zipOk ? ' zipok' : ' ZIPBAD'));
      if (!zipOk) {
        return 'false';
      }
      // 回写源文件（recents 重开即编辑后内容）
      if (this.currentOpenName.length > 0) {
        const srcP = this.hostFilesDir + '/' + this.currentOpenName;
        const rd = fs.openSync(outP, fs.OpenMode.READ_ONLY);
        const buf2 = new ArrayBuffer(st.size);
        fs.readSync(rd.fd, buf2);
        fs.closeSync(rd);
        const s = fs.openSync(srcP, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(s.fd, buf2);
        fs.closeSync(s);
        console.error('SAVE_BIN_BACK src=' + srcP + ' size=' + st.size);
      }
      return 'true';
    } catch (e) {
      console.error('SAVE_BIN_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 打开共用管线：x2t 转 doct_bin（DOCY;v10;0;+raw 二进制）→ base64 暂存 →
   * 加载官方编辑外壳（LocalStartOpen 后经 DesktopOfflineAppDocumentEndLoad 注入）。
   * 转换失败或文件不可读 → 不导航，留在欢迎页（避免官方壳报"打开文件错误"弹窗）。
   */
  private convertAndOpen(ab: ArrayBuffer, ext: string, name: string): string {
    try {
      const inP = this.hostFilesDir + '/open-in.' + ext;
      const outP = this.hostFilesDir + '/open-in.bin';
      const w = fs.openSync(inP, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(w.fd, ab);
      fs.closeSync(w);
      // x2t 按输入扩展名自动选 *2doct_bin 转换器；.bin 输出后缀已实机验证（POC 打开链 v10）
      const xml = `<Convert><m_sFileFrom>${inP}</m_sFileFrom><m_sFileTo>${outP}</m_sFileTo></Convert>`;
      const rc = x2tConvertSync(xml);
      console.error('OPEN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        console.error('OPEN_X2T_FAIL ext=' + ext);
        return 'false';
      }
      const st2 = fs.statSync(outP);
      const ro = fs.openSync(outP, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(st2.size);
      fs.readSync(ro.fd, buf);
      fs.closeSync(ro);
      this.pendingOpenBase64 = bufToB64(buf);
      this.pendingOpenLen = st2.size;
      this.pendingOpenUrl = this.hostFilesDir;
      this.pendingOpenName = name;
      this.currentOpenName = name;
      console.error('OPEN_CONVERTED bin=' + st2.size + ' b64=' + this.pendingOpenBase64.length);
      this.controller.loadUrl(this.editorUrl(ext, name));
      return 'true';
    } catch (e) {
      console.error('OPEN_CONVERT_ERR ' + String(e));
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
  private onEditorReadyForDoc(): void {
    if (this.pendingOpenBase64.length === 0) {
      console.error('LSO_NO_PENDING (editor ready, no doc — create:new?)');
      return;
    }
    // 页面 XHR 拉取沙箱 doct_bin（rawfileLoader 已拦 userfile/ → filesDir 返回真字节）→
    // window.postMessage openDocumentFromBinary（官方 api.js/Gateway/loadBinary →
    // asc_openDocumentFromBytes，checkStreamSignature 嗅探 DOCY 签名 —— web/服务器链，
    // 与 3.7 web 语义（编辑器页删除 AscDesktopEditor）配套；桌面 doffline 链路待桌面
    // 字体/native 通路三件套齐备后再启用）。
    const js = '(function(){'
      + 'try{var x=new XMLHttpRequest();'
      + 'x.open("GET","http://localhost/userfile/open-in.bin?v="+Date.now(),true);'
      + 'x.responseType="arraybuffer";'
      + 'x.onload=function(){try{var ab=x.response;'
      + 'if(!ab||!ab.byteLength){console.error("LSO_XHR_EMPTY st="+x.status);return;}'
      + 'window.postMessage({command:"openDocumentFromBinary",data:ab},"*");'
      + 'console.error("LSO_OPEN_DOCUMENT_OK len="+ab.byteLength);'
      + '}catch(e){console.error("LSO_LOAD_ERR "+String(e));}};'
      + 'x.onerror=function(){console.error("LSO_XHR_ERR st="+x.status);};'
      + 'x.send(null);}catch(e){console.error("LSO_INJECT_ERR "+String(e));}})();';
    this.controller.runJavaScript(js, (err: BusinessError, res: string) => {
      if (err) {
        console.error('LSO_INJECT_ERR ' + err.code + ' ' + err.message);
      } else {
        console.error('LSO_INJECT_OK ' + res);
      }
    });
    this.pendingOpenBase64 = ''; // 一次性（下次打开重新转换）
    this.pendingOpenLen = 0;
    this.pendingOpenName = '';
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.resourceManager = ctx.resourceManager;
    this.hostFilesDir = ctx.filesDir;
    this.webLogPath = ctx.filesDir + '/web_console.txt';
    try {
      const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(f); // 每次启动清空 web 日志（避免无限增长/读旧日志）
    } catch (e) {
      // 忽略
    }
    this.copySandboxSamples(); // 样本 docx/xlsx/pptx：rawfile → 沙箱 filesDir（open 链走 userfile/；保存回写也落这里）
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

  build() {
    Column() {
      // 注意：?v=N 是对 ArkWeb http cache 的 cache-bust——rawfileLoader 已剥离 query，
      // 每次提升版本号强制再次取新页面（此 SDK 无 webview.CacheMode 枚举）。
      // 桌面链（M3）：初始页 = 官方 loginpage 欢迎页（产品主界面）；打开文档 → loadUrl 编辑器
      Web({ src: this.useDesktopHome ? this.homeUrl() : this.editorUrl(this.docType, 'sample.docx'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onInterceptRequest((event) => loadRaw(event.request, this.resourceManager!, this.hostFilesDir))
        .onControllerAttached(() => {
          // 桌面链桥——window.AscNative（ascshim.js 里 await 它出现再装 window.AscDesktopEditor）。
          // registerJavaScriptProxy 的对象要到页面 (re)load 才出现在 window，故在
          // onControllerAttached（早于加载）注册才对本页生效。
          // 同步方法表：'_call'（JS 端阻塞取返回——官方 CEF V8 语义）、'_onReady'（安装完成）
          const nativeDispatch = new AscNativeDispatch(this.hostFilesDir);
          nativeDispatch.setHandler(new ShellCommandHandler(this));
          nativeDispatch.setLocalStartOpenHandler(() => {
            this.onEditorReadyForDoc();
          });
          this.ascNative = new AscNativeBridge(nativeDispatch);
          this.controller.registerJavaScriptProxy(this.ascNative, 'AscNative', ['_call', '_onReady'], []);
        })
        .onPageEnd(() => {
          // 用 console.error 而非 console.log：I 级日志随 app 切后台被丢弃，E 级稳定（与页面 [web] 同通道）
          console.error('PAGE_END url=' + this.controller.getUrl());
          // 页面级错误采集（app 初始化失败时 onerror/unhandledrejection 是最直接证据）
          const inject = `(function(){
if(window.__ooh_installed){return;}
window.__ooh_installed=true;
try{var _er0=window.onerror;window.onerror=function(msg,src,ln,cl,err){console.error('JSERR '+String(msg).slice(0,160)+' @'+String(src||'').slice(-40)+':'+ln);if(_er0)return _er0.apply(this,arguments);return false;};}catch(e){}
try{window.addEventListener('unhandledrejection',function(ev){console.error('UHR '+String(ev.reason&&ev.reason.message||ev.reason).slice(0,160));});}catch(e){}
})();`;
          this.pageJS(inject);
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
