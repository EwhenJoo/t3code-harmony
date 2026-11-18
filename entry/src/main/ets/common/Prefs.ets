import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from './Log';

const TAG = 'Prefs';

/** Synchronous key/value settings backed by @kit.ArkData preferences. */
export class Prefs {
  private static store: preferences.Preferences | null = null;

  static init(context: common.Context): void {
    try {
      const options: preferences.Options = { name: 't3code_settings' };
      Prefs.store = preferences.getPreferencesSync(context, options);
    } catch (e) {
      Log.e(TAG, `init failed ${JSON.stringify(e)}`);
    }
  }

  static getString(key: string, fallback: string): string {
    if (Prefs.store === null) {
      return fallback;
    }
    const value = Prefs.store.getSync(key, fallback);
    return typeof value === 'string' ? value as string : fallback;
  }

  static getBool(key: string, fallback: boolean): boolean {
    if (Prefs.store === null) {
      return fallback;
    }
    const value = Prefs.store.getSync(key, fallback);
    return typeof value === 'boolean' ? value as boolean : fallback;
  }

  static put(key: string, value: string | boolean): void {
    if (Prefs.store === null) {
      return;
    }
    try {
      Prefs.store.putSync(key, value);
      Prefs.store.flush();
    } catch (e) {
      Log.e(TAG, `put ${key} failed ${JSON.stringify(e)}`);
    }
  }

  static remove(key: string): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.deleteSync(key);
    Prefs.store.flush();
  }
}

/** Single saved computer (v1); migrated into PREF_ENVIRONMENTS on first start. */
export const PREF_ENVIRONMENT = 'environment.v1';
/** Every connected computer, as a JSON array of SavedEnvironment. */
export const PREF_ENVIRONMENTS = 'environments.v2';
export const PREF_HAND_OVERRIDE = 'hand.override';
export const PREF_LIGHT_EFFECTS = 'light.effects';
/** Vibrate lightly on taps and selections. */
export const PREF_HAPTICS = 'feedback.haptics';
/** While the agent runs: 'steer' guides the current turn, 'queue' waits for it to finish. */
export const PREF_FOLLOW_UP = 'chat.followUp';
/** Return key in the composer: 'newline' or 'send'. */
export const PREF_RETURN_KEY = 'chat.returnKey';
/** Local notifications: master switch and the three moments they cover. */
export const PREF_NOTIFY = 'notify.enabled';
export const PREF_NOTIFY_ATTENTION = 'notify.attention';
export const PREF_NOTIFY_DONE = 'notify.done';
export const PREF_NOTIFY_FAILED = 'notify.failed';
/** Last run settings used for a new conversation, per computer. */
export const PREF_LAST_RUN = 'newTask.lastRun.v1';
/** The push helper this phone is bound to (JSON PushHelperBinding) and this install's id there. */
export const PREF_PUSH_HELPER = 'push.helper.v1';
export const PREF_PUSH_DEVICE_ID = 'push.deviceId';
export const PREF_SHOW_SETTLED = 'list.showSettled';
/** Unsent messages per conversation: JSON { threadId: text }. */
export const PREF_DRAFTS = 'composer.drafts.v1';
/** Voice input: where recordings are transcribed and how (JSON, see services/Voice). */
export const PREF_VOICE = 'voice.v1';
/** 'project' (default, like the desktop sidebar) or 'status'. */
export const PREF_GROUP_BY = 'list.groupBy';
/** JSON array of folded project groups (`<environmentId>|<projectId>`). */
export const PREF_COLLAPSED_PROJECTS = 'list.collapsedProjects';
export const PREF_APPEARANCE = 'appearance';
export const PREF_CLERK_CLIENT = 'clerk.client.v1';
export const PREF_CLOUD_ACCOUNT = 'cloud.account.v1';
