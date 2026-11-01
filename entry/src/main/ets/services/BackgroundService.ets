import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLog } from './AppLog';

/**
 * Keeps the process alive while a long extraction/transcode runs.
 *
 * DATA_TRANSFER is the closest official continuous-task category for a local
 * media job: it is a user-visible, long-running data operation. The notification
 * is created by the system; stopping the task removes it.
 */
export class BackgroundService {
  private static active: boolean = false;

  static isActive(): boolean {
    return BackgroundService.active;
  }

  static async start(ctx: common.UIAbilityContext): Promise<boolean> {
    if (BackgroundService.active) {
      return true;
    }

    try {
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      BackgroundService.active = true;
      AppLog.info('后台', '已申请持续任务，切后台或按返回键后继续处理');
      return true;
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      AppLog.warn('后台', '持续任务申请失败：' + (be.message ? be.message : String(e)));
      return false;
    }
  }

  static async stop(ctx: common.UIAbilityContext): Promise<void> {
    if (!BackgroundService.active) {
      return;
    }
    BackgroundService.active = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      AppLog.info('后台', '持续任务已结束');
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      AppLog.warn('后台', '结束持续任务失败：' + (be.message ? be.message : String(e)));
    }
  }
}
