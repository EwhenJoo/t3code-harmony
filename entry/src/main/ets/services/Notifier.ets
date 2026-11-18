import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { appState, isWorking, needsAttention } from '../model/AppState';
import { ThreadShell } from '../model/Types';
import { previewText } from '../common/Format';
import { Log } from '../common/Log';

const TAG = 'Notifier';
const BUNDLE = 'com.ewhen.t3code';

class ThreadMark {
  attentionId: string = '';
  status: string = '';
  /** Same test as the list's "运行中": real T3 reports a run as `queued` with an active run id. */
  working: boolean = false;
}

/**
 * Local notifications for the moments iOS pushes: a conversation needs you (approval or a
 * question), finished, or failed. The T3 relay only delivers APNs / FCM pushes, so on HarmonyOS
 * they come from the live connection: while the app is open, and for a few minutes after it goes
 * to the background (a transient task keeps the socket alive).
 */
class NotifierImpl {
  private marks: Map<string, ThreadMark> = new Map();
  private primed: boolean = false;
  private foreground: boolean = true;
  private delayId: number = -1;
  private nextId: number = 1;
  /** The conversation on screen; it needs no notification. */
  visibleThreadId: string = '';

  requestPermission(context: common.UIAbilityContext): void {
    try {
      notificationManager.isNotificationEnabled().then((enabled: boolean) => {
        if (!enabled) {
          notificationManager.requestEnableNotification(context).catch((e: Error) => {
            Log.w(TAG, `notification permission denied ${JSON.stringify(e)}`);
          });
        }
      }).catch(() => {
      });
    } catch (e) {
      Log.w(TAG, `notification permission unavailable ${JSON.stringify(e)}`);
    }
  }

  get isForeground(): boolean {
    return this.foreground;
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (foreground) {
      this.cancelGrace();
    } else {
      this.startGrace();
    }
  }

  /** Called after every shell change; compares each thread with what it was last time. */
  onThreadsChanged(): void {
    const threads = appState.threads;
    if (!this.primed) {
      // The first snapshot is history, not news.
      threads.forEach((t: ThreadShell) => this.marks.set(this.key(t), this.markOf(t)));
      this.primed = appState.anyShellLoaded;
      return;
    }
    threads.forEach((thread: ThreadShell) => {
      const key = this.key(thread);
      const before = this.marks.get(key);
      const now = this.markOf(thread);
      this.marks.set(key, now);
      if (before === undefined) {
        return;
      }
      if (now.attentionId.length > 0 && now.attentionId !== before.attentionId) {
        if (appState.notifyAttention) {
          const question = (thread.pendingRuntimeRequest?.kind ?? '') === 'user_input';
          this.post(thread, question ? '代理在等你回答' : '代理在等你批准', thread.title);
        }
      } else if (now.status === 'failed' && before.status !== 'failed') {
        if (appState.notifyFailed) {
          this.post(thread, `失败：${thread.title}`, thread.lastError ?? '');
        }
      } else if (before.working && !now.working && now.status !== 'interrupted' && now.status !== 'cancelled') {
        // A run you stopped yourself needs no notice.
        if (appState.notifyDone) {
          this.post(thread, `完成：${thread.title}`, previewText(thread.latestVisibleMessage?.text ?? '', 120));
        }
      }
    });
  }

  private key(thread: ThreadShell): string {
    return `${thread.environmentId ?? ''}:${thread.id}`;
  }

  private markOf(thread: ThreadShell): ThreadMark {
    const mark = new ThreadMark();
    mark.attentionId = needsAttention(thread) ? (thread.pendingRuntimeRequest?.id ?? 'pending') : '';
    mark.status = thread.status;
    mark.working = isWorking(thread);
    return mark;
  }

  private post(thread: ThreadShell, title: string, text: string): void {
    if (!appState.notify) {
      return;
    }
    // Already reading it: no need to interrupt.
    if (this.foreground && thread.id === this.visibleThreadId) {
      return;
    }
    // In the background the push helper delivers the same news through Push Kit.
    if (!this.foreground && appState.pushHelperName.length > 0) {
      return;
    }
    const id = this.nextId++;
    const uri = `t3code://thread?id=${encodeURIComponent(thread.id)}&env=${encodeURIComponent(thread.environmentId ?? '')}`;
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: BUNDLE, abilityName: 'EntryAbility', uri: uri }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: id,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    wantAgent.getWantAgent(info).then((agent: WantAgent) => {
      const request: notificationManager.NotificationRequest = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: text.length > 0 ? text : (appState.multiEnv ? (appState.environmentFor(thread.environmentId)?.label ?? '') : 'T3 Code') },
        },
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        wantAgent: agent,
        tapDismissed: true,
        groupName: thread.id,
      };
      return notificationManager.publish(request);
    }).catch((e: Error) => {
      Log.w(TAG, `publish failed ${JSON.stringify(e)}`);
    });
  }

  /** Keep the connection for a few minutes after leaving the app, so news still arrives. */
  private startGrace(): void {
    if (this.delayId >= 0) {
      return;
    }
    try {
      const info = backgroundTaskManager.requestSuspendDelay('等待代理的新消息', () => {
        this.cancelGrace();
      });
      this.delayId = info.requestId;
    } catch (e) {
      Log.d(TAG, `transient task unavailable ${JSON.stringify(e)}`);
    }
  }

  private cancelGrace(): void {
    if (this.delayId < 0) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(this.delayId);
    } catch (e) {
      Log.d(TAG, 'cancel suspend delay failed');
    }
    this.delayId = -1;
  }

  /** Clears this app's notifications, e.g. when it comes back to the foreground. */
  clearAll(): void {
    notificationManager.cancelAll().catch(() => {
    });
  }
}

export const notifier: NotifierImpl = new NotifierImpl();
