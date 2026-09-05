import { webview } from '@kit.ArkWeb';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { loadRaw } from '../common/rawfileLoader';
import { x2tConvertSync } from '../common/x2t';
import { AscNativeBridge, AscNativeDispatch, AscCommandHandler } from '../common/ascBridge';
import { Smoke } from '../common/smoke';
import { getLaunchOptions } from '../entryability/EntryAbility';
import { b64ToBuf, readFileBuf, writeFileBuf, x2tXml, u8ToStr } from '../common/bytes';
import { appendRecent, RECENT_TYPE_DOCX, RECENT_TYPE_XLSX, RECENT_TYPE_PPTX } from '../common/recents';

/** ArkTS 侧调试开关：false=仅落 web_console.txt 文件（默认）；true=另 hilog 双写 */
const ARK_DEBUG: boolean = false;
/**
 * 自动验收 = ability 启动参数控制（2026-09-05 用户建议：不写死代码，避免重新编译切换）：
 *   hdc XXX shell aa start -a EntryAbility -b app.hackeris.winehua \
 *     -p m7accept 1 -p m7file sample.xlsx
 *   m7accept=1  → 验收开启（缺省 m7file=sample.docx；文件名须在 rawfile/onlyoffice/ 下，
 *                 且被 copySandboxSamples 复制到沙箱）。
 *   无参数启动 → 产品态：无自动打开/探针/诊断快照/样本拷贝（验收与产品分离，阶段2）。
 * 双重门控：ascshim 的 m7open/m7auto 另按 URL 参数触发（EditorPage 只在该模式拼参数）。
 */

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

@Entry
@Component
struct EditorPage {
  controller: webview.WebviewController = new webview.WebviewController();
  private resourceManager: resourceManager.ResourceManager | undefined = undefined;
  private ascNative: AscNativeBridge | undefined = undefined;
  private hostFilesDir: string = '';
  private webLogPath: string = '';
  // —— 官方打开链（M3）：open:recent → x2t → 临时文件 open-in.bin（页面 XHR 拉字节），
  //     本布尔量仅作「有待打开文档」守卫（原 base64 暂存字段从未被消费，2026-09-05 删除） ——
  private pendingOpenFile: boolean = false;
  // 当前打开文档名（M4 保存回写源文件用；一次性，不残留）
  private currentOpenName: string = '';
  /** M7：当前打开文档扩展名（docx/xlsx/pptx）—— 保存链 save.<ext> 用 */
  private currentOpenExt: string = 'docx';

  /** M7 诊断直达配额：onPageEnd 时打开样本（welcome 完成后才触发，避开加载竞争） */
  private m7DirectQueued: boolean = false;

  /**
   * 统一日志入口（ArkTS 侧 → web_console.txt 镜像，与页面 [web] 日志同文件/时间戳）。
   * 页面日志经 onConsole 也走本函数（2026-09-05 归并：原内联落盘与此处双份重复）。
   * 开关：ARK_DEBUG=false 仅落文件（设备文件最可靠，hilog 抓取部分环境不可用）；
   * true 另 console.error 双写（hilog）。文件名：主日志系统缺 hilog 时仍可拷贝。
   */
  private arkLog(msg: string): void {
    if (ARK_DEBUG) {
      console.error(msg);
    }
    try {
      const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
      fs.writeSync(f.fd, 'T' + Date.now() + ' ' + msg + '\n');
      fs.closeSync(f);
    } catch (e) {
      // 日志落盘失败不影响主流程
    }
  }

  // —— 页面注入入口（runJavaScript）——
  private pageJS(fn: string): void {
    this.controller.runJavaScript(fn, (err: BusinessError, res: string) => {
      if (err) {
        this.arkLog('OOH_SHELL ' + fn.substring(0, 40) + ' ERR ' + err.code + ' ' + err.message);
      }
    });
  }

  /** 页缓存版本号：构建期按 rawfile/onlyoffice 内容哈希生成（version.json）
   *  → URL ?v=N cache-bust（原 VERSION_BUMP 手工递增已删，阶段3 2026-09-05） */
  private pageVer: string = '0';
  /** 自动验收样本名（Smoke.target 的页面侧副本——smoke 行为见 Smoke 模块/Ascshim；
   *  空 = 产品态：无自动打开/诊断快照/样本拷贝） */
  private m7Target: string = '';

