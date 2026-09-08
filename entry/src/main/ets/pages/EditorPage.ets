import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { x2tConvertSync } from '../common/x2t';
import { AscNativeBridge, AscNativeDispatch, AscCommandHandler } from '../common/ascBridge';
import { Smoke } from '../common/smoke';
import { getLaunchOptions } from '../entryability/EntryAbility';
import { b64ToBuf, readFileBuf, writeFileBuf, x2tXml, u8ToStr } from '../common/bytes';
import { appendRecent, RECENT_TYPE_DOCX, RECENT_TYPE_XLSX, RECENT_TYPE_PPTX } from '../common/recents';
import { P0TabsProbe, P0TabCtx, P0TabPair } from './P0TabsProbe';
import { DocTabHost, DocTabCtx, DocTabPair } from './DocTabHost';

/** ArkTS 侧调试开关：false=仅落 web_console.txt 文件（默认）；true=另 hilog 双写 */
const ARK_DEBUG: boolean = false;
/**
 * 自动验收 = ability 启动参数控制（2026-09-05 用户建议：不写死代码，避免重新编译切换）：
 *   hdc XXX shell aa start -a EntryAbility -b app.fuqidian.pureoffice \
 *     -p m7accept 1 -p m7file sample.xlsx
 *   m7accept=1  → 验收开启（缺省 m7file=sample.docx；文件名须在 rawfile/onlyoffice/ 下，
 *                 且被 copySandboxSamples 复制到沙箱）。
 *   无参数启动 → 产品态：无自动打开/探针/诊断快照/样本拷贝（验收与产品分离，阶段2）。
 * 双重门控：ascshim 的 m7open/m7auto 另按 URL 参数触发（EditorPage 只在该模式拼参数）。
 */

/** 桌面命令处理器（per-instance：每 Web 实例一方，ctx 标识该实例——
 *  open: 任意实例（接收方=发起者页面），save:bin / file:close 路由到该 ctx 的 per-tab 状态） */
class ShellCommandHandler implements AscCommandHandler {
  private owner: EditorPage;
  private ctx: DocTabCtx;

  constructor(owner: EditorPage, ctx: DocTabCtx) {
    this.owner = owner;
    this.ctx = ctx;
  }

  onCommand(cmd: string, param: string, userFlag?: number): string {
    // userFlag 透传（ascBridge 第三参：1 用户保存 / 0 autosave——v2 保存语义，
    // 缺省 1 兜底用户保存）
    return this.owner.onTabCommand(this.ctx, cmd, param, userFlag ?? 1);
  }
}

@Entry
@Component
struct EditorPage {
  private resourceManager: resourceManager.ResourceManager | undefined = undefined;
  private ascNative: AscNativeBridge | undefined = undefined;
  private hostFilesDir: string = '';
  private webLogPath: string = '';
  /** M7 诊断直达配额：onPageEnd 时打开样本（welcome 完成后才触发，避开加载竞争） */
  private m7DirectQueued: boolean = false;
  /** 资源版本自愈 flush 一次守卫（onInstanceReady 周期内）——升级自愈只跑一次 */
  private cacheFlushed: boolean = false;
  // —— P1b（2026-09-08）：「保存目标」等文档身份字段已全部下沉 per-tab 的
  //    DocTabCtx.state（DocTabState：name/ext/saveTarget/savePath/pendingOpen）——
  //    原单例保留字段 savePath 等不再存在（多文档并存下单例必串写，见设计 §3）。

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

  /** 页缓存版本号：构建期按 rawfile/onlyoffice 内容哈希生成（version.json）
   *  → URL ?v=N cache-bust（原 VERSION_BUMP 手工递增已删，阶段3 2026-09-05） */
  private pageVer: string = '0';
  /** 自动验收样本名（Smoke.target 的页面侧副本——smoke 行为见 Smoke 模块/Ascshim；
   *  空 = 产品态：无自动打开/诊断快照/样本拷贝） */
  private m7Target: string = '';
  /** P0 多实例探针（docs/ONLYOFFICE_MULTITAB_DESIGN.md §9；p0tabs=1 启动参数门控，
   *  产品态不挂载本分支——验证骨架，验证完可整体移除） */
  private p0On: boolean = false;
  @State p0Tabs: P0TabPair[] = [];
  /** P1b 容器：tab 数组（home 恒第一，随打开/关闭变化）+ 活动 tab（DocTabHost 受控） */
  @State docTabs: DocTabPair[] = [];
  @State focusTab: number = 0;
  /** tab 标题平行数组（@State 元素可观察——另存为改名即时刷新 chip）；与 docTabs 同步
   *  （index 对应；home 恒 '主页'） */
  @State docTitles: string[] = [];
  /** tab 主题色平行数组（页面 00_theme 0.10 上报：当前主题 CSS 变量
   *  --toolbar-header-<app>）——选中 chip 颜色跟随文档页当前主题色（官方桌面特性；
   *  主题切换重报）。缺省 ''=回退静态 accent。 */
  @State docAccents: string[] = [];
  private docTabSeq: number = 0;

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

