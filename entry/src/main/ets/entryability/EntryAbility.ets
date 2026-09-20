import { AbilityConstant, Want, UIAbility, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 启动参数（want.parameters）——EditorPage 读取（自动验收开关 m7accept/m7file；
 * 见 EditorPage.ets 文件头）。onNewWant 覆盖（应用已运行时再次 aa start 换参数）。
 */
let launchOptions: Record<string, string> = {};

export function getLaunchOptions(): Record<string, string> {
  return launchOptions;
}

// —— 「打开方式」入口 uri（want.uri）——
// 文件管理器/其他应用把文档交给我们打开时携带（module.json5 已声明 viewData skill，
// 否则系统不会把本应用列入候选）。冷启动时 EditorPage 尚未创建（handler 未注册），
// uri 先存下由首帧后 takeLaunchUri 取走；热启动（应用已运行）时 handler 已注册，
// 直接送达页面——两条路都不丢事件。
let launchUri: string | null = null;
let wantUriHandler: ((uri: string) => void) | null = null;

export function setWantUriHandler(h: ((uri: string) => void) | null): void {
  wantUriHandler = h;
}

/** 取走启动 uri（take 语义：同一 uri 只消费一次；无待办返回 null）。
 *  首帧前连点两次「打开方式」= 以后一次为准（打开用户最新点的那份文件） */
export function takeLaunchUri(): string | null {
  const u = launchUri;
  launchUri = null;
  return u;
}

function collect(want: Want): void {
  try {
    const p = (want.parameters ?? {}) as Record<string, string>;
    const out: Record<string, string> = {};
    for (const k of Object.keys(p)) {
      if (typeof p[k] === 'string') {
        out[k] = p[k];
      }
    }
    launchOptions = out;
  } catch (e) {
    launchOptions = {};
  }
  try {
    const u = typeof want.uri === 'string' ? want.uri : '';
    if (u.length > 0) {
      hilog.info(0x0000, 'OfficeWant', 'want.uri=' + u);
      if (wantUriHandler !== null) {
        wantUriHandler(u); // 页面已就绪：直达（不写暂存位——否则会被二次 take 重复打开）
      } else {
        launchUri = u; // 首帧前：暂存，由 takeLaunchUri 取走
      }
    }
  } catch (e) {
    // uri 解析失败不影响启动
  }
}

// —— 系统三键 ✕ 关闭守卫桥（2026-09-10，WPS 同款正路）——
// WindowStage.on('windowStageClose')（@since 14）：主窗口三键导航栏「关闭」点击
// 事件——回调 **return true = 不关窗**（d.ts 类型标注 Callback<void>，语义在返回
// 值；真机行为为准）。策略=恒拦：先阻止系统关窗，再转 EditorPage 守卫
// （requestBackExit：未保存逐个弹三按钮框→全处置完 terminateSelf；用户取消=窗口
// 保留）。此前「系统 ✕ 不可拦截/×随标题栏隐藏」结论错误：setWindowDecorVisible
// (false) 只藏标题栏，三键常驻右上角（1.4 UI dump [2370,297]-[2560,335] 实证）——
// 旧结论取证样本是 1.8（tablet 沉浸窗口本无三键），与 decor 无关。
let windowCloseHandler: (() => void) | null = null;

export function setWindowCloseHandler(h: (() => void) | null): void {
  windowCloseHandler = h;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // POC-1: 无业务初始化；仅收集启动参数（能力验证/验收开关用）
    collect(want);
  }

  /** 权限申请只做一次（loadContent 回调与 WINDOW_SHOWN 双路径防漏，二选一触发） */
  private permRequested: boolean = false;

  /**
   * 启动即申请剪贴板读取权限（2026-09-21 工具栏粘贴链，用户决策）。
   * READ_PASTEBOARD = user_grant 受限权限（ACL 管资格、用户管授予）：module.json5
   * 声明 + 签名 profile acl 只是「有资格申请」，授予必须用户点头。若等到首次点
   * 「粘贴」再弹，用户先见点击无反应再见弹窗，体验割裂——故启动即申请：
   * 已授予（checkAccessToken）静默跳过；未授予弹系统授权框，一次授权长期有效。
   * 拒绝后系统自身限频（不再反复骚扰）；宿主 clip:paste 分支对未授权态另有
   * toast 引导（EditorPage.pasteClipboard）。
   * 时机（1.6 实测教训）：必须在**窗口内容就绪后**（loadContent 回调/WINDOW_SHOWN）
   * ——onCreate 阶段窗口未建，requestPermissionsFromUser 无处挂弹窗，系统静默
   * 返回 auth=-1（拒绝）且不显示任何 UI；且该次结果会被记账为「已拒绝」，
   * 后续真窗口期的申请也可能被限频，勿改回 onCreate。
   */
  private requestClipboardPermission(): void {
    if (this.permRequested) {
      return;
    }
    this.permRequested = true;
    try {
      const atm = abilityAccessCtrl.createAtManager();
      bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
        .then((info: bundleManager.BundleInfo) => {
          if (info.appInfo === undefined || info.appInfo === null) {
            hilog.warn(0x0000, 'OfficePerm', 'no appInfo, skip');
            return;
          }
          const tokenId = info.appInfo.accessTokenId;
          return atm.checkAccessToken(tokenId, 'ohos.permission.READ_PASTEBOARD');
        })
        .then((st: abilityAccessCtrl.GrantStatus | void) => {
          if (st !== undefined && st === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            hilog.info(0x0000, 'OfficePerm', 'pasteboard already granted');
            return;
          }
          const perms: Array<Permissions> = ['ohos.permission.READ_PASTEBOARD'];
          atm.requestPermissionsFromUser(this.context, perms)
            .then((res) => {
              // res 类型由 Promise 泛型推断（PermissionRequestResult 为模块内部
              // 声明，不在 abilityAccessCtrl 命名空间下，无法显式标注）
              hilog.info(0x0000, 'OfficePerm',
                'pasteboard request auth=' + JSON.stringify(res.authResults));
            })
            .catch((e: BusinessError) => {
              hilog.warn(0x0000, 'OfficePerm', 'pasteboard request err ' + JSON.stringify(e));
            });
        })
        .catch((e: BusinessError) => {
          hilog.warn(0x0000, 'OfficePerm', 'checkAccessToken err ' + JSON.stringify(e));
        });
    } catch (e) {
      hilog.warn(0x0000, 'OfficePerm', 'pasteboard precheck err ' + JSON.stringify(e));
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用运行中再次启动（aa start 更新参数）：刷新参数；EditorPage 只在 aboutToAppear
    // 读取一次（2026-09-05 审查更正注释：新参数对运行中的实例下次冷启动生效）
    collect(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 系统三键 ✕ 关闭守卫入口（2026-09-10）：拦截（return true=不关窗）仅当
    // windowCloseHandler 已注册（EditorPage aboutToAppear 设置=requestBackExit）；
    // **未注册（loadContent 首帧前）→ 放行系统默认关窗**——恒拦会死锁（handler 为
    // null 时无人终止，窗口卡死）。首帧前亦无文档可编辑，放行零数据风险。
    try {
      windowStage.on('windowStageClose', () => {
        if (windowCloseHandler !== null) {
          windowCloseHandler();
          return true;
        }
        return false;
      });
    } catch (e) {
      hilog.warn(0x0000, 'OfficeWin', 'windowStageClose register err ' + JSON.stringify(e));
    }
    windowStage.loadContent('pages/EditorPage', () => {
      // loadContent 之后窗口装饰才就绪（wineohos WineWindowAbility 同款时序）。
      // 2026-09-09 首次真机：loadContent 回调时窗口未显示——setWindowLayoutFullScreen
      // 生效（内容伸入状态栏区）但 setSpecificSystemBarEnabled 未生效（时间/电量仍显示）。
      // wineohos 是窗口 SHOWN 事件后才隐藏系统栏（WineWindowAbility WINDOW_SHOWN 段），
      // 改为事件驱动重试（幂等，双保险）。
      this.applyWindowMode(windowStage);
      // 剪贴板权限申请（loadContent 回调=窗口内容就绪；permRequested 守卫使
      // WINDOW_SHOWN 路径只做漏触发兜底，不会重复弹窗）
      this.requestClipboardPermission();
      try {
        const mw = windowStage.getMainWindowSync();
        mw.on('windowEvent', (event) => {
          if (event === window.WindowEventType.WINDOW_SHOWN) {
            this.applyWindowMode(windowStage);
            this.requestClipboardPermission();
          }
        });
      } catch (e) {
        hilog.warn(0x0000, 'OfficeWin', 'windowEvent register err ' + JSON.stringify(e));
      }
    });
  }

  /**
   * 窗口形态（2026-09-09 用户需求，参考 ../wineohos 窗口逻辑——PAD 虚拟桌面/
   * PC 窗口实锤代码）：
   *  - Pad（deviceType tablet/phone）→ **系统默认形态**（不干预：状态栏/导航条可见）。
   *    2026-09-18 用户要求不再常驻沉浸（原实现= setWindowLayoutFullScreen(true) +
   *    隐藏状态栏/手势条，仿 wineohos「进入桌面」）；放映期仍临时沉浸，见
   *    EditorPage.applyFsWindow。
   *  - PC（deviceType 2in1/pc）→ 无边框沉浸：setWindowDecorVisible(false) +
   *    setWindowDecorHeight(37)——用户拍板参考 ../wineohos/.temp/HiSH
   *    （见 PC 分支注释）；1.4 真机验收通过（tab 恒不越系统三键区=另加 150 避让）。
   * 判据官方枚举 deviceInfo.deviceType（String 常量；无 'pc' 时 2in1 即 PC 形态；
   * 注意它只反映硬件——同一 Pad 切 PC 桌面模式仍报 tablet，窗口形态切换判据留待
   * 窗口 mode/显示模式 API）。
   * 幂等：SHOWN 重复调用无害（重复设置同值）。失败不阻断编辑器（退化=系统默认形态）。
   */
  private applyWindowMode(windowStage: window.WindowStage): void {
    try {
      const mw = windowStage.getMainWindowSync();
      const dt = deviceInfo.deviceType;
      hilog.info(0x0000, 'OfficeWin', 'applyWindowMode deviceType=' + dt);
      if (dt !== 'tablet' && dt !== 'phone') {
        // PC（2in1/pc）无边框沉浸——用户拍板参考 ../wineohos/.temp/HiSH
        // （EntryAbility.ets:83-85）：setWindowDecorVisible(false)（隐藏系统
        // 标题栏+按钮）+ setWindowDecorHeight(37)（**保留合法最小 37 装饰区=
        // 顶部拖条**——[37,112] 官方范围；HiSH 用 48 是自选非下限，悬浮标题栏
        // 固定 37vp）。canIUse 守卫保留（能力判定：2in1 自由窗口才生效；
        // 不支持时走 else=系统默认标题栏而**不报错**——比直接调 801 兜底更
        // 显式）。此前两个被否决的走法（WineWindowAbility 全隐藏禁拖动 /
        // wineohos Index 保留标题栏+避让）不采用，勿回。
        if (canIUse('SystemCapability.Window.SessionManager')) {
          mw.setWindowDecorVisible(false);
          mw.setWindowDecorHeight(37);
          hilog.info(0x0000, 'OfficeWin', 'pc decor off h37');
        } else {
          hilog.warn(0x0000, 'OfficeWin', 'pc no SessionManager, decor kept');
        }
      }
    } catch (e) {
      hilog.warn(0x0000, 'OfficeWin', 'applyWindowMode err ' + JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
  }

  onDestroy(): void {
  }
}