  /** 官方欢迎页（loginpage）：欢迎/最近文件列表 + 新建卡片
   *  lang=zh-CN：loginpage 界面语言由 URL 参数决定（utils.inParams.lang；
   *  未传时回退英文——2026-09-05 用户目标「默认中文」） */
  private homeUrl(): string {
    return 'http://localhost/onlyoffice/index.html?v=' + this.pageVer
      + '&lang=zh-CN'
      // 注：zoom=1.2 只在文档页（editorUrl）拼——2026-09-05 用户：主界面不放大，
      // 文档页面才放大（LSO_PAGE_ZOOM 由 ascshim 00_boot 按参数设 html CSS zoom）
      + (this.m7Target.length > 0 ? '&m7open=' + encodeURIComponent(this.m7Target) : '');
  }

  /** 沉浸窗口状态缓存（setImmersive 幂等去重；''=未初始化，首次按 URL 设定） */
  private immersiveState: string = '';

  /** PC（2in1/pc）标记：URL 拼 &zoom=1.2 → 页面 ascshim 对 html 设置 CSS zoom
   *  （WebviewController.zoom(factor) 为移动端触摸语义，桌面布局实测无效——
   *  2026-09-05 量化验证：字高 47px 前后无变化；故走 URL 参数 + 页面 CSS zoom） */
  private readonly isPc: boolean = deviceInfo.deviceType === '2in1'
    || deviceInfo.deviceType === 'pc';

  /** 沉浸窗口按 URL 驱动（2026-09-05 用户需求：主页不沉浸，离开主页（编辑器页）再开。
   *  仅 Pad（module deviceTypes 含 phone/2in1，deviceInfo 守卫——EntryAbility 已迁移
   *  到此处，主页初始即非沉浸）。入口统一为 Web 组件 onLoadIntercept（导航决定时、
   *  早于内容加载）+ 单点收口覆盖所有进出路径（初始/打开/关闭/文件菜单返回/ascshim
   *  goback/requestClose 的页面自跳——任何落脚 index.html 或 /main/index.html 的
   *  导航都会经过拦截）。setSpecificSystemBarEnabled 的 navigationIndicator 为隐藏
   *  底部手势条正确接口（setWindowSystemBarEnable 的 'navigation' 无效果，参照
   *  ../comfyui 实测注释）。 */
  private setImmersive(url: string): void {
    // 沉浸设备范围：仅 Tablet（2026-09-05 用户回调：PC/2in1 不做沉浸——PC 的
    // 形态诉求是「空出系统标题栏」，由 EntryAbility setWindowDecorVisible(false)
    // 方案处理（HiSH 同款）；phone 保持系统默认。主页始终不沉浸（URL 判定下方）。
    if (deviceInfo.deviceType !== 'tablet') { return; }
    const on = url.indexOf('/main/index.html') >= 0;
    const state = on ? 'on' : 'off';
    if (this.immersiveState === state) { return; }
    // getLastWindow 为 Promise 版（本 SDK 无 getLastWindowSync）；getContext 需显式
    // 类型（arkts-no-any-unknown）。导航低频，重复切换时两次异步按序覆盖，终态=最后一次。
    const ctx = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(ctx).then((mw: window.Window) => {
      try {
        mw.setWindowLayoutFullScreen(on);
        mw.setSpecificSystemBarEnabled('status', !on);
        mw.setSpecificSystemBarEnabled('navigationIndicator', !on);
        this.immersiveState = state;
        this.arkLog('IMMERSIVE ' + state + ' url=' + url);
      } catch (e) {
        this.arkLog('IMMERSIVE_ERR ' + String(e));
      }
    }).catch((e: BusinessError) => {
      this.arkLog('IMMERSIVE_ERR ' + String(e));
    });
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
    let url = 'http://localhost/onlyoffice/webapps/apps/' + app + '/main/index.html?v=' + this.pageVer
      + '&fileType=' + type + '&isDesktop=false&docType=' + type + '&lang=zh-CN&title=' + encodeURIComponent(title)
      + (this.isPc ? '&zoom=1.2' : '');   // PC 文档页整体放大 1.2（ascshim 00_boot → html zoom）
    // M7 验收态：自动打开后追加 m7auto=1（ascshim：模型就绪→序列化→save:bin→x2t 落盘）
    if (this.m7Target.length > 0) {
      url = url + '&m7auto=1';
    }
    return url;
  }