  /**
   * 编辑器页 URL —— 官方编辑器应用页（apps/<app>/main/index.html，顶层加载；
   * POC 打开链 v12 真机成功渲染的页面/构建组合）。页面经 Gateway init 后接收
   * openDocumentFromBinary 字节（官方 api.js/Gateway/loadBinary 链）。
   * 注：官方面向 API 调用方的桌面壳页（api/documents/index.html + iframe）组合已实测
   * 到 openDocument 前链；引擎模型初始化依赖 B 架构运行时序，本阶段以顶层页打开（后续 M4+ 返回 iframe 结构）。
   */
  private editorUrl(type: string, title: string, sidVal?: number): string {
    const app = type === 'xlsx' ? 'spreadsheeteditor'
      : type === 'pptx' ? 'presentationeditor' : 'documenteditor';
    let url = 'http://localhost/onlyoffice/webapps/apps/' + app + '/main/index.html?v=' + this.pageVer
      + '&fileType=' + type + '&isDesktop=false&docType=' + type + '&lang=zh-CN&title=' + encodeURIComponent(title)
      // sid=实例唯一化（2026-09-05 修复「关闭文档后再新建显示旧内容」：相同 URL 的
      // 二次导航 ArkWeb 复用引擎实例——页面事件照常（LSO_OPEN_DOCUMENT_OK 收到新模板
      // 字节 len=1086）但旧文档模型残留（真机实锤：新建「未命名的文档」显示 demo-cn 7 页
      // 内容）；sid 强制全新导航。P1b 起 sid=tabId（单调递增，比 Date.now 更保唯一；
      // 语义=tab 标识）。禁止回退为固定 URL（v= 仅防 HTTP 缓存，不防复用）。
      + '&sid=' + (sidVal !== undefined ? sidVal : Date.now());
    // M7 验收态：自动打开后追加 m7auto=1（ascshim：模型就绪→序列化→save:bin→x2t 落盘）
    if (this.m7Target.length > 0) {
      url = url + '&m7auto=1'
        // AI 联网验证 key 走页面 URL 传递（2026-09-08：启动参数链路在 1.4 上不可达
        // ——见 smoke.ets m7args 头注；URL 是 Web 侧已知可靠通道）
        + (Smoke.key.length > 0 ? '&m7key=' + encodeURIComponent(Smoke.key) : '');
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
  /**
   * 桌面命令（per-instance 分派入口——handler 按 ctx 路由；open: 由实例发起即合法，
   * save:bin / file:close 只认发送者 ctx 的 per-tab 状态）。
   */
  onTabCommand(ctx: DocTabCtx, cmd: string, param: string, userFlag: number = 1): string {
    this.arkLog('[TabCommand] ' + ctx.kind + ctx.id + ' ' + cmd + ' ' + param.slice(0, 300));
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
      // userFlag=1 用户主动保存（补录 recents）/ 0 autosave（不补录——2026-09-05）
      return this.saveBinRaw(ctx, param, userFlag > 0);
    }
    if (cmd === 'save:as') {
      // 官方另存为（asc_Save isSaveAs=true → 同格式）：40_save 发来的是**序列化流 DOCY**
      // （不是文件字节！）→ 先 x2t doct_bin2docx（保存链同款，saveBinRaw 'none' 分支的
      // doSaveAs 入参即此产物）→ 系统保存框（doSaveAs 既有链：uri 落盘+saveTarget/
      // savePath 身份演进+recents 补录）。直接写 DOCY=伪 docx（外部打开损坏——
      // 2026-09-08 真机发现 SAVE_AS_WRITE 落盘的是 doct bin 流，必修）。不同格式导出
      // 走「下载为」（暂未支持，菜单已隐藏——2026-09-08 用户决策）。
      return this.saveAsBin(ctx, param);
    }
    if (cmd === 'go:folder') {
      // 官方桌面"返回"（FileMenu 返回到文档列表）→ tab 化语义：激活主页 tab（doc 实例
      // 保留——文档仍开着，点 doc chip 即回，状态零重建）
      this.arkLog('GOBACK -> home tab');
      this.focusTab = 0;
      return 'true';
    }
    if (cmd === 'files:explore') {
      // 官方面板「在文件夹中显示」→ sdk.execCommand('files:explore', {path,id,hash})
      // B 架构无系统级「文件管理器定位文件」API（桌面 C++ OpenDir 等价物）——降级为
      // toast 显示文件绝对路径（用户可在系统文件管理/导出中按路径查找；2026-09-05）
      try {
        const fp = JSON.parse(param) as Record<string, Object>;
        const p = String(fp['path'] ?? '');
        this.arkLog('FILES_EXPLORE path=' + p);
        promptAction.showToast({ message: '文件位置：' + p, duration: 3000 });
      } catch (e) {
        this.arkLog('FILES_EXPLORE_ERR ' + String(e));
      }
      return 'true';
    }
    if (cmd === 'editor:event') {
      // 官方桌面"关闭文件"（FileMenu miExit → file:exit → Desktop.js:640）
      try {
        const oe = JSON.parse(param) as Record<string, Object>;
        if (String(oe['action']) === 'file:close') {
          this.arkLog('CLOSE_FILE -> doc tab close id=' + ctx.id);
          this.closeDocTab(ctx.id);
        }
      } catch (e) {
        this.arkLog('EDITOR_EVENT_ERR ' + String(e));
      }
      return 'true';
    }
    // 其余桌面命令（files:check 等）M5 登记降级，当前 no-op
    return 'true';
  }

  /** 另存为命令体（per-tab：临时文件带 ctx 后缀——多文档隔离） */
  private saveAsBin(ctx: DocTabCtx, param: string): string {
    try {
      const abS = b64ToBuf(param);
      if (abS === null || abS.byteLength === 0) {
        this.arkLog('SAVE_AS_B64_BAD len=' + param.length);
        return 'false';
      }
      const extA = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const inA = ctx.tabPath('saveas-in.bin');
      const outA = ctx.tabPath('saveas-out.' + extA);
      if (!writeFileBuf(inA, abS)) {
        this.arkLog('SAVE_AS_WRITE_ERR ' + inA);
        return 'false';
      }
      const rcA = x2tConvertSync(x2tXml(inA, outA));
      this.arkLog('SAVE_AS_X2T rc=0x' + (rcA >>> 0).toString(16) + ' tab=' + ctx.id);
      if (rcA !== 0) {
        this.arkLog('SAVE_AS_X2T_FAIL');
        return 'false';
      }
      const docxBuf = readFileBuf(outA);
      if (docxBuf === null) {
        this.arkLog('SAVE_AS_SUBMISS ' + outA);
        return 'false';
      }
      this.doSaveAs(ctx, docxBuf);
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_AS_ERR ' + String(e));
      return 'false';
    }
  }

  /** 官方语言包词条缓存（懒加载，一次；三 app 键值） */
  private defaultNames: Record<string, string> | null = null;

  /**
   * 新建文档默认名 —— 从官方语言包读取（rawfile webapps/apps/<app>/main/locale/
   * zh.json，键 [DE|SSE|PE].Controllers.LeftMenu.newDocumentTitle = 官方桌面「新建」
   * 默认名：未命名的文档/未命名的电子表格/未命名的演示）。语言文件与 UI lang 对齐
   * （editorUrl lang=zh-CN → locale/zh.json；未来多语言换 lang 即换文件）。
   * 兜底仅在语言包读失败/键缺失时给直写中文（正常路径零硬编码文本）。
   */
  private defaultDocName(ext: string): string {
    try {
      if (this.defaultNames === null) {
        this.defaultNames = {};
        const lang = 'zh'; // 与 editorUrl lang=zh-CN 对齐
        const apps: [string, string, string][] = [
          ['docx', 'documenteditor', 'DE'],
          ['xlsx', 'spreadsheeteditor', 'SSE'],
          ['pptx', 'presentationeditor', 'PE']
        ];
        for (let i = 0; i < apps.length; i++) {
          const e: string = apps[i][0];
          const app: string = apps[i][1];
          const pfx: string = apps[i][2];
          const raw = this.resourceManager!.getRawFileContentSync(
            'onlyoffice/webapps/apps/' + app + '/main/locale/' + lang + '.json') as Uint8Array;
          const dict = JSON.parse(u8ToStr(raw)) as Record<string, string>;
          this.defaultNames[e] = dict[pfx + '.Controllers.LeftMenu.newDocumentTitle'] ?? '';
        }
      }
    } catch (e) {
      this.arkLog('DEFAULT_NAME_LOCALE_ERR ' + String(e));
    }
    const fromLoc = this.defaultNames && this.defaultNames[ext];
    if (fromLoc !== null && fromLoc !== undefined && fromLoc.length > 0) {
      return fromLoc + '.' + ext;
    }
    // 兜底（语言包读取失败/键缺失时保底；正常路径走上面官方词条）
    const base = ext === 'xlsx' ? '未命名的电子表格'
      : ext === 'pptx' ? '未命名的演示' : '未命名的文档';
    return base + '.' + ext;
  }

  /** create:new（word）：空文档模板 → 与打开同管线注入（官方 C++ 对新建同样发 DocumentEndLoad） */
  private openNewFile(ext: string): string {
    try {
      // 空模板（rawfile/onlyoffice/templates/empty.<ext>；docx/xlsx/pptx 均由
      // 官方样本/结构保证合法——xlsx/pptx 生成见 scripts/onlyoffice/make_empty_templates.py）
      const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/templates/empty.' + ext) as Uint8Array;
      const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      this.arkLog('CREATE_NEW empty.' + ext + ' len=' + ab.byteLength);
      // 新建（未保存）不进「最近使用」——官方桌面语义：recents=打开过的文件；
      // 未保存的新建无独立文件身份，点开即编辑 — 2026-09-05 修复（原 convertAndOpen
      // 无条件 appendRecent，创建一轮就把未命名文档堆进 recents，用户实测质疑）
      // 2026-09-05 根因修正：newDoc=true（零状态空文档，无模板文件/无写入源）
      return this.openNewTabEntry(ab, ext, this.defaultDocName(ext), false, true);
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
      // userUri=系统选择器真实位置——保存目标=用户原文件（覆盖式保存，2026-09-05）
      this.openNewTabEntry(ab, ext, label, true, false, uri);
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
      // userUri=recents 记录的真实位置（uri→保存覆盖用户文件；历史沙箱路径→兼容）
      return this.openNewTabEntry(ab, ext, base.length > 0 ? base : name, true, false, path);
    } catch (e) {
      this.arkLog('OPEN_RECENT_ERR ' + String(e));
      return 'false';
    }
  }

  /**
   * 另存为（per-tab：ctx.state 唯一身份源）：系统保存对话框（DocumentViewPicker.save）
   * → 用户选位置/文件名 → 字节落盘（uri 写）→ 身份演进（'none'→'uri'）→ recents 补录
   * → tab 标题刷新（docTitles 平行数组——@State 元素级可观察）。取消 → 不动。
   */
  private async doSaveAs(ctx: DocTabCtx, outBuf: ArrayBuffer): Promise<void> {
    try {
      const aCtx = getContext(this) as common.UIAbilityContext;
      const dvp = new picker.DocumentViewPicker(aCtx);
      const opts = new picker.DocumentSaveOptions();
      // 默认名：已保存文档=当前名；新建=语言包中文未命名（defaultDocName——
      // 2026-09-08 补：doSaveAs 兜底名原写死 Unnamed.，与 openNewFile 语言包驱动对齐）
      const defName = ctx.state.name.length > 0 ? ctx.state.name : this.defaultDocName(ctx.state.ext);
      opts.newFileNames = [defName];
      const uris = await dvp.save(opts);
      if (!uris || uris.length === 0) {
        this.arkLog('SAVE_AS_CANCEL tab=' + ctx.id);
        return;
      }
      const uri = uris[0];
      const ok = writeFileBuf(uri, outBuf);
      this.arkLog('SAVE_AS_WRITE uri=' + uri + ' ok=' + ok + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
      if (!ok) {
        this.arkLog('SAVE_AS_WRITE_ERR ' + uri);
        return;
      }
      ctx.state.savePath = uri; // 身份=真实位置（后续保存覆盖写它）
      // 文件身份 = 用户选择的位置（recents path=真实 uri）；文件名以 uri 尾段为准
      const base = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
      if (base.length > 0) {
        ctx.state.name = base;
        const dot = base.lastIndexOf('.');
        if (dot > 0) {
          const e2 = base.substring(dot + 1).toLowerCase();
          if (e2 === 'docx' || e2 === 'xlsx' || e2 === 'pptx') {
            ctx.state.ext = e2;
          }
        }
      }
      // 身份演进（saveTarget 单点）：'none' → 'uri'——页面经 save:type 同步询问即命中。
      // 不写沙箱镜像：用户数据只存用户选择的位置（重开后由打开链自动建立工作副本）。
      ctx.state.saveTarget = 'uri';
      // tab 标题刷新（docTitles 平行数组 index 与 docTabs 一致）
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === ctx) {
          const tArr = this.docTitles.slice();
          tArr[i] = base.length > 0 ? base : this.defaultDocName(ctx.state.ext);
          this.docTitles = tArr;
          break;
        }
      }
      if (ctx.state.name.length > 0) {
        const typeNum = ctx.state.ext === 'xlsx' ? RECENT_TYPE_XLSX
          : ctx.state.ext === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
        // path=真实保存位置（uri）；重开走 readFileBuf(uri)（picker 授权持久）
        if (appendRecent(this.hostFilesDir, ctx.state.name, uri, typeNum)) {
          this.arkLog('RECENTS_APPEND_SAVEAS name=' + ctx.state.name + ' path=' + uri);
        }
      }
    } catch (e) {
      this.arkLog('SAVE_AS_ERR ' + String(e));
    }
  }

