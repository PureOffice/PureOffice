import { AbilityConstant, Want, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // POC-1: 无业务初始化
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/EditorPage');
  }

  onWindowStageDestroy(): void {
  }

  onDestroy(): void {
  }
}
