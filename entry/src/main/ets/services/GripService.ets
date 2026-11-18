import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState, Hand } from '../model/AppState';
import { Log } from '../common/Log';
import { Prefs, PREF_HAND_OVERRIDE } from '../common/Prefs';

const TAG = 'Grip';
/** A one-handed grip must hold this long before controls move to the other side. */
const STEADY_MS = 700;

/**
 * Smart left/right hand grip awareness.
 *
 * Prefers `holdingHandChanged` (API 20, grip sensing: which hand holds the phone) and falls back
 * to `operatingHandChanged` (API 15, which thumb is touching). Both need DETECT_GESTURE, a
 * system_grant permission declared in module.json5. Devices without the sensor report 801;
 * the app then keeps the manual override from Settings.
 */
class GripServiceImpl {
  private holdingCallback: ((status: motion.HoldingHandStatus) => void) | null = null;
  private operatingCallback: ((status: motion.OperatingHandStatus) => void) | null = null;
  private steadyTimer: number = -1;

  /**
   * Real grip sensors flip between "both" and one hand many times a second while the phone is
   * picked up or shifted. Only a one-handed reading that stays put moves the layout.
   */
  private observe(hand: Hand, source: string): void {
    appState.hand = hand;
    appState.handSource = source;
    if (this.steadyTimer !== -1) {
      clearTimeout(this.steadyTimer);
      this.steadyTimer = -1;
    }
    if ((hand !== 'left' && hand !== 'right') || hand === appState.thumbHand) {
      return;
    }
    this.steadyTimer = setTimeout(() => {
      this.steadyTimer = -1;
      if (appState.hand === hand) {
        appState.thumbHand = hand;
        Log.i(TAG, `layout follows ${hand} hand`);
      }
    }, STEADY_MS);
  }

  start(): void {
    appState.handOverride = Prefs.getString(PREF_HAND_OVERRIDE, 'auto');
    if (this.holdingCallback !== null || this.operatingCallback !== null) {
      return;
    }
    if (this.tryHolding()) {
      return;
    }
    this.tryOperating();
  }

  stop(): void {
    if (this.steadyTimer !== -1) {
      clearTimeout(this.steadyTimer);
      this.steadyTimer = -1;
    }
    try {
      if (this.holdingCallback !== null) {
        motion.off('holdingHandChanged', this.holdingCallback);
      }
      if (this.operatingCallback !== null) {
        motion.off('operatingHandChanged', this.operatingCallback);
      }
    } catch (e) {
      Log.w(TAG, `unsubscribe failed ${JSON.stringify(e)}`);
    }
    this.holdingCallback = null;
    this.operatingCallback = null;
  }

  setOverride(value: string): void {
    appState.handOverride = value;
    Prefs.put(PREF_HAND_OVERRIDE, value);
  }

  /** Lets the emulator (no grip sensor) exercise the adaptive layout. */
  simulate(hand: Hand): void {
    appState.hand = hand;
    appState.thumbHand = hand;
    appState.handSource = 'simulated';
  }

  private tryHolding(): boolean {
    const callback = (status: motion.HoldingHandStatus): void => {
      this.observe(GripServiceImpl.fromHolding(status), 'grip');
      Log.d(TAG, `holding hand -> ${appState.hand}`);
    };
    try {
      motion.on('holdingHandChanged', callback);
      this.holdingCallback = callback;
      appState.handSource = 'grip';
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `holdingHandChanged unavailable: ${err.code} ${err.message}`);
      return false;
    }
  }

  private tryOperating(): void {
    const callback = (status: motion.OperatingHandStatus): void => {
      this.observe(GripServiceImpl.fromOperating(status), 'touch');
    };
    try {
      motion.on('operatingHandChanged', callback);
      this.operatingCallback = callback;
      appState.handSource = 'touch';
      try {
        const recent = GripServiceImpl.fromOperating(motion.getRecentOperatingHandStatus());
        appState.hand = recent;
        if (recent === 'left' || recent === 'right') {
          appState.thumbHand = recent;
        }
      } catch (inner) {
        Log.d(TAG, 'no recent operating hand');
      }
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `operatingHandChanged unavailable: ${err.code} ${err.message}`);
      appState.handSource = 'unavailable';
    }
  }

  private static fromHolding(status: motion.HoldingHandStatus): Hand {
    switch (status) {
      case motion.HoldingHandStatus.LEFT_HAND_HELD:
        return 'left';
      case motion.HoldingHandStatus.RIGHT_HAND_HELD:
        return 'right';
      case motion.HoldingHandStatus.BOTH_HANDS_HELD:
        return 'both';
      case motion.HoldingHandStatus.NOT_HELD:
        return 'none';
      default:
        return 'unknown';
    }
  }

  private static fromOperating(status: motion.OperatingHandStatus): Hand {
    switch (status) {
      case motion.OperatingHandStatus.LEFT_HAND_OPERATED:
        return 'left';
      case motion.OperatingHandStatus.RIGHT_HAND_OPERATED:
        return 'right';
      default:
        return 'unknown';
    }
  }
}

export const gripService: GripServiceImpl = new GripServiceImpl();
