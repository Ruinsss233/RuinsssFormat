/**
 * Ruinsss格式快转 — EntryAbility
 * Stage model, API 12+. The window uses a light, warm backdrop so the frosted
 * glass surfaces in the page read as glass rather than as flat white cards.
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0001;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'loadContent succeeded');
    });

    const win: window.Window = windowStage.getMainWindowSync();
    win.setPreferredOrientation(window.Orientation.PORTRAIT).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'orientation failed: %{public}s', e.message);
    });
    win.setWindowKeepScreenOn(true).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'keep screen on failed: %{public}s', e.message);
    });
    win.setWindowSystemBarProperties({
      statusBarColor: '#FFF9FC',
      statusBarContentColor: '#3D2935',
      navigationBarColor: '#EAF8F3',
      navigationBarContentColor: '#3D2935'
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'system bar setup failed: %{public}s', e.message);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onBackground');
  }
}
