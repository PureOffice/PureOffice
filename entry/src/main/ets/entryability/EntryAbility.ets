import { AbilityConstant, Want, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
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
      try {
        const mw = windowStage.getMainWindowSync();
        mw.on('windowEvent', (event) => {
          if (event === window.WindowEventType.WINDOW_SHOWN) {
            this.applyWindowMode(windowStage);
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
   *  - Pad（deviceType tablet/phone）→ 沉浸窗口模式：全屏布局 + 隐藏状态栏与
   *    手势条——wineohos Index.ets「进入桌面」同款（setWindowLayoutFullScreen(true)
   *    + setSpecificSystemBarEnabled('status'/'navigationIndicator', false)）；
   *    1.8 真机已验证（状态栏消失、内容贴顶）。
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
      if (dt === 'tablet' || dt === 'phone') {
        mw.setWindowLayoutFullScreen(true)
          .then(() => { hilog.info(0x0000, 'OfficeWin', 'fullScreen ok'); })
          .catch((e: BusinessError) => { hilog.warn(0x0000, 'OfficeWin', 'fullScreen err ' + JSON.stringify(e)); });
        mw.setSpecificSystemBarEnabled('status', false)
          .then(() => { hilog.info(0x0000, 'OfficeWin', 'statusBar off ok'); })
          .catch((e: BusinessError) => { hilog.warn(0x0000, 'OfficeWin', 'statusBar off err ' + JSON.stringify(e)); });
        mw.setSpecificSystemBarEnabled('navigationIndicator', false)
          .then(() => { hilog.info(0x0000, 'OfficeWin', 'navBar off ok'); })
          .catch((e: BusinessError) => { hilog.warn(0x0000, 'OfficeWin', 'navBar off err ' + JSON.stringify(e)); });
      } else {
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
