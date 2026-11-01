/**
 * Remembers the last unfinished extraction.
 *
 * HarmonyOS containers cannot be appended from an arbitrary byte offset, so a
 * recovered job is re-created from the start into the same destination file.
 * The source and destination URI permissions are persisted, which lets the app
 * offer that recovery after the process has been restarted.
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class PendingJob {
  inputUri: string = '';
  inputName: string = '';
  inputSize: number = 0;
  outputUri: string = '';
  outputName: string = '';
  format: string = 'mp3';
  durationUs: number = 0;
  createdAt: number = 0;
}

export class JobStore {
  private static readonly NAME: string = 'ruinsss_job';
  private static store: preferences.Preferences | null = null;

  private static async ensure(context: common.UIAbilityContext): Promise<preferences.Preferences | null> {
    if (JobStore.store !== null) {
      return JobStore.store;
    }
    try {
      JobStore.store = await preferences.getPreferences(context, JobStore.NAME);
      return JobStore.store;
    } catch (e) {
      console.error('job preferences unavailable: ' + JSON.stringify(e));
      return null;
    }
  }

  static async load(context: common.UIAbilityContext): Promise<PendingJob | null> {
    const store: preferences.Preferences | null = await JobStore.ensure(context);
    if (store === null) {
      return null;
    }
    try {
      const raw = await store.get('job', '');
      const text: string = raw as string;
      if (text.length === 0) {
        return null;
      }
      const job: PendingJob = JSON.parse(text) as PendingJob;
      if (job.inputUri.length === 0 || job.outputUri.length === 0) {
        return null;
      }
      return job;
    } catch (e) {
      return null;
    }
  }

  static async save(context: common.UIAbilityContext, job: PendingJob): Promise<void> {
    const store: preferences.Preferences | null = await JobStore.ensure(context);
    if (store === null) {
      return;
    }
    try {
      await store.put('job', JSON.stringify(job));
      await store.flush();
    } catch (e) {
      console.error('job save failed: ' + JSON.stringify(e));
    }
  }

  static async clear(context: common.UIAbilityContext): Promise<void> {
    const store: preferences.Preferences | null = await JobStore.ensure(context);
    if (store === null) {
      return;
    }
    try {
      await store.put('job', '');
      await store.flush();
    } catch (e) {
      console.error('job clear failed: ' + JSON.stringify(e));
    }
  }
}
