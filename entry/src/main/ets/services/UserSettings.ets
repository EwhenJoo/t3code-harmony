import { appState } from '../model/AppState';
import {
  PREF_COLLAPSED_PROJECTS,
  PREF_GROUP_BY,
  Prefs,
  PREF_FOLLOW_UP,
  PREF_HAPTICS,
  PREF_NOTIFY,
  PREF_NOTIFY_ATTENTION,
  PREF_NOTIFY_DONE,
  PREF_NOTIFY_FAILED,
  PREF_RETURN_KEY,
} from '../common/Prefs';

/** Device-local preferences, mirrored into appState so views react to them. */
class UserSettingsImpl {
  load(): void {
    appState.haptics = Prefs.getBool(PREF_HAPTICS, true);
    appState.followUp = Prefs.getString(PREF_FOLLOW_UP, 'steer') === 'queue' ? 'queue' : 'steer';
    appState.returnKey = Prefs.getString(PREF_RETURN_KEY, 'newline') === 'send' ? 'send' : 'newline';
    appState.notify = Prefs.getBool(PREF_NOTIFY, true);
    appState.notifyAttention = Prefs.getBool(PREF_NOTIFY_ATTENTION, true);
    appState.notifyDone = Prefs.getBool(PREF_NOTIFY_DONE, true);
    appState.notifyFailed = Prefs.getBool(PREF_NOTIFY_FAILED, true);
    appState.groupBy = Prefs.getString(PREF_GROUP_BY, 'project') === 'status' ? 'status' : 'project';
    try {
      // Groups are keyed by project name now (`name:` / `id:`); folds saved per computer are dropped.
      const saved = JSON.parse(Prefs.getString(PREF_COLLAPSED_PROJECTS, '[]')) as string[];
      appState.collapsedProjects = saved.filter((k: string) => k.startsWith('name:') || k.startsWith('id:'));
    } catch (e) {
      appState.collapsedProjects = [];
    }
  }

  setGroupBy(value: string): void {
    appState.groupBy = value === 'status' ? 'status' : 'project';
    Prefs.put(PREF_GROUP_BY, appState.groupBy);
  }

  /** Folds or unfolds one project group on the home list, remembered across launches. */
  toggleProject(key: string): void {
    const folded = appState.collapsedProjects.indexOf(key) >= 0;
    appState.collapsedProjects = folded
      ? appState.collapsedProjects.filter((k: string) => k !== key)
      : appState.collapsedProjects.concat([key]);
    Prefs.put(PREF_COLLAPSED_PROJECTS, JSON.stringify(appState.collapsedProjects));
  }

  setHaptics(on: boolean): void {
    appState.haptics = on;
    Prefs.put(PREF_HAPTICS, on);
  }

  setFollowUp(value: string): void {
    appState.followUp = value === 'queue' ? 'queue' : 'steer';
    Prefs.put(PREF_FOLLOW_UP, appState.followUp);
  }

  setReturnKey(value: string): void {
    appState.returnKey = value === 'send' ? 'send' : 'newline';
    Prefs.put(PREF_RETURN_KEY, appState.returnKey);
  }

  setNotify(on: boolean): void {
    appState.notify = on;
    Prefs.put(PREF_NOTIFY, on);
  }

  setNotifyAttention(on: boolean): void {
    appState.notifyAttention = on;
    Prefs.put(PREF_NOTIFY_ATTENTION, on);
  }

  setNotifyDone(on: boolean): void {
    appState.notifyDone = on;
    Prefs.put(PREF_NOTIFY_DONE, on);
  }

  setNotifyFailed(on: boolean): void {
    appState.notifyFailed = on;
    Prefs.put(PREF_NOTIFY_FAILED, on);
  }
}

export const userSettings: UserSettingsImpl = new UserSettingsImpl();
