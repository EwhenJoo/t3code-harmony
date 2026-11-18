import { appState } from '../model/AppState';
import { Prefs, PREF_DRAFTS } from '../common/Prefs';
import { Log } from '../common/Log';

const TAG = 'Drafts';

/**
 * Unsent messages, kept per conversation on this phone (like the desktop's composer drafts): the list
 * marks those conversations 草稿, and opening one puts the text back in the field.
 */
export class DraftStore {
  private texts: Map<string, string> = new Map();
  private saveTimer: number = -1;

  load(): void {
    try {
      const saved = JSON.parse(Prefs.getString(PREF_DRAFTS, '{}')) as Record<string, string>;
      Object.keys(saved).forEach((threadId: string) => {
        if (typeof saved[threadId] === 'string' && saved[threadId].trim().length > 0) {
          this.texts.set(threadId, saved[threadId]);
        }
      });
    } catch (e) {
      Log.w(TAG, 'saved drafts unreadable');
    }
    this.publish();
  }

  get(threadId: string): string {
    return this.texts.get(threadId) ?? '';
  }

  set(threadId: string, text: string): void {
    const had = this.texts.has(threadId);
    if (text.trim().length === 0) {
      if (!had) {
        return;
      }
      this.texts.delete(threadId);
    } else {
      this.texts.set(threadId, text);
    }
    if (had !== this.texts.has(threadId)) {
      this.publish();
    }
    this.scheduleSave();
  }

  private publish(): void {
    appState.draftThreadIds = Array.from(this.texts.keys());
  }

  private scheduleSave(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      const out: Record<string, string> = {};
      this.texts.forEach((text: string, threadId: string) => {
        out[threadId] = text;
      });
      Prefs.put(PREF_DRAFTS, JSON.stringify(out));
    }, 400);
  }
}

export const drafts: DraftStore = new DraftStore();
