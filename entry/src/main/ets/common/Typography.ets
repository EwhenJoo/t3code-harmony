/**
 * One type scale and spacing grid for every screen (vp). Compact like the official T3 mobile
 * app, mapped onto HarmonyOS levels: Title_S 20, Body_M 14, Body_S 12, Caption 11.
 */
export class Type {
  /** Page titles: 线程, 设置. */
  static readonly pageTitle: number = 20;
  /** Conversation and sub-page titles in the header bar. */
  static readonly barTitle: number = 15;
  /** Body: messages, list titles, settings rows, inputs. */
  static readonly body: number = 14;
  static readonly bodyLine: number = 21;
  /** Secondary: metadata, captions, section labels, trailing state. */
  static readonly small: number = 12;
  static readonly smallLine: number = 16;
  static readonly caption: number = 11;
  /** Code and command output. */
  static readonly code: number = 12;
  static readonly codeLine: number = 18;
}

export class Space {
  /** Page margin: every left edge (titles, labels, glyphs, text) sits on this line. */
  static readonly margin: number = 16;
  /** Sidebar rows are rounded cards inset by this much; their content still lands on `margin`. */
  static readonly cardInset: number = 6;
  /** Minimum touch target (HarmonyOS). */
  static readonly hit: number = 40;
  /** Plain icon buttons: glyph size, and how far the 40vp target overhangs the margin. */
  static readonly icon: number = 20;
  static readonly iconOverhang: number = 10;
  static readonly badge: number = 18;
}

/** Page margin of full-width pages at 600vp and wider: HDS large titles sit on this line there. */
export const WIDE_MARGIN: number = 24;