  /**
   * 官方桌面命令（loginpage sdk.command → AscNative.execCommand 与 command 两入口 → 本函数）。
   *   open:recent —— 沙箱源文件 → x2t 转 doct_bin（DOCY;v10 二进制）→ base64 暂存 →
   *                   loadUrl 官方编辑外壳，等 LocalStartOpen 就绪注入
   *   create:new  —— 空文档（无字节），直接打开外壳（引擎 OfflineApp 空文档）
   * 返回 'true'/'false'：loginpage 不依赖返回值（C++ 侧真正动作已由本函数执行）。
   */
  onShellCommand(cmd: string, param: string): string {
    this.arkLog('[ShellCommand] ' + cmd + ' ' + param.slice(0, 300));
    if (cmd === 'open:recent') {
      return this.openRecent(param);
    }
    if (cmd === 'create:new') {
      // 官方 create:new 参数：'word'|'cell'|'slide'（新建卡片）或 {template:...}（模板卡）
      // 2026-09-05：cell/slide 支持（空模板 empty.xlsx/empty.pptx 由
      // scripts/onlyoffice/make_empty_templates.py 生成——原为 M4 TODO 不支持）
      const isCell = param.indexOf('cell') >= 0;
      const isSlide = param.indexOf('slide') >= 0;
      const ext = isSlide ? 'pptx' : isCell ? 'xlsx' : 'docx';
      return this.openNewFile(ext);
    }
    if (cmd === 'open:folder') {
      // M7：loginpage「Open local file」→ sdk.command('open:folder', path)（欢迎页按钮/拖放区
      // "选择文件"；param 为 pinned 文件夹路径，桌面语义"打开文件夹位置"）。本机语义 = 系统
      // 文件选择器选一个 docx/xlsx/pptx 打开（async 处理，命令先行受理）。
      this.openLocalFile();
      return 'true';
    }
    if (cmd === 'save:bin') {
      return this.saveBinRaw(param);
    }
    if (cmd === 'go:folder') {
      // 官方桌面"返回"（FileMenu 返回到文档列表）→ Desktop.process('goback')
      this.arkLog('GOBACK -> welcome');
      this.controller.loadUrl(this.homeUrl());
      return 'true';
    }
    if (cmd === 'editor:event') {
      // 官方桌面"关闭文件"（FileMenu miExit → file:exit → Desktop.js:640）
      try {
        const oe = JSON.parse(param) as Record<string, Object>;
        if (String(oe['action']) === 'file:close') {
          this.arkLog('CLOSE_FILE -> welcome');
          this.controller.loadUrl(this.homeUrl());
        }
      } catch (e) {
        this.arkLog('EDITOR_EVENT_ERR ' + String(e));
      }
      return 'true';
    }
    // 其余桌面命令（open:folder / files:check ...）M5 登记降级，当前 no-op
    return 'true';
  }