  /**
   * @param userSaved 用户主动保存（true=补录 recents）/ autosave（false=只落盘不打扰
   * 「最近使用」；2026-09-05 新建即 autosave 的连锁修正）
   */
  /**
   * M4 保存链本体（saveBinRaw）：ascshim saveDocument 接手 → 官方 asc_nativeGetFileData
   * （BinaryFileWriter 序列化当前模型 → DOCY;v10，与打开链 in.bin 同格式）→ save:bin
   * 至此：写沙箱 in.bin → x2t doct_bin2docx → save.<ext>（zip 头校验）→ 回写当前源文件。
   * userSaved=1 用户保存（补录 recents）/ 0 autosave（只落盘不补录，2026-09-05 语义）。
   */
  /**
   * M4 保存链本体（per-tab 版：ctx.state 身份源 + ctx.tabPath 临时文件——多文档隔离）：
   * save:bin ← ascshim saveDocument 接手 → 官方 asc_nativeGetFileData（BinaryFileWriter
   * 序列化当前模型 → DOCY;v10）→ 本方法：写 per-tab in.<id>.bin → x2t doct_bin2docx →
   * save.<id>.<ext>（zip 头校验）→ 回写当前源文件（ctx.state.savePath）。
   */
  private saveBinRaw(ctx: DocTabCtx, b64: string, userSaved: boolean = true): string {
    try {
      if (b64.length === 0) {
        this.arkLog('SAVE_BIN_EMPTY');
        return 'false';
      }
      const ab = b64ToBuf(b64);
      // M7 三格式：目标后缀决定 x2t 转换器（doct_bin2docx / xlst_bin2xlsx / pptt_bin2pptx）
      const extU = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const inP = ctx.tabPath('in.bin');
      const outP = ctx.tabPath('save.' + extU);
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
      // 新文件首次保存 = 另存为（官方桌面语义：无文件身份 → 弹系统保存对话框选位置；
      // 2026-09-05 用户「点保存应弹保存位置，却直接保存了」）。x2t 产物 outBuf 交接给
      // doSaveAs（async：dvp.save → uri 落盘 + 沙箱同步 + recents + 复位 isNewUnsaved）。
      // 对话框异步期间先回 'true'（保存受理）；取消=未保存（isNewUnsaved 仍 true，
      // 下次保存再弹）。
      // v2 保存决策（单一事实源 saveTarget，per-tab）：
      if (userSaved && ctx.state.saveTarget === 'none') {
        // 新建无身份 + 用户保存 → 弹另存为（async：dvp.save → uri 落盘 → 'none'→'uri'）
        this.arkLog('SAVE_AS_DIALOG name=' + ctx.state.name + ' tab=' + ctx.id);
        this.doSaveAs(ctx, outBuf);
        return 'true';
      }
      if (ctx.state.name.length > 0) {
        if (ctx.state.saveTarget === 'uri' && ctx.state.savePath.length > 0) {
          // 已另存为：覆写真实位置（用户数据=savePath uri）
          const okUri = writeFileBuf(ctx.state.savePath, outBuf);
          this.arkLog('SAVE_BIN_URI ok=' + okUri + ' uri=' + ctx.state.savePath + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
          if (!okUri) {
            this.arkLog('SAVE_BIN_URI_ERR ' + ctx.state.savePath);
            return 'false';
          }
        }
        // 引擎工作副本同步（打开/另存为后重开链以最新内容起步；不参与 recents/用户
        // 数据——用户文件=savePath（uri 或沙箱工作副本，2026-09-05）
        const srcP = this.hostFilesDir + '/' + ctx.state.name;
        if (!writeFileBuf(srcP, outBuf)) {
          this.arkLog('SAVE_BIN_BACK_ERR src=' + srcP);
          return 'false';
        }
        this.arkLog('SAVE_BIN_BACK src=' + srcP + ' size=' + outBuf.byteLength + ' tab=' + ctx.id);
        // 保存成功 = 文件身份成立（官方桌面语义：保存后的文件进「最近使用」；
        // 新建在打开链已禁 recents（openNewTabEntry addRecent=false）——用户保存即补录；
        // appendRecent 同名去旧置顶，已打开文件的保存同样刷新置顶。
        // 仅用户保存补录（自动保存/autosave 不打扰列表——2026-09-05 用户实测后修正）。
        if (userSaved) {
          const saveType = ctx.state.ext === 'xlsx' ? RECENT_TYPE_XLSX
            : ctx.state.ext === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
          // recents.path：真实位置优先（uri），否则沙箱（打开链/兼容）
          const recentPath = ctx.state.saveTarget === 'uri' ? ctx.state.savePath : srcP;
          if (appendRecent(this.hostFilesDir, ctx.state.name, recentPath, saveType)) {
            this.arkLog('RECENTS_APPEND_SAVE name=' + ctx.state.name);
          }
        }
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
  /**
   * @param addRecent 是否写入「最近使用」（打开=写入；新建=不写，2026-09-05）
   * @param newDoc  新建语义（2026-09-05 根因修正「创建≠打开文件」）：不落模板源文件、
   *                currentOpenName 置空（无文件身份——官方桌面语义：新建即零状态，保存
   *                首次=另存为；此前把新建当「打开模板文件」导致保存/recents 路径/未保存
   *                语义全部错位）
   */
  /**
   * 打开管线（per-tab 版，P1b——多文档并存的基础）：
   * 先建 doc 实例（tab id 定名）→ 沙箱工作副本（newDoc 跳过）→ x2t 转换
   * （临时文件带 tab 后缀：open-in.<id>.*——多实例互不踩）→ per-tab 身份 state
   * （name/ext/saveTarget/savePath/pendingOpen 全部下沉）→ 追加 tab 并列（不再关旧开新）。
   * m7 验收锁（设计 §6.4）：验收态单 tab 隧道（关旧开新）——产品态自由多开。
   */
  private openNewTabEntry(ab: ArrayBuffer, ext: string, name: string, addRecent: boolean = true,
    newDoc: boolean = false, userUri?: string): string {
    try {
      const extU = ext.toLowerCase();
      if (Smoke.enabled()) {
        const oldDocs = this.docTabs.filter((p: DocTabPair) => p.ctx.kind === 'doc');
        for (let i = 0; i < oldDocs.length; i++) {
          this.closeDocTab(oldDocs[i].ctx.id);
        }
      }
      // 身份对象先行（tabId 唯一化）：临时文件/url/state 全部以 id 定名
      this.docTabSeq += 1;
      const ctx = new DocTabCtx(this.docTabSeq, 'doc', name, '',
        this.resourceManager!, this.hostFilesDir,
        ((m: string) => this.arkLog(m)), ((c: DocTabCtx) => this.onInstanceReady(c)),
        ((c: DocTabCtx) => this.onPageEndCB(c)));
      // M7：源文件持久化到沙箱 <name>（openRecent 的来源 / 保存回写目标 / recents 条目；
      // 选择器授权 uri 读权限短暂——字节落盘即固化）。newDoc 跳过（无文件身份，2026-09-05）
      if (!newDoc) {
        const srcP = this.hostFilesDir + '/' + name;
        if (!writeFileBuf(srcP, ab)) {
          this.arkLog('OPEN_SRC_WRITE_ERR ' + srcP);
          return 'false';
        }
      }
      // 临时文件 per-tab（TRUNC 覆盖语义不变；不在回调里删——与页面 XHR 竞态，2026-09-05）
      const inP = ctx.tabPath('open-in.' + extU);
      const outP = ctx.tabPath('open-in.bin');
      if (!writeFileBuf(inP, ab)) {
        this.arkLog('OPEN_TMP_WRITE_ERR ' + inP);
        return 'false';
      }
      // x2t 按输入扩展名自动选 *2doct_bin 转换器；.bin 输出后缀已实机验证（POC 打开链 v10）
      const rc = x2tConvertSync(x2tXml(inP, outP));
      this.arkLog('OPEN_X2T rc=0x' + (rc >>> 0).toString(16) + ' (' + rc + ') tab=' + ctx.id);
      if (rc !== 0) {
        this.arkLog('OPEN_X2T_FAIL ext=' + extU);
        return 'false';
      }
      const buf = readFileBuf(outP);
      if (buf === null) {
        this.arkLog('OPEN_BIN_MISS ' + outP);
        return 'false';
      }
      // per-tab 身份赋值（原保存链单例字段→ctx.state）
      if (newDoc) {
        ctx.state.name = '';
        ctx.state.ext = extU;
        ctx.state.saveTarget = 'none';
        ctx.state.savePath = '';
      } else {
        ctx.state.name = name;
        ctx.state.ext = extU;
        if (userUri !== undefined && userUri.length > 0) {
          // 历史 recents 的 path 是沙箱路径（=工作副本本身）→ 保存目标=沙箱；
          // 真实位置（file:/// 等）→ 保存覆盖用户文件
          ctx.state.saveTarget = userUri.indexOf(this.hostFilesDir) === 0 ? 'sandbox' : 'uri';
          ctx.state.savePath = userUri;
        } else {
          ctx.state.saveTarget = 'sandbox';
          ctx.state.savePath = this.hostFilesDir + '/' + name;
        }
        // recents 真数据（仅打开 addRecent=true 写入；新建不写）——path=保存目标真实路径
        if (addRecent) {
          const typeNum = extU === 'xlsx' ? RECENT_TYPE_XLSX : extU === 'pptx' ? RECENT_TYPE_PPTX : RECENT_TYPE_DOCX;
          if (appendRecent(this.hostFilesDir, name, ctx.state.savePath, typeNum)) {
            this.arkLog('RECENTS_APPEND name=' + name + ' type=0x' + typeNum.toString(16));
          } else {
            this.arkLog('RECENTS_APPEND_ERR name=' + name);
          }
        }
      }
      ctx.state.pendingOpen = true;
      ctx.url = this.editorUrl(extU, name, ctx.id); // sid=tabId：强制唯一加载 + 事件归属
      const arr = this.docTabs.slice();
      const tArr = this.docTitles.slice();
      const aArr = this.docAccents.slice();
      arr.push(new DocTabPair(ctx));
      tArr.push(name.length > 0 ? name : this.defaultDocName(extU));
      aArr.push('');
      this.docTabs = arr;
      this.docTitles = tArr;
      this.docAccents = aArr;
      this.focusTab = this.docTabs.length - 1;
      this.arkLog('P1B_OPEN_TAB id=' + ctx.id + ' ext=' + extU + ' bin=' + buf.byteLength
        + ' target=' + ctx.state.saveTarget + ' name=' + name);
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
  /**
   * LocalStartOpen 回调（per-instance：dispatch 装配时绑定 ctx）——字节注入该实例。
   * 多文档下每个 doc 实例独立就绪、独立注入（open-in.<id>.bin 隔离）。
   */
  private onDocReady(docC: DocTabCtx): void {
    if (!docC.state.pendingOpen) {
      this.arkLog('LSO_NO_PENDING (editor ready, no doc — create:new?) tab=' + docC.id);
      return;
    }
    // tab 关闭守卫（探针注入不再进已消亡实例；注入路径本身判 null 不崩）
    const closedTab = (): boolean => {
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === docC) {
          return false;
        }
      }
      return true;
    };
    // 页面 XHR 拉取沙箱 doct_bin（rawfileLoader 已拦 userfile/ → filesDir 返回真字节）→
    // window.postMessage openDocumentFromBinary（官方 api.js/Gateway/loadBinary →
    // asc_openDocumentFromBytes，checkStreamSignature 嗅探 DOCY 签名 —— web/服务器链，
    // 与 3.7 web 语义（编辑器页删除 AscDesktopEditor）配套；桌面 doffline 链路待桌面
    // 字体/native 通路三件套齐备后再启用）。
    const js = '(function(){'
      + 'try{var x=new XMLHttpRequest();'
      + 'x.open("GET","http://localhost/userfile/open-in.' + docC.id + '.bin?v="+Date.now(),true);'
      + 'x.responseType="arraybuffer";'
      + 'x.onload=function(){try{var ab=x.response;'
      + 'if(!ab||!ab.byteLength){console.error("LSO_XHR_EMPTY st="+x.status);return;}'
      + 'window.postMessage({command:"openDocumentFromBinary",data:ab},"*");'
      + 'console.error("LSO_OPEN_DOCUMENT_OK len="+ab.byteLength);'
      + '}catch(e){console.error("LSO_LOAD_ERR "+String(e));}};'
      + 'x.onerror=function(){console.error("LSO_XHR_ERR st="+x.status);};'
      + 'x.send(null);}catch(e){console.error("LSO_INJECT_ERR "+String(e));}})();';
    docC.controller.runJavaScript(js, (err: BusinessError, res: string) => {
      if (err) {
        this.arkLog('LSO_INJECT_ERR ' + err.code + ' ' + err.message);
      } else {
        this.arkLog('LSO_INJECT_OK ' + res);
      }
      // 注：不再在此删除临时文件 —— runJavaScript 回调先于页面 XHR onload 返回，
      // 删文件会让 rawfileLoader 返回 404（实测 XHR 拿到 58B 的 "404: <url>" 响应体），
      // 与字节交付竞态。临时文件本就每轮 TRUNC 覆盖（见 openNewTabEntry），无需清理。
    });
    docC.state.pendingOpen = false; // 一次性（下次打开重新转换）
    // smoke 诊断（自动验收态才注入，产品无此行为）：页面状态快照（区分"主线程卡死"
    // vs "链未走完但页面活"）。脚本外置 rawfile/onlyoffice/smoke/prof-snap.js
    //（源 scripts/onlyoffice/smoke/——多行可读，不再以 TS 字符串内嵌单行）。
    if (Smoke.enabled()) {
      const snap = Smoke.readScript(this.resourceManager, 'prof-snap.js');
      if (snap === null) {
        this.arkLog('SMOKE_SNAP_MISSING');
      } else {
        const c1 = docC;
        setTimeout(() => {
          if (!closedTab()) {
            c1.js(snap, '');
          }
        }, 10000);
      }
      // AI 联网验证（2026-09-07 方案 A 放行）：与 AI 插件同形态的 fetch 直连
      // DeepSeek /v1（key 经启动参数 m7key 注入，不进 git/不落盘；见 ai_fetch_test.js）。
      const aiTest = Smoke.readScript(this.resourceManager, 'ai_fetch_test.js');
      if (aiTest === null) {
        this.arkLog('SMOKE_AITEST_MISSING');
      } else {
        const c2 = docC;
        setTimeout(() => {
          if (!closedTab) {
            c2.js(aiTest.replace('__AI_KEY__', Smoke.key), '');
          }
        }, 15000);
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
    // P0 探针：启动参数 p0tabs=1 → 挂双实例验证骨架（tabs 数组用于 build 分支判断）
    this.p0On = getLaunchOptions()['p0tabs'] === '1';
    if (this.p0On) {
      try {
        const logFn: (m: string) => void = ((m: string) => this.arkLog(m));
        this.p0Tabs = [
          new P0TabPair(new P0TabCtx(1, '主页', this.homeUrl(), this.resourceManager!, this.hostFilesDir, logFn)),
          new P0TabPair(new P0TabCtx(2, 'P0 文档', this.editorUrl('docx', 'P0 验证'), this.resourceManager!, this.hostFilesDir, logFn))
        ];
        this.arkLog('P0_TABS_INIT n=' + this.p0Tabs.length
          + ' t1=' + this.p0Tabs[1].ctx.url);
      } catch (e) {
        this.arkLog('P0_TABS_ERR ' + String(e));
      }
    }
    // P1a 容器初始化：主页实例恒第一（常驻；doc 由打开/新建命令动态追加）
    if (!this.p0On) {
      try {
        const homeCtx = new DocTabCtx(0, 'home', '主页', this.homeUrl(),
          this.resourceManager!, this.hostFilesDir,
          ((m: string) => this.arkLog(m)), ((c: DocTabCtx) => this.onInstanceReady(c)),
          ((c: DocTabCtx) => this.onPageEndCB(c)));
        this.docTabs = [new DocTabPair(homeCtx)];
        this.docTitles = ['主页'];
        this.docAccents = [''];
        this.arkLog('P1A_TABS_INIT home=' + homeCtx.url);
      } catch (e) {
        this.arkLog('P1A_TABS_ERR ' + String(e));
      }
    }
  }

  /** rawfile 样本复制到沙箱 filesDir（open 链走 userfile/ 前缀；编辑/转换产物也在 filesDir）。
   *  仅自动验收态拷贝（m7Target 非空——阶段2 验收与产品分离）：产品路径不产生任何验收样本文件。
   *  样本集中 at rawfile/onlyoffice/smoke/samples/（2026-09-06 用户：smoke 文件单独
   *  目录存放；install_smoke 整目录拷贝保留 samples/ 子目录——读取须加 samples/ 段）。 */
  private copySandboxSamples(): void {
    if (!this.resourceManager || this.m7Target.length === 0) {
      return;
    }
    for (const name of ['sample.docx', 'sample.xlsx', 'sample.pptx', 'm7-open-test.docx']) {
      try {
        const raw = this.resourceManager.getRawFileContentSync('onlyoffice/smoke/samples/' + name) as Uint8Array;
        const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        if (!writeFileBuf(this.hostFilesDir + '/' + name, ab)) {
          this.arkLog('SAMPLE_COPY_ERR ' + name);
        }
      } catch (e) {
        this.arkLog('SAMPLE_COPY_ERR ' + name + ' ' + String(e));
      }
    }
  }

  /**
   * 页面实例就绪（Web onControllerAttached，每实例一次——节点复用不重装配）：
   * 桥装配（AscNative 注册）。P1a：装配与业务仍单例（handler/saveTarget 读 this）；
   * P1b 起 per-tab 化。升级自愈 cacheFlush 仅 home 实例执行（removeCache 对同一
   * user data dir 全实例生效——产品级一次即可）。
   */
  private onInstanceReady(ctx: DocTabCtx): void {
    // 升级自愈（2026-09-06 注释原文）：install -r 整包替换 rawfile，但 WebView 磁盘
    // 缓存（data/storage/el2/base/cache/web/Cache，install -r 不清空）中同 URL 旧响应
    // 可能被命中——主页面/编辑页 URL 已带 ?v=<资源哈希>（cache-bust）自愈，但插件
    // iframe 等子资源引用无版本参数（如 plugins/v1/plugins.js）——兜底：资源版本
    // 变化后首次启动 flush 一次（once per version；记录于 files/app_version.json）。
    // 前车之鉴：不得用缓存清理解释页面行为 bug。
    if (ctx.kind === 'home' && !this.cacheFlushed) {
      this.cacheFlushed = true;
      try {
        const vRaw = this.resourceManager?.getRawFileContentSync('onlyoffice/version.json') as Uint8Array | undefined;
        const cur = vRaw ? String((JSON.parse(u8ToStr(vRaw)) as Record<string, string>).v || '') : '';
        const metaP = this.hostFilesDir + '/app_version.json';
        let old = '';
        const oldB = readFileBuf(metaP);
        if (oldB) {
          old = u8ToStr(new Uint8Array(oldB)).trim();
        }
        if (old !== cur) {
          ctx.controller.removeCache(true);
          const curBytes = new Uint8Array(cur.length);
          for (let bi = 0; bi < cur.length; bi++) {
            curBytes[bi] = cur.charCodeAt(bi);
          }
          writeFileBuf(metaP, curBytes);
          this.arkLog('VERSION_CACHE_FLUSH v=' + cur + ' (was ' + (old || 'none') + ')');
        }
      } catch (ce) {
        this.arkLog('VERSION_CACHE_ERR ' + String(ce));
      }
    }
    // ascNative 字段保持强引用（registerJavaScriptProxy 代理对象避免被回收）。
    const nativeDispatch = new AscNativeDispatch(this.hostFilesDir, ((m: string) => this.arkLog(m)));
    // LoadFontBase64 桥（引擎桌面路径取字体字节）：rawfile/onlyoffice/fonts/<id>
    // —— 2026-09-05 根因修复（此前缺失 → CJK 字体流空 → 方块）
    nativeDispatch.setRawReader((p: string) => {
      const raw = this.resourceManager?.getRawFileContentSync(p);
      return raw ? (raw as Uint8Array) : null;
    });
    // per-instance 装配：handler/LocalStartOpen/save:type 全部绑定该 ctx
    // （P1b 核心——多文档并存：每实例的保存/注入只走自己的 per-tab 状态）
    nativeDispatch.setHandler(new ShellCommandHandler(this, ctx));
    nativeDispatch.setLocalStartOpenHandler(() => {
      this.onDocReady(ctx);
    });
    // 主题色上报（页面 00_theme 0.10 → 本实例的 chip 激活色）
    nativeDispatch.setThemeReporter((payload: string) => {
      return this.onThemeReport(ctx, payload);
    });
    // save:type 询问（per-tab 单一事实源）：页面 asc_Save 同步询问保存目标——
    // 'none'（autosave 跳过/用户保存→另存为）| 'sandbox' | 'uri'
    nativeDispatch.setSaveTargetReader(() => ctx.state.saveTarget);
    this.ascNative = new AscNativeBridge(nativeDispatch);
    ctx.controller.registerJavaScriptProxy(this.ascNative, 'AscNative', ['_call', '_onReady'], []);
    this.arkLog('P1A_INSTANCE_READY kind=' + ctx.kind + ' id=' + ctx.id);
  }

  /** onPageEnd（每实例首次到达）：M7 直达（仅 home）+ 页面级错误采集（每实例幂等） */
  private onPageEndCB(ctx: DocTabCtx): void {
    const cu = ctx.controller.getUrl();
    // M7 诊断直达：welcome（首页）完成加载后触发样本打开（避开加载竞争；仅 home）
    if (ctx.kind === 'home' && this.m7DirectQueued && cu.indexOf('/main/index.html') < 0) {
      this.m7DirectQueued = false;
      try {
        const raw = this.resourceManager!.getRawFileContentSync('onlyoffice/smoke/samples/' + this.m7Target) as Uint8Array;
        const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        const ext = this.m7Target.substring(this.m7Target.lastIndexOf('.') + 1).toLowerCase();
        this.arkLog('M7_DIRECT_OPEN ' + this.m7Target + ' len=' + ab.byteLength);
        this.openNewTabEntry(ab, ext, this.m7Target, true, false);
      } catch (e) {
        this.arkLog('M7_DIRECT_ERR ' + String(e));
      }
    }
    // 页面级错误采集（onerror/unhandledrejection 是最直接证据；JS 内幂等 __ooh_installed）
    const inject = `(function(){
if(window.__ooh_installed){return;}
window.__ooh_installed=true;
try{var _er0=window.onerror;window.onerror=function(msg,src,ln,cl,err){console.error('JSERR '+String(msg).slice(0,160)+' @'+String(src||'').slice(-40)+':'+ln);if(_er0)return _er0.apply(this,arguments);return false;};}catch(e){}
try{window.addEventListener('unhandledrejection',function(ev){console.error('UHR '+String(ev.reason&&ev.reason.message||ev.reason).slice(0,160));});}catch(e){}
})();`;
    ctx.js(inject, '');
  }

  /**
   * 关闭 doc tab（file:close / tab ×）：移除节点（挂载即销毁）+ 标题同步。
   * 关闭后聚焦相邻（2026-09-09 用户需求）：关激活 tab → 选随后一个顶替原位的
   * （关尾 → 前一个）；关非激活 tab → 焦点保持指向原来那个（数组前移一位）。
   * 无未保存守卫（P2 引入：官方 _state.isDocModified 读取——设计 §6.3）。
   */
  private closeDocTab(id: number): void {
    try {
      let idx = -1;
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx.id === id) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        return;
      }
      const wasFocus = this.focusTab === idx;
      const arr = this.docTabs.slice();
      arr.splice(idx, 1);
      this.docTabs = arr;
      const tArr = this.docTitles.slice();
      tArr.splice(idx, 1);
      this.docTitles = tArr;
      const aArr = this.docAccents.slice();
      aArr.splice(idx, 1);
      this.docAccents = aArr;
      if (wasFocus) {
        // 相邻归位：原位置（idx）由后一个顶替；关的是最后一个 → 前一个
        this.focusTab = Math.min(idx, this.docTabs.length - 1);
      } else if (this.focusTab > idx) {
        // 非激活关闭：数组前移，焦点保持指向同一文档
        this.focusTab = this.focusTab - 1;
      }
      this.arkLog('P1B_CLOSE_TAB id=' + id + ' focus=' + this.focusTab);
    } catch (e) {
      this.arkLog('P1A_CLOSE_TAB_ERR ' + String(e));
    }
  }

  /**
   * 主题色上报处理（页面 00_theme 0.10）：payload JSON {app,color}——color=当前主题
   * CSS 变量 --toolbar-header-<app> 的实际值（官方 colors-table-<theme>.less 定义
   * 为主题内配置，主题切换重报）。缓存到 docAccents（索引与 docTabs 对齐——选中
   * chip 颜色跟随文档页当前主题色，官方桌面特性）。
   */
  private onThemeReport(ctx: DocTabCtx, payload: string): string {
    try {
      const o = JSON.parse(payload) as Record<string, string>;
      const color = String(o['color'] ?? '').trim();
      if (color.length === 0) {
        return 'true';
      }
      for (let i = 0; i < this.docTabs.length; i++) {
        if (this.docTabs[i].ctx === ctx) {
          const aArr = this.docAccents.slice();
          // 防御：上报到已关闭/未初始化 tab（race 时 docAccents 可能短于 docTabs）
          // ——下标缺失段补 ''（静态 accent 兜底），避免数组空洞
          if (i < aArr.length) {
            aArr[i] = color;
          } else {
            aArr.push(color);
          }
          this.docAccents = aArr;
          break;
        }
      }
      this.arkLog('THEME_COLOR tab=' + ctx.id + ' ' + color);
    } catch (e) {
      this.arkLog('THEME_COLOR_ERR ' + String(e));
    }
    return 'true';
  }

  /** tab 切换（DocTabHost.onSwitch）：非激活实例打点（P0 判据复用：后台实例活） */
  private onSwitchTab(idx: number): void {
    for (let i = 0; i < this.docTabs.length; i++) {
      const c = this.docTabs[i].ctx;
      if (i !== idx && c.attached) {
        c.js('(function(){try{console.error("P1A_ALIVE ' + c.kind + c.id
          + ' rd="+document.readyState);}catch(e){console.error("P1A_ALIVE_ERR "+e);}})();', '');
      }
    }
  }

  build() {
    if (this.p0On) {
      // P0 探针分支：p0tabs=1（ability 启动参数）挂载多实例验证骨架；产品态恒 else
      P0TabsProbe({ tabs: $p0Tabs })
    } else {
      // P1b 容器：主页常驻（恒第一）+ doc tab 多开（NodeContainer 节点复用=切回零重建）
      DocTabHost({
        tabs: $docTabs,
        focus: $focusTab,
        titles: $docTitles,
        accents: $docAccents,
        onCloseDoc: (id: number) => this.closeDocTab(id),
        onSwitch: (idx: number) => this.onSwitchTab(idx)
      })
    }
  }
}
