import { AbilityConstant, Want, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

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
    windowStage.loadContent('pages/EditorPage', (err) => {
      if (err.code) {
        console.error('loadContent failed: ' + JSON.stringify(err));
        return;
      }
      // 沉浸窗口模式（2026-09-05 用户指示，参照 ../comfyui/EntryAbility.ets）：
      // 全屏布局 + 隐藏状态栏/底部导航指示器 —— WebView 铺满整屏（欢迎页/编辑器页）。
      // **仅 Pad**：module.json5 deviceTypes 含 phone/2in1（comfyui 只声明 tablet
      // 无需判断），这里运行时按 deviceInfo.deviceType === 'tablet' 守卫；phone/2in1
      // 保持系统默认。navigationIndicator 必须用 setSpecificSystemBarEnabled
      // （setWindowSystemBarEnable 的 'navigation' 参数无效果——comfyui 实测注释）；
      // 与 EditorPage 根 Stack 的 expandSafeArea 配合，内容顶到边。
      if (deviceInfo.deviceType === 'tablet') {
        try {
          const mw = windowStage.getMainWindowSync();
          mw.setWindowLayoutFullScreen(true);
          mw.setSpecificSystemBarEnabled('status', false);
          mw.setSpecificSystemBarEnabled('navigationIndicator', false);
          console.info('immersive window (tablet) enabled');
        } catch (e) {
          console.error('immersive window setup failed: ' + JSON.stringify(e));
        }
      }
    });
  }

  onWindowStageDestroy(): void {
  }

  onDestroy(): void {
  }
}
