// ============================================================================
// AscBridge —— window.AscNative 单入口同步桥
//
// 注册（EditorPage.onControllerAttached）：
//   controller.registerJavaScriptProxy(this.ascNative, 'AscNative', ['_call', '_onReady'], [])
// 页面侧（ascshim.js）：
//   window.AscDesktopEditor = { IsLocalFile: p => AscNative._call('IsLocalFile', [p]) ... }
//   + 官方 InitJSContext shim（CreateEditorApi/sendSystemMessage/OpenFilenameDialog...）
// 即 CEF 202 方法的全部名字→JS 对象成员；成员体统一到 _call(methodName, args)。
//
// 分派在 AscNativeDispatch 类（同文件），负责将 methodName 转为 ArkTS/NAPI 动作，
// 未实现的方法按官方降级契约返回（false/''/0/{}），并登记 FEATURE_MATRIX 待办。
// 日志经构造注入 logger（EditorPage.arkLog → web_console.txt 统一入口）；
// 未注入时降级 console.error（hilog）。
// ============================================================================

import { readRecents, removeRecent, clearRecents, RecentItem } from './recents';
import { bufToB64 } from './bytes';

/** LocalFileRecents 输出形状（loginpage parseRecent 消费的 5 字段，与 RecentItem 同构） */
interface RecentOut {
  id: number;
  pin: number;
  path: string;
  type: number;
  modifyed: string;
}

/** ArkWeb registerJavaScriptProxy 传入的参数（JS 侧传递的简单值对象） */
export type BridgeArgs = Array<Object | string | number | boolean>;

/** 日志注入签名（EditorPage.arkLog 语义：落 web_console.txt） */
export type BridgeLog = (msg: string) => void;

const DEFAULT_LOG: BridgeLog = (msg: string) => console.error(msg);

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
    this.dispatch.log('[AscNative] READY');
    return 'ok';
  }
}

/** 业务回调接口：EditorPage 注入，处理"桌面命令"类动作（打开/新建文件等） */
export interface AscCommandHandler {
  /** 处理桌面命令；返回 JSON 编码结果（'true'/'""'/对象） */
  onCommand(cmd: string, param: string, userFlag?: number): string;
}

/** 请求分派中心 */
export class AscNativeDispatch {
  private filesDir: string;
  private handler: AscCommandHandler | null = null;
  /** 日志出口（AscNativeBridge._onReady 同用；EditorPage 注入 arkLog → web_console.txt） */
  log: BridgeLog;
  /** 官方打开链信号：sdkjs 引擎就绪时调 LocalStartOpen()（common/Local/common.js:64）
   *  → 桥转发 → EditorPage.onEditorReadyForDoc（XHR 拉沙箱字节 + postMessage 注入） */
  private localStartOpenCb: (() => void) | null = null;

  constructor(filesDir: string, log?: BridgeLog) {
    this.filesDir = filesDir;
    this.log = log ?? DEFAULT_LOG;
  }

  /** EditorPage 在 onControllerAttached 时注入命令处理器 */
  setHandler(handler: AscCommandHandler): void {
    this.handler = handler;
  }

  /** EditorPage 注入 LocalStartOpen 回调（引擎就绪 → 送文档字节） */
  setLocalStartOpenHandler(cb: (() => void) | null): void {
    this.localStartOpenCb = cb;
  }

  /** 保存目标读取（页面 asc_Save 经 save:type 同步询问）：
   *  'none'（新建无身份：autosave 跳过/用户保存→另存为）| 'sandbox' | 'uri' */
  private saveTargetReader: (() => string) | null = null;
  setSaveTargetReader(fn: (() => string) | null): void {
    this.saveTargetReader = fn;
  }

  /** rawfile 读取（EditorPage 注入 getRawFileContentSync；null = 桥未接 → '""'）。
   *  LoadFontBase64 依赖（2026-09-05 中文方块根因修复，见 loadFontBase64）。 */
  private rawRead: ((path: string) => Uint8Array | null) | null = null;
  setRawReader(fn: (path: string) => Uint8Array | null): void {
    this.rawRead = fn;
  }

  /** 主题色上报（页面 00_theme 0.10 读取当前主题 CSS 变量 --toolbar-header-<app>
   *  上报 → EditorPage 缓存到 docAccents——选中 tab 颜色跟随文档页当前主题色，
   *  官方桌面特性复刻。payload JSON {app,color}）。 */
  private themeReporter: ((payload: string) => string) | null = null;
  setThemeReporter(fn: (payload: string) => string): void {
    this.themeReporter = fn;
  }

