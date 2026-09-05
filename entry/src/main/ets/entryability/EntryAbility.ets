import { AbilityConstant, Want, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/**
 * 启动参数（want.parameters）——EditorPage 读取（自动验收开关 m7accept/m7file；
 * 见 EditorPage.ets 文件头）。onNewWant 覆盖（应用已运行时再次 aa start 换参数）。
 */
let launchOptions: Record<string, string> = {};

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
}

export function getLaunchOptions(): Record<string, string> {
  return launchOptions;
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
    // 初始不开启沉浸（2026-09-05 用户需求：主页（index.html）不沉浸，进入编辑器页
    // 再开）。沉浸窗口已迁至 EditorPage.setImmersive——Web 组件 onLoadIntercept 按
    // 目标 URL 驱动（index.html=关 / main/index.html=开），仅 tablet（deviceInfo 守卫
    // 在页面侧）；本处 loadContent 放行即可，勿在此恢复无条件开启（否则主页被沉浸）。
    windowStage.loadContent('pages/EditorPage');
  }

  onWindowStageDestroy(): void {
  }

  onDestroy(): void {
  }
}
