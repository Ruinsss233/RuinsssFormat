/** Tiny persistent history of successful extractions. */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { HistoryItem, parseHistory } from '../model/Types';

export class HistoryStore {
  private static readonly NAME: string = 'ruinsss_history';
  private static store: preferences.Preferences | null = null;

  private static async ensure(context: common.UIAbilityContext): Promise<preferences.Preferences | null> {
    if (HistoryStore.store !== null) {
      return HistoryStore.store;
    }
    try {
      HistoryStore.store = await preferences.getPreferences(context, HistoryStore.NAME);
      return HistoryStore.store;
    } catch (e) {
      console.error('history preferences unavailable: ' + JSON.stringify(e));
      return null;
    }
  }

  static async load(context: common.UIAbilityContext): Promise<HistoryItem[]> {
    const store: preferences.Preferences | null = await HistoryStore.ensure(context);
    if (store === null) {
      return [];
    }
    try {
      const raw = await store.get('items', '[]');
      const text: string = raw as string;
      return parseHistory(text);
    } catch (e) {
      return [];
    }
  }

  static async save(context: common.UIAbilityContext, items: HistoryItem[]): Promise<void> {
    const store: preferences.Preferences | null = await HistoryStore.ensure(context);
    if (store === null) {
      return;
    }
    try {
      await store.put('items', JSON.stringify(items));
      await store.flush();
    } catch (e) {
      console.error('history save failed: ' + JSON.stringify(e));
    }
  }

  static async clear(context: common.UIAbilityContext): Promise<void> {
    const store: preferences.Preferences | null = await HistoryStore.ensure(context);
    if (store === null) {
      return;
    }
    try {
      await store.put('items', '[]');
      await store.flush();
    } catch (e) {
      console.error('history clear failed: ' + JSON.stringify(e));
    }
  }
}