  private execCommand(args: BridgeArgs): string {
    const cmd = typeof args[0] === 'string' ? (args[0] as string) : '';
    const param = typeof args[1] === 'string' ? (args[1] as string) : '';
    // 第三参 = 用户保存标志（1 用户保存 / 0 autosave；ascshim 40_save 传；缺省 1 兜底）
    const userFlag = typeof args[2] === 'number' ? args[2] : 1;
    this.log('[AscNative:execCommand] ' + cmd + ' ' + param.slice(0, 200));
    return this.handler ? this.handler.onCommand(cmd, param, userFlag) : 'true';
  }

  invoke(name: string, args: BridgeArgs): string {
    try {
      switch (name) {
        // ===== 本机已实现（文件系统/业务动作）=====
        case 'getFilesDir':
          // M7 验收工具（m7open）：欢迎页自动打开沙箱文件需要绝对路径（open:recent 的 path）
          return this.filesDir;
        case 'IsLocalFile':
          // 官方：判断下载的临时文件是否为本地文件（桌面模式恒 "local"）
          return 'true';
        case 'LocalFileRecents':
          // 2026-09-05 用户决策：暂不支持「最近使用文件」——B 架构文件位置是 picker
          // 授权型 uri（授权会被回收），列表路径语义不成立；面板已 UI 隐藏（40_save
          // 3.10）。数据端同步封闭（recents.json 读写保留，待持久位置机制再恢复）。
          return '[]';
        case 'save:type':
          // v2 保存目标询问（页面 asc_Save 同步调用；缺省 'sandbox' 兜底——页面侧
          // autosave 短路只认 'none'，取不到时放行不丢数据）
          return this.saveTargetReader ? this.saveTargetReader() : 'sandbox';
        case 'LocalFileRemoveRecent':
          // 官方面板「从列表中移除」→ sdk.LocalFileRemoveRecent(fileid) → 本 case。
          // 2026-09-05：原硬编码 '1'（假成功、列表永远清不掉——用户实测）——真删除
          // （按 id，recents.json 去条；删除后页面侧 ascshim 2.6 会 fire onupdaterecents
          // 刷新面板，见 20_bridge 2.6 段）。
          return removeRecent(this.filesDir, Number(typeof args[0] === 'object'
            ? (args[0] as Record<string, Object>)['id'] ?? 0
            : args[0] ?? 0)) ? '1' : '0';
        case 'LocalFileRemoveAllRecents':
          // 官方面板「清除」→ sdk.LocalFileRemoveAllRecents() → 本 case（全清 + 同上刷新）
          this.log('LocalFileRemoveAllRecents');
          return clearRecents(this.filesDir) ? '1' : '0';
        case 'LocalFileRemoveRecover':
        case 'LocalFileRemoveAllRecovers':
          return '1';
        case 'LocalFileRecovers':
          return '[]';
        case 'GetLocalFeatures':
          return '{"features":["dav","local"]}';
        case 'LocalFileGetSourcePath':
          return args.length > 0 ? (args[0] as string) : '';
        case 'LocalFileGetSaved':
        case 'LocalFileTemplates':
          return '[]';
        case 'IsLocalFileExist':
          return 'true';
        case 'GetInstallPlugins':
        case 'GetBackupPlugins':
          // 官方空态（GetPluginsJson 布局双段 url+pluginsData；sdkjs UpdateSystemPlugins
          // 直接 _plugins[0..1] 取 url，[] 会 TypeError —— 见 make_ascshim.py RAW_METHODS 注释）
          return '[{"url":"","pluginsData":[]},{"url":"","pluginsData":[]}]';
        case 'execCommand':
          return this.execCommand(args);
        case 'theme:color':
          // 主题色上报（00_theme 0.10）：per-instance（dispatch 按 ctx 装配）
          return this.themeReporter ? this.themeReporter(String(args[0] ?? '')) : 'true';
        case 'LocalStartOpen':
          // 引擎加载完成（官方：编辑器 LocalFile counter 之一）——交给 EditorPage 注入字节
          if (this.localStartOpenCb) {
            this.log('[AscNative:LocalStartOpen] -> inject');
            this.localStartOpenCb();
          }
          return 'true';
        case 'LocalFileSaveBin':
          // M4 遗留出入口（ascshim 已统一走 execCommand('save:bin')；本 case 保留为
          // 兼容转发——避免任何残留调用写死 save.docx 产生双保存链，2026-09-05 收敛）
          return this.execCommand(['save:bin', typeof args[0] === 'string' ? (args[0] as string) : '']);
        case 'SaveQuestion':
          return 'false';

        // ===== 支持标志（false → 官方 UI 自动隐藏对应入口）=====
        case 'isSupportMacroses':
        case 'isSupportNetworkFunctionality':
        case 'IsSupportNativePrint':
        case 'IsFilePrinting':
        case 'IsSupportMedia':
        case 'IsSignaturesSupport':
        case 'IsProtectionSupport':
          return 'false';
        // 插件提真（2026-09-06 AI 插件接入）：sdkjs common/plugins.js:977-980 run()
        // 第一道门 isSupportPlugins()===false → 直接 return——9-04/9-05「AI 选项卡
        // 出现但点按钮无反应」硬根因。web 语义插件装配走 plugins.json server 链
        // （web-apps Plugins.js:165），不依赖 GetInstallPlugins（保持下方空态）。
        case 'isSupportPlugins':
          return 'true';
        case 'isBlockchainSupport':
          return 'false';
        case 'GetExternalClouds':
        case 'getSupportCryptoModes':
        case 'GetSupportCryptoModes':
          return '[]';
        case 'GetCryptoMode':
          return '0';

        // ===== 官方 shim 元信息/降级（'""' 需保持 JSON 文本，乱会 Unexpected end）=====
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
        case 'getDictionariesPath':
          return '""';

        // ===== 空/降级（未实现功能）=====
        case 'GetHash':
        case '_GetHash':
        case 'GetSupportScaleValues':
        case 'GetFontThumbnailHeight':
        case 'CheckUserId':
        case 'SetAdvancedOptions':
        case 'ApplyAction':
        case 'SetFullscreen':
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
          return '0';

        // ===== 未知/未登记 → 降级空（is/Support 前缀走 false，其余 ""）=====
        case 'LoadFontBase64':
          // 官方语义：返回 "<size>;<base64>"（sdkjs stringserialize.js Base64.decode
          // 的 isUsePrefix 前缀格式）；JS 侧 ascshim 回填 window[fontId]。
          // 2026-09-05 根因修复：此前无此 case → fallback '""' → 引擎取 window[id]
          // = undefined → CreateFontData4(undefined) → 字体流空 → 字体 face=null →
          // 中文等 CJK 字符无字形 → 方块（desktop C++ 有实现，我们 B 架构一直缺这段）。
          return this.loadFontBase64(String(args[0] ?? ''));
        default:
          return this.fallback(name);
      }
    } catch (err) {
      this.log('[AscNative] ' + name + ' err: ' + String(err)
        + (err instanceof Error ? ' ' + err.message : ''));
      return '""';
    }
  }

