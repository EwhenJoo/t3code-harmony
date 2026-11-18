import { AbilityConstant, bundleManager, UIAbility, Want } from '@kit.AbilityKit';
import { notifier } from '../services/Notifier';
import { pushHelper } from '../services/PushHelper';
import { projectIcons } from '../services/ProjectIcons';
import { attachmentPreviews } from '../services/Attachments';
import { drafts } from '../services/Drafts';
import { voice } from '../services/Voice';
import { openThread } from '../common/Nav';
import { userSettings } from '../services/UserSettings';
import { display, UIContext, window } from '@kit.ArkUI';
import { appState, finishedAt } from '../model/AppState';
import { connection } from '../services/Connection';
import { cloudAccount, ConnectConfig } from '../services/CloudAccount';
import { gripService } from '../services/GripService';
import { lightEffects } from '../services/LightEffects';
import { Prefs, PREF_APPEARANCE, PREF_SHOW_SETTLED } from '../common/Prefs';
import { applyAppearance } from '../common/Appearance';
import { Log } from '../common/Log';

const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private pendingPairUri: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Prefs.init(this.context);
    userSettings.load();
    drafts.load();
    voice.load();
    projectIcons.init(this.context);
    attachmentPreviews.init(this.context);
    pushHelper.init();
    appState.showSettled = Prefs.getBool(PREF_SHOW_SETTLED, false);
    applyAppearance(this.context, Prefs.getString(PREF_APPEARANCE, 'system'));
    lightEffects.start();
    gripService.start();
    cloudAccount.start(EntryAbility.debugConnectConfig(want.uri ?? ''));
    connection.start();
    this.capturePairLink(want);
    this.captureThreadLink(want);
    this.capturePushLink(want);
  }

  /** `t3code://push?url=…&key=…` from the push helper's QR code: hand it this phone's push token. */
  private capturePushLink(want: Want): void {
    const uri = want.uri ?? '';
    if (!uri.startsWith('t3code://push?')) {
      return;
    }
    // Push Kit notifications only show once the app may post notifications.
    notifier.requestPermission(this.context);
    pushHelper.bind(uri).then((message: string) => {
      appState.notice = message;
    }).catch((e: Error) => {
      appState.notice = `绑定失败：${e.message}`;
    });
  }

  /** `t3code://thread?id=…&env=…` from a tapped notification: open that conversation. */
  private captureThreadLink(want: Want): void {
    const uri = want.uri ?? '';
    if (!uri.startsWith('t3code://thread?')) {
      return;
    }
    let threadId = '';
    uri.substring(uri.indexOf('?') + 1).split('&').forEach((pair: string) => {
      const eq = pair.indexOf('=');
      if (eq > 0 && pair.substring(0, eq) === 'id') {
        threadId = decodeURIComponent(pair.substring(eq + 1));
      }
    });
    if (threadId.length > 0) {
      // Wait for the shell to know the thread (cold start) before showing it.
      let tries = 0;
      const tryOpen = () => {
        tries++;
        if (appState.threadFor(threadId) !== null) {
          openThread(threadId);
        } else if (tries < 40) {
          setTimeout(tryOpen, 250);
        }
      };
      setTimeout(tryOpen, 200);
    }
  }

  /**
   * Debug builds accept `t3code://dev-connect?fapi=…&relay=…` so UI tests can aim T3 Connect at
   * the mock deployment (launch parameters do not survive `aa start` here). Release builds
   * ignore it and always use production.
   */
  private static debugConnectConfig(uri: string): ConnectConfig | undefined {
    if (!uri.startsWith('t3code://dev-connect?')) {
      return undefined;
    }
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      if (!info.appInfo.debug) {
        return undefined;
      }
    } catch (e) {
      return undefined;
    }
    let fapi = '';
    let relay = '';
    uri.substring(uri.indexOf('?') + 1).split('&').forEach((pair: string) => {
      const eq = pair.indexOf('=');
      const key = eq >= 0 ? pair.substring(0, eq) : pair;
      const value = eq >= 0 ? decodeURIComponent(pair.substring(eq + 1)) : '';
      if (key === 'fapi') {
        fapi = value;
      } else if (key === 'relay') {
        relay = value;
      }
    });
    if (fapi.length === 0 || relay.length === 0) {
      return undefined;
    }
    const config = new ConnectConfig();
    config.fapiUrl = fapi;
    config.relayUrl = relay;
    Log.i(TAG, 'T3 Connect pointed at a debug deployment');
    return config;
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const debugConfig = EntryAbility.debugConnectConfig(want.uri ?? '');
    if (debugConfig !== undefined) {
      cloudAccount.start(debugConfig);
    }
    this.capturePairLink(want);
    this.captureThreadLink(want);
    this.capturePushLink(want);
  }

  onForeground(): void {
    notifier.setForeground(true);
    connection.wake();
    // Back in front of an open conversation: whatever it shows now has been seen.
    if (notifier.visibleThreadId.length > 0) {
      const shell = appState.threadFor(notifier.visibleThreadId);
      connection.visitThread(notifier.visibleThreadId, shell !== null ? finishedAt(shell) + 1 : 0);
    }
    gripService.start();
  }

  onBackground(): void {
    notifier.setForeground(false);
    gripService.stop();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        Log.e(TAG, `loadContent failed ${error.code}`);
        return;
      }
      // Returning users with a computer: ask once (the system remembers). New users are asked
      // right after their first computer connects, when notifications start to mean something.
      if (appState.notify && appState.hasEnvironments) {
        notifier.requestPermission(this.context);
      }
    });
    windowStage.getMainWindow().then((win: window.Window) => {
      win.setWindowLayoutFullScreen(true).catch(() => {
      });
      const uiContext = win.getUIContext();
      const updateInsets = (): void => {
        try {
          const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          appState.topInset = uiContext.px2vp(system.topRect.height);
          appState.bottomInset = uiContext.px2vp(nav.bottomRect.height);
          const props = win.getWindowProperties();
          appState.windowWidth = uiContext.px2vp(props.windowRect.width);
          EntryAbility.readCrease(uiContext, props.windowRect.left);
        } catch (e) {
          Log.w(TAG, `inset update failed ${JSON.stringify(e)}`);
        }
      };
      updateInsets();
      win.on('avoidAreaChange', () => updateInsets());
      win.on('windowSizeChange', () => updateInsets());
      win.on('keyboardHeightChange', (height: number) => {
        appState.keyboardHeight = uiContext.px2vp(height);
      });
      try {
        display.on('foldStatusChange', () => updateInsets());
      } catch (e) {
        Log.d(TAG, 'fold status unavailable');
      }
    }).catch((e: Error) => {
      Log.e(TAG, `main window unavailable ${e.message}`);
    });
  }

  /** Records a vertical fold crease so the two-column layout can split on it. */
  private static readCrease(uiContext: UIContext, windowLeft: number): void {
    let x = 0;
    let width = 0;
    try {
      if (display.isFoldable() && display.getFoldStatus() !== display.FoldStatus.FOLD_STATUS_FOLDED) {
        const region = display.getCurrentFoldCreaseRegion();
        const rect = region.creaseRects.length > 0 ? region.creaseRects[0] : null;
        if (rect !== null && rect.height > rect.width) {
          x = uiContext.px2vp(rect.left - windowLeft);
          width = uiContext.px2vp(rect.width);
        }
      }
    } catch (e) {
      x = 0;
    }
    appState.creaseX = Math.round(x);
    appState.creaseWidth = Math.round(width);
  }

  /** `t3code://pair?pairingUrl=…` from a QR scan in the system camera, a browser or hdc. */
  private capturePairLink(want: Want): void {
    const uri = want.uri ?? '';
    if (uri.startsWith('t3code') && uri.indexOf('://pair') > 0 && uri !== this.pendingPairUri) {
      this.pendingPairUri = uri;
      connection.pairFromLink(uri);
    }
  }
}