  /** create:new（word）：空文档模板 → 与打开同管线注入（官方 C++ 对新建同样发 DocumentEndLoad） */
  private openNewFile(ext: string): string {
    try {
      // 空模板（rawfile/onlyoffice/templates/empty.<ext>；docx/xlsx/pptx 均由
      // 官方样本/结构保证合法——xlsx/pptx 生成见 scripts/onlyoffice/make_empty_templates.py）
      const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/templates/empty.' + ext) as Uint8Array;
      const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      this.arkLog('CREATE_NEW empty.' + ext + ' len=' + ab.byteLength);
      return this.convertAndOpen(ab, ext, 'Unnamed.' + ext);
    } catch (e) {
      this.arkLog('CREATE_NEW_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * M7 打开真实文件：系统文件选择器（DocumentViewPicker）→ 选中 docx/xlsx/pptx
   * → 字节交 convertAndOpen（写入沙箱 <name> + x2t + 编辑器导航）。
   * 选择器授权 uri 仅临时可读 —— 字节读入内存即固化为沙箱文件，此后与源文件无关联
   * （保存回写沙箱；"导出"经系统保存对话框写用户位置）。
   */
  private async openLocalFile(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.docx', '.xlsx', '.pptx'];
      const uris = await dvp.select(opts);
      if (uris.length === 0) {
        this.arkLog('OPEN_LOCAL_CANCEL');
        return;
      }
      const uri = uris[0];
      // 选择器授权 uri 仅临时可读：读入内存即固化（后续 convertAndOpen 写沙箱）
      const ab = readFileBuf(uri);
      if (ab === null) {
        this.arkLog('OPEN_LOCAL_READERR uri=' + uri);
        return;
      }
      // 文件名/扩展名：uri 尾段（Picker uri 通常带编码文件名；统计型 uri 兜底 docx）
      const label = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
      let ext = '';
      const dot = label.lastIndexOf('.');
      if (dot > -1) {
        ext = label.substring(dot + 1).toLowerCase();
      }
      if (ext !== 'docx' && ext !== 'xlsx' && ext !== 'pptx') {
        this.arkLog('OPEN_LOCAL_EXTBAD label=' + label + ' ext=' + ext);
        return;
      }
      this.arkLog('OPEN_LOCAL_OK label=' + label + ' uri=' + uri + ' size=' + ab.byteLength);
      this.convertAndOpen(ab, ext, label);
    } catch (e) {
      this.arkLog('OPEN_LOCAL_ERR ' + String(e));
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
      if (typeNum === RECENT_TYPE_XLSX) {
        ext = 'xlsx';
      } else if (typeNum === RECENT_TYPE_PPTX) {
        ext = 'pptx';
      } else {
        ext = 'docx';
      }
      // 扩展名兜底（recents 模型缺 type 时从文件名后缀采信白名单）
      if (name.length > 0) {
        const i = name.lastIndexOf('.');
        if (i > 0) {
          const sfx = name.substring(i + 1);
          if (sfx === 'xlsx' || sfx === 'pptx' || sfx === 'docx') {
            ext = sfx;
          }
        }
      }
      if (path.length === 0) {
        this.arkLog('OPEN_RECENT_NOPATH ' + param);
        return 'false';
      }
      // 文件名以 path 尾部为准（loginpage recents 的 name 字段可能被截断/缺失）
      const base = path.substring(path.lastIndexOf('/') + 1);
      // 读源文件字节
      const ab = readFileBuf(path);
      if (ab === null) {
        this.arkLog('OPEN_RECENT_READERR ' + path);
        return 'false';
      }
      return this.convertAndOpen(ab, ext, base.length > 0 ? base : name);
    } catch (e) {
      this.arkLog('OPEN_RECENT_ERR ' + String(e));
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
        this.arkLog('SAVE_BIN_EMPTY');
        return 'false';
      }
      const ab = b64ToBuf(b64);
      // M7 三格式：目标后缀决定 x2t 转换器（doct_bin2docx / xlst_bin2xlsx / pptt_bin2pptx）
      const extU = this.currentOpenExt.length > 0 ? this.currentOpenExt : 'docx';
      const inP = this.hostFilesDir + '/in.bin';
      const outP = this.hostFilesDir + '/save.' + extU;
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('SAVE_BIN_WRITE_ERR ' + inP);
        return 'false';
      }
      // x2t doct_bin2docx（checker 以文件头 DOCY 内容识别，.bin 后缀无碍；POC 保存链实证）
      const rc = x2tConvertSync(x2tXml(inP, outP));
      this.arkLog('SAVE_BIN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        return 'false';
      }
      // zip 头校验 0x50 0x4b（校验比 exist 更严：x2t 产物必须是合法 ZIP）
      const outBuf = readFileBuf(outP);
      if (outBuf === null) {
        this.arkLog('SAVE_BIN_SUBMISS ' + outP);
        return 'false';
      }
      const mk = new Uint8Array(outBuf.slice(0, 2));
      const zipOk = mk[0] === 0x50 && mk[1] === 0x4b;
      this.arkLog('SAVE_BIN_OUT size=' + outBuf.byteLength + ' mk=0x'
        + mk[0].toString(16).padStart(2, '0') + mk[1].toString(16).padStart(2, '0')
        + (zipOk ? ' zipok' : ' ZIPBAD'));
      if (!zipOk) {
        return 'false';
      }
      // 回写源文件（recents 重开即编辑后内容）
      if (this.currentOpenName.length > 0) {
        const srcP = this.hostFilesDir + '/' + this.currentOpenName;
        if (!writeFileBuf(srcP, outBuf)) {
          this.arkLog('SAVE_BIN_BACK_ERR src=' + srcP);
          return 'false';
        }
        this.arkLog('SAVE_BIN_BACK src=' + srcP + ' size=' + outBuf.byteLength);
      }
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_BIN_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 打开共用管线：x2t 转 doct_bin（DOCY;v10;0;+raw 二进制）→ 字节读入内存 → 导航空
   * 官方编辑外壳（LocalStartOpen 就绪后经 onEditorReadyForDoc 注入）。
   * 转换失败或文件不可读 → 不导航，留在欢迎页（避免官方壳报"打开文件错误"弹窗）。
   */
  private convertAndOpen(ab: ArrayBuffer, ext: string, name: string): string {
    try {
      const extU = ext.toLowerCase();
      // M7：源文件持久化到沙箱 <name>（openRecent 的来源 / 保存回写目标 / recents 条目；
      // 系统选择器授权 uri 的读权限只保证 select 返回后短暂有效，字节落盘即固化）
      const srcP = this.hostFilesDir + '/' + name;
      if (!writeFileBuf(srcP, ab)) {
        this.arkLog('OPEN_SRC_WRITE_ERR ' + srcP);
        return 'false';
      }
      // 临时文件本轮 TRUNC 重写（打开链字节在 onEditorReadyForDoc 派发完才由页面拉取；
      // 不主动删除——清理时序与页面 XHR 存在竞态，2026-09-05 已修）
      const inP = this.hostFilesDir + '/open-in.' + extU;
      const outP = this.hostFilesDir + '/open-in.bin';
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('OPEN_TMP_WRITE_ERR ' + inP);
        return 'false';
      }
      // x2t 按输入扩展名自动选 *2doct_bin 转换器；.bin 输出后缀已实机验证（POC 打开链 v10）
      const rc = x2tConvertSync(x2tXml(inP, outP));
      this.arkLog('OPEN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ')');
      if (rc !== 0) {
        this.arkLog('OPEN_X2T_FAIL ext=' + extU);
        return 'false';
      }
      const buf = readFileBuf(outP);
      if (buf === null) {
        this.arkLog('OPEN_BIN_MISS ' + outP);
        return 'false';
      }
      this.pendingOpenFile = true;
      this.currentOpenName = name;
      this.currentOpenExt = extU;
      // M7：recents 真数据 —— 打开过即"最近"，type 按格式枚举上报（单一实现见 recents.ets）
      const typeNum = extU === 'xlsx' ? RECENT_TYPE_XLSX : extU === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
      if (appendRecent(this.hostFilesDir, name, this.hostFilesDir + '/' + name, typeNum)) {
        this.arkLog('RECENTS_APPEND name=' + name + ' type=0x' + typeNum.toString(16));
      } else {
        this.arkLog('RECENTS_APPEND_ERR name=' + name); // 写失败（records 损坏保护）不阻断打开
      }
      this.arkLog('OPEN_CONVERTED bin=' + buf.byteLength);
      this.controller.loadUrl(this.editorUrl(extU, name));
      return 'true';
    } catch (e) {
      this.arkLog('OPEN_CONVERT_ERR ' + String(e));
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
    if (!this.pendingOpenFile) {
      this.arkLog('LSO_NO_PENDING (editor ready, no doc — create:new?)');
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
        this.arkLog('LSO_INJECT_ERR ' + err.code + ' ' + err.message);
      } else {
        this.arkLog('LSO_INJECT_OK ' + res);
      }
      // 注：不再在此删除 open-in.bin —— runJavaScript 回调先于页面 XHR onload 返回，
      // 删文件会让 rawfileLoader 返回 404（实测 XHR 拿到 58B 的 "404: <url>" 响应体），
      // 与字节交付竞态。临时文件本就每轮 TRUNC 覆盖（见 convertAndOpen），无需清理。
    });
    this.pendingOpenFile = false; // 一次性（下次打开重新转换）
    // smoke 诊断（自动验收态才注入，产品无此行为）：页面状态快照（区分"主线程卡死"
    // vs "链未走完但页面活"）。脚本外置 rawfile/onlyoffice/smoke/prof-snap.js
    //（源 scripts/onlyoffice/smoke/——多行可读，不再以 TS 字符串内嵌单行）。
    if (Smoke.enabled()) {
      const snap = Smoke.readScript(this.resourceManager, 'prof-snap.js');
      if (snap === null) {
        this.arkLog('SMOKE_SNAP_MISSING');
      } else {
        setTimeout(() => this.pageJS(snap), 10000);
      }
    }
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.resourceManager = ctx.resourceManager;
    this.hostFilesDir = ctx.filesDir;
    this.webLogPath = ctx.filesDir + '/web_console.txt';
    // 自动验收开关（ability 启动参数 → Smoke；见 smoke.ets / EntryAbility）：无参数 = 产品态
    Smoke.fromParams(getLaunchOptions());
    this.m7Target = Smoke.target;
    // 页面版本号（构建期生成 version.json）：资源变更 → URL ?v= 变化 → 系统缓存失效
    try {
      const vr = this.resourceManager.getRawFileContentSync('onlyoffice/version.json') as Uint8Array;
      const parsed = JSON.parse(u8ToStr(vr)) as Record<string, string>;
      this.pageVer = String(parsed['v'] ?? '0');
    } catch (e) {
      // version.json 缺失（本地调试/旧包）→ 默认 '0'，缓存不失效但功能不受影响
    }
    try {
      const f = fs.openSync(this.webLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(f); // 每次启动清空 web 日志（避免无限增长/读旧日志）
    } catch (e) {
      // 忽略
    }
    this.copySandboxSamples(); // 样本 docx/xlsx/pptx：rawfile → 沙箱 filesDir（open 链走 userfile/；保存回写也落这里）
    // 自动验收诊断直达：跳过 welcome（loginpage 全量渲染可达 60-90s，且末轮设备状态
    // 出现 welcome 卡死）——启动即走打开链进编辑器页，PROF 剖面链（3.4 DI → Gateway
    // 字节注入 → serverId 踢闸 → loading 移除 → 工具栏判据）全靠编辑器页自身，
    // 无需 welcome/sdk。生产态（m7Target 空）即无此路径。
    // M7_DIRECT 前置：onPageEnd（welcome 完成）后触发 open（见 onPageEnd 分支）——
    // 不能放此处 setTimeout 3s：与 welcome 慢加载（60s+）竞争会被覆盖。
    this.m7DirectQueued = this.m7Target.length > 0;
  }

  /** rawfile 样本复制到沙箱 filesDir（open 链走 userfile/ 前缀；编辑/转换产物也在 filesDir）。
   *  仅自动验收态拷贝（m7Target 非空——阶段2 验收与产品分离）：产品路径不产生任何验收样本文件。 */
  private copySandboxSamples(): void {
    if (!this.resourceManager || this.m7Target.length === 0) {
      return;
    }
    for (const name of ['sample.docx', 'sample.xlsx', 'sample.pptx', 'm7-open-test.docx']) {
      try {
        const raw = this.resourceManager.getRawFileContentSync('onlyoffice/' + name) as Uint8Array;
        const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        if (!writeFileBuf(this.hostFilesDir + '/' + name, ab)) {
          this.arkLog('SAMPLE_COPY_ERR ' + name);
        }
      } catch (e) {
        this.arkLog('SAMPLE_COPY_ERR ' + name + ' ' + String(e));
      }
    }
  }

  build() {
    Stack() {
      // 注意：?v=N 是对 ArkWeb http cache 的 cache-bust——rawfileLoader 已剥离 query，
      // 每次提升版本号强制再次取新页面（此 SDK 无 webview.CacheMode 枚举）。
      // 桌面链（M3）：初始页 = 官方 loginpage 欢迎页（产品主界面）；打开文档 → loadUrl 编辑器
      Web({ src: this.homeUrl(), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onInterceptRequest((event) => loadRaw(event.request, this.resourceManager!, this.hostFilesDir, ((m: string) => this.arkLog(m))))
        // 沉浸窗口按目标 URL 切换（主页=关/编辑器页=开；早于加载生效，见 setImmersive）
        .onLoadIntercept((event) => {
          this.setImmersive(event.data.getRequestUrl());
          return false;
        })
        .onControllerAttached(() => {
          // 桌面链桥——window.AscNative（ascshim.js 里 await 它出现再装 window.AscDesktopEditor）。
          // registerJavaScriptProxy 的对象要到页面 (re)load 才出现在 window，故在
          // onControllerAttached（早于加载）注册才对本页生效。
          // 同步方法表：'_call'（JS 端阻塞取返回——官方 CEF V8 语义）、'_onReady'（安装完成）。
          // ascNative 字段保持强引用（registerJavaScriptProxy 代理对象避免被回收）。
          const nativeDispatch = new AscNativeDispatch(this.hostFilesDir, ((m: string) => this.arkLog(m)));
          // LoadFontBase64 桥（引擎桌面路径取字体字节）：rawfile/onlyoffice/fonts/<id>
          // —— 2026-09-05 根因修复（此前缺失 → CJK 字体流空 → 方块）
          nativeDispatch.setRawReader((p: string) => {
            const raw = this.resourceManager?.getRawFileContentSync(p);
            return raw ? (raw as Uint8Array) : null;
          });
          nativeDispatch.setHandler(new ShellCommandHandler(this));
          nativeDispatch.setLocalStartOpenHandler(() => {
            this.onEditorReadyForDoc();
          });
          this.ascNative = new AscNativeBridge(nativeDispatch);
          this.controller.registerJavaScriptProxy(this.ascNative, 'AscNative', ['_call', '_onReady'], []);
        })
        .onPageEnd(() => {
          // 统一日志入口（arkLog）：ArkTS 侧日志与页面 [web] 日志同文件 web_console.txt
          //（hilog 部分环境不可抓），时间戳对齐便于诊断排序
          const cu = this.controller.getUrl();
          this.arkLog('PAGE_END url=' + cu);
          // M7 诊断直达：welcome（首页）完成加载后触发样本打开（等待 welcome 不再与 loadUrl 竞争）
          if (this.m7DirectQueued && cu.indexOf('/main/index.html') < 0) {
            this.m7DirectQueued = false;
            try {
              const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/' + this.m7Target) as Uint8Array;
              const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
              const ext = this.m7Target.substring(this.m7Target.lastIndexOf('.') + 1).toLowerCase();
              this.arkLog('M7_DIRECT_OPEN ' + this.m7Target + ' len=' + ab.byteLength);
              this.convertAndOpen(ab, ext, this.m7Target);
            } catch (e) {
              this.arkLog('M7_DIRECT_ERR ' + String(e));
            }
          }
          // 页面级错误采集（app 初始化失败时 onerror/unhandledrejection 是最直接证据）
          // 注：此段为页面 JS（runJavaScript 注入），内用 console.error 而非 this.arkLog——
          // 页面侧 console.error 经 onConsole 自动落 web_console.txt（统一日志入口）。
          const inject = `(function(){
if(window.__ooh_installed){return;}
window.__ooh_installed=true;
try{var _er0=window.onerror;window.onerror=function(msg,src,ln,cl,err){console.error('JSERR '+String(msg).slice(0,160)+' @'+String(src||'').slice(-40)+':'+ln);if(_er0)return _er0.apply(this,arguments);return false;};}catch(e){}
try{window.addEventListener('unhandledrejection',function(ev){console.error('UHR '+String(ev.reason&&ev.reason.message||ev.reason).slice(0,160));});}catch(e){}
})();`;
          this.pageJS(inject);
        })
        .onErrorReceive((err: OnErrorReceiveEvent) => {
          this.arkLog('Web error: ' + JSON.stringify(err));
        })
        .onConsole((event: OnConsoleEvent) => {
          const line = event.message.getSourceId() + ':' + event.message.getLineNumber()
            + ' ' + event.message.getMessage();
          // 页面日志（web 控制台全量）→ 统一日志入口（落 web_console.txt；诊断基础
          // 设施——页面侧错误 JSERR/UHR 生产可查，不随 ARK_DEBUG 关闭）。
          this.arkLog('[web] ' + line);
          return false;
        })
        .width('100%')
        .layoutWeight(1)
      // 注：M7 FAB「导出/打开」测试按钮已按稳定化计划阶段2删除（2026-09-05）——保存/打开
      // 走官方菜单与欢迎页官方入口（loginpage Open local file → open:folder → onShellCommand）。
    }
    .width('100%')
    .height('100%')
    .align(Alignment.BottomStart)
  }
}
