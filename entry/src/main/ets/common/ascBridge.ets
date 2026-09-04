// ============================================================================
// AscBridge —— window.AscNative 单入口同步桥
//
// 注册（EditorPage.onControllerAttached）：
//   controller.registerJavaScriptProxy(this.ascBridge, 'AscNative', ['_call'], [])
// 页面侧（ascshim.js）：
//   window.AscDesktopEditor = { IsLocalFile: p => AscNative._call('IsLocalFile', [p]) ... }
//   + 官方 InitJSContext shim（CreateEditorApi/sendSystemMessage/OpenFilenameDialog...）
// 即 CEF 202 方法的全部名字→JS 对象成员；成员体统一到 _call(methodName, args)。
//
// 分派在 AscNativeDispatch 类（同文件），负责将 methodName 转为 ArkTS/NAPI 动作，
// 未实现的方法按官方降级契约返回（false/''/0/{}），并登记 FEATURE_MATRIX 待办。
// ============================================================================

import { fileIo as fs } from '@kit.CoreFileKit';

/** ArkWeb registerJavaScriptProxy 传入的参数（JS 侧传递的简单值对象） */
export type BridgeArgs = Array<Object | string | number | boolean>;

/** base64 → ArrayBuffer（与 EditorPage.b64ToBuf 同实现；ArkTS 页内副本避免跨文件依赖） */
function b64buf(b64: string): ArrayBuffer {
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

// JS → ArkTS 方向，全部为同步语义（ArkWeb methodList）。
export class AscNativeBridge {
  private dispatch: AscNativeDispatch;

  constructor(dispatch: AscNativeDispatch) {
    this.dispatch = dispatch;
  }

  // window.AscNative._call(name, args[]) —— 同步调用；返回 string（JSON 或原生串）
  _call(name: string, args: BridgeArgs): string {
    return this.dispatch.invoke(name, args);
  }

  // 窗口就绪信号
  _onReady(): string {
    console.error('[AscNative] READY');
    return 'ok';
  }
}

/** 业务回调接口：EditorPage 注入，处理"桌面命令"类动作（打开/新建文件等） */
export interface AscCommandHandler {
  /** 处理桌面命令；返回 JSON 编码结果（'true'/'""'/对象） */
  onCommand(cmd: string, param: string): string;
}

/** 请求分派中心 */
export class AscNativeDispatch {
  private filesDir: string;
  private handler: AscCommandHandler | null = null;
  /** 官方打开链信号：sdkjs 引擎就绪时调 LocalStartOpen()（common/Local/common.js:64）
   *  → 桥转发 → EditorPage 注入 DesktopOfflineAppDocumentEndLoad(url, base64, len) */
  private localStartOpenCb: (() => void) | null = null;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  /** EditorPage 在 onControllerAttached 时注入命令处理器 */
  setHandler(handler: AscCommandHandler): void {
    this.handler = handler;
  }

  /** EditorPage 注入 LocalStartOpen 回调（引擎就绪 → 送文档字节） */
  setLocalStartOpenHandler(cb: (() => void) | null): void {
    this.localStartOpenCb = cb;
  }

  private execCommand(args: BridgeArgs): string {
    const cmd = typeof args[0] === 'string' ? (args[0] as string) : '';
    const param = typeof args[1] === 'string' ? (args[1] as string) : '{}';
    console.error('[AscNative:execCommand] ' + cmd + ' ' + param.slice(0, 200));
    return this.handler ? this.handler.onCommand(cmd, param) : 'true';
  }

  invoke(name: string, args: BridgeArgs): string {
    try {
      switch (name) {
        // ===== 核心：本机已实现 =====
        // 文件系统
        case 'IsLocalFile':
          return this.isLocalFile(args);
        case 'LocalFileRecents':
          return this.localFileRecents(args);
        case 'LocalFileRemoveRecent':
          return '1';
        case 'LocalFileRemoveAllRecents':
          return '1';
        case 'LocalFileRecovers':
          return '[]';
        case 'LocalFileRemoveRecover':
          return '1';
        case 'LocalFileRemoveAllRecovers':
          return '1';
        case 'GetLocalFeatures':
          return '{"features":["dav","local"]}';
        case 'LocalFileGetSourcePath':
          return args.length > 0 ? (args[0] as string) : '';
        case 'LocalFileGetSaved':
          return '[]';
        case 'LocalFileTemplates':
          return '[]';
        case 'IsLocalFileExist':
          return 'true';

        // 支持标志（false → 官方 UI 自动隐藏对应入口）
        case 'isSupportMacroses':
        case 'isSupportPlugins':
          return 'false';
        case 'isSupportNetworkFunctionality':
          return 'false';
        case 'IsSupportNativePrint':
        case 'IsFilePrinting':
          return 'false';
        case 'IsSupportMedia':
        case 'IsSignaturesSupport':
        case 'IsProtectionSupport':
          return 'false';
        case 'isBlockchainSupport':
          return 'false';
        case 'GetExternalClouds':
          return '[]';
        case 'getSupportCryptoModes':
        case 'GetSupportCryptoModes':
          return '[]';
        case 'GetCryptoMode':
          return '0';
        // 官方空态（GetPluginsJson 布局双段 url+pluginsData；sdkjs UpdateSystemPlugins
        // 直接 _plugins[0..1] 取 url，[] 会 TypeError / JSON.parse('') —— 见 ascshim RAW 说明）
        case 'GetInstallPlugins':
        case 'GetBackupPlugins':
          return '[{"url":"","pluginsData":[]},{"url":"","pluginsData":[]}]';
        case 'getDictionariesPath':
          return '""';
        case 'CheckCloudFeatures':
          return '0';
        case 'GetOpenedFile':
          return '[]';
        case 'getEngineVersion':
          return '"9.4.0"';
        case 'GetDocumentInfo':
        case 'getDocumentInfo':
          return '""';
        case 'GetCurrentWindowInfo':
          return '{}';
        case 'getOfficeFileType':
          return '""';
        // shim JSON.parse(_getViewportSettings()) 需 JSON 字符串（'"{}"'），空串会 Unexpected end
        case '_getViewportSettings':
        case 'GetViewportSettings':
          return '"{}"';
        // shim defineProperty CryptoMode.get → 直接作为值消费（数值 0）
        case 'Property_GetCryptoMode':
          return '0';

        // 空/降级（未实现功能）
        case 'GetHash':
        case '_GetHash':
        case 'GetSupportScaleValues':
        case 'GetFontThumbnailHeight':
        case 'CheckUserId':
        case 'SetAdvancedOptions':
        case 'ApplyAction':
        case 'SetFullscreen':
          return 'false';

        case 'execCommand':
          return this.execCommand(args);

        case 'LocalStartOpen':
          // 引擎加载完成（官方：编辑器 LocalFile counter 之一）——交给 EditorPage 注入字节
          if (this.localStartOpenCb) {
            console.error('[AscNative:LocalStartOpen] -> inject');
            this.localStartOpenCb();
          }
          return 'true';

        case 'LocalFileSaveBin':
          // M4 保存链：官方 asc_onSaveDocument → Gateway.saveDocument(ascshim 覆写)
          // → _call('LocalFileSaveBin', [base64]) → 写沙箱 filesDir/save.docx
          try {
            const b64 = typeof args[0] === 'string' ? (args[0] as string) : '';
            console.error('[AscNative:LocalFileSaveBin] b64len=' + b64.length);
            const ab = b64buf(b64);
            const f = fs.openSync(this.filesDir + '/save.docx', fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
            fs.writeSync(f.fd, ab);
            fs.closeSync(f);
            console.error('[AscNative:LocalFileSaveBin] saved bytes=' + ab.byteLength);
            return 'true';
          } catch (se) {
            console.error('[AscNative:LocalFileSaveBin] err: ' + String(se));
            return 'false';
          }

        case 'SaveQuestion':
          return 'false';

        // ===== 官方 shim 调用、无本地实现 =====
        case 'CreateEditorApi':
        case '_CreateEditorApi':
        case 'OnSave':
        case 'onDocumentModifiedChanged':
        case 'onDocumentContentReady':
        case 'SetDocumentName':
        case 'SetEditorId':
        case 'GetEditorId':
        case 'InitJSContext':
        case 'setCookie':
        case 'getCookiePresent':
        case 'setAuth':
        case 'getAuth':
        case 'Logout':
        case 'CheckCloudFeatures':
          return '0';

        // ===== 未知/未登记 → 降级空 =====
        default:
          return this.fallback(name, args);
      }
    } catch (err) {
      console.error('[AscNative] ' + name + ' err: ' + JSON.stringify(err));
      return '""';
    }
  }

  private isLocalFile(args: BridgeArgs): string {
    // 官方：判断下载的临时文件是否为本地文件（桌面模式恒 "local"）
    return 'true';
  }

  private localFileRecents(args: BridgeArgs): string {
    console.error('[AscNative:LocalFileRecents] ' + this.filesDir);
    // recents 契约（由 loginpage utils.js:405 parseRecent 单方消费，字段不可多不可少）：
    //   id(存为 fileid) / pin(置 pinid 符号) / path(绝对路径，名从路径尾截取)
    //   type(FileFormat 枚举整数: docx=0x41 xlsx=0x101 pptx=0x81) / modifyed(显示"最近打开")
    // M7：真数据 —— EditorPage 打开文档时追加 filesDir/recents.json（打开过即"最近"）
    class RecentItem {
      id: number = 0;
      pin: number = 0;
      path: string = '';
      type: number = 0;
      modifyed: string = '';
    }
    // M7 真数据：recents.json 不存在/空 → 空列表（loginpage 空 recents 时点「Open local file」
    // 走官方直发分支 openFile(OPEN_FILE_FOLDER) → open:folder —— 免二次点击）
    const arr: RecentItem[] = [];
    try {
      const p = this.filesDir + '/recents.json';
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(p);
      const txt = new ArrayBuffer(st.size);
      fs.readSync(f.fd, txt);
      fs.closeSync(f);
      let txtStr = '';
      const t8 = new Uint8Array(txt);
      for (let i = 0; i < t8.length; i++) {
        txtStr += String.fromCharCode(t8[i]);
      }
      const parsed = JSON.parse(txtStr) as Array<Record<string, Object>>;
      const now = new Date().toLocaleString();
      for (const r of parsed) {
        const item = new RecentItem();
        item.id = Number(r['id'] ?? 0);
        item.path = String(r['path'] ?? '');
        item.type = Number(r['type'] ?? 0x41);
        item.modifyed = String(r['modifyed'] ?? now);
        arr.push(item);
      }
    } catch (e) {
      console.error('[AscNative:LocalFileRecents] no recents.json: ' + String(e));
    }
    return JSON.stringify(arr);
  }

  private fallback(name: string, args: BridgeArgs): string {
    console.warn('[AscNative] not-implemented: ' + name);
    return name.startsWith('is') || name.startsWith('Is') || name.startsWith('Support') ? 'false' : '""';
  }
}