  private localFileRecents(): string {
    this.log('[AscNative:LocalFileRecents] ' + this.filesDir);
    // recents 真数据（单一实现/契约：recents.ets —— loginpage utils.js parseRecent 消费，
    // 输出 5 字段 id/pin/path/type/modifyed 不可多不可少）：
    // 损坏文件返回 null → 空列表（loginpage 空 recents 点「Open local file」走官方直发
    // 分支 openFile(OPEN_FILE_FOLDER) → open:folder —— 免二次点击）。
    const arr = readRecents(this.filesDir) ?? [];
    return JSON.stringify(arr.map((r): RecentOut => {
      return { id: r.id, pin: r.pin, path: r.path, type: r.type, modifyed: r.modifyed };
    }));
  }

  /** rawfile/onlyoffice/fonts/<id> → "<size>;<base64>"（size 为字节数十进制） */
  private loadFontBase64(id: string): string {
    try {
      const u8 = this.rawRead ? this.rawRead('onlyoffice/fonts/' + id) : null;
      if (!u8 || u8.length === 0) {
        this.log('[AscNative:LoadFontBase64] miss ' + id);
        return '""';
      }
      const out = String(u8.length) + ';' + bufToB64(u8);
      this.log('[AscNative:LoadFontBase64] ' + id + ' bytes=' + u8.length);
      return JSON.stringify(out);
    } catch (e) {
      this.log('[AscNative:LoadFontBase64] ' + id + ' err ' + String(e));
      return '""';
    }
  }

  private fallback(name: string): string {
    this.log('[AscNative] not-implemented: ' + name);
    return name.startsWith('is') || name.startsWith('Is') || name.startsWith('Support') ? 'false' : '""';
  }
}
