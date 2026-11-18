import { curves } from '@kit.ArkUI';

/**
 * One motion language for the whole app. Things that move use a spring that settles without bouncing;
 * things that only come and go fade. Every effect carries its own animation, so it plays however the
 * state changed: a tap, a message from the computer, or a timer.
 */

/** Quick and settled (damping ≈ 0.92): selections, buttons swapping, chevrons. */
export const SPRING: ICurve = curves.interpolatingSpring(0, 1, 380, 36);
/** Softer (damping ≈ 0.97): content arriving, panels opening, pages fading through. */
export const SPRING_SOFT: ICurve = curves.interpolatingSpring(0, 1, 240, 30);

/** One control taking another's place in the same slot: send ↔ stop, a spinner ↔ a check mark. */
export const SWAP: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
  .animation({ curve: SPRING });

/**
 * New content arriving from below: a message, a card. Leaving is instant, so an item that is redrawn
 * as a new copy (its key changed) never shows twice.
 */
export const RISE: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 })).animation({ curve: SPRING_SOFT }),
  TransitionEffect.IDENTITY);

/** Something opening under what it belongs to: a search field, a banner, details under a header. */
export const REVEAL: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })).animation({ curve: SPRING }),
  TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -4 })).animation({ duration: 140, curve: Curve.Sharp }));

/** Two states of one area handing over in place, e.g. the composer's tools and the recording bar. */
export const SHIFT: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.translate({ y: 8 }))
  .animation({ curve: SPRING });

/**
 * Content replacing other content in a column (loaded results, another view of a page): the old goes
 * at once, so the two never stack up, and the new settles in with a short fade and lift.
 */
export const ENTER: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 6 })).animation({ curve: SPRING_SOFT }),
  TransitionEffect.IDENTITY);

/** A plain cross-fade between layers stacked in one place: loading to loaded, draft to conversation. */
export const FADE: TransitionEffect = TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.Friction });

/** Colours and sizes of a control that changes state in place (selected, enabled, on). */
export const STATE_CHANGE: AnimateParam = { duration: 180, curve: Curve.Friction };

/**
 * Runs a state change as one animation: what moves slides to its new place, what appears plays its
 * transition. For changes that reshape a layout (opening a section, picking a different mode).
 */
export function animate(ui: UIContext, change: () => void, curve: ICurve = SPRING): void {
  ui.animateTo({ curve: curve }, change);
}
