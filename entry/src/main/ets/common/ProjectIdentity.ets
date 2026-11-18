/**
 * The desktop's project identity, ported so a project looks the same on the phone: the palette of
 * icon colors and the monogram + color derived from a project's name when it has no icon of its own
 * (apps/web/src/projectIdentity.ts in T3 Code).
 */

/** Same order as the desktop's PROJECT_ICON_COLORS; the hash below indexes into it. */
export const PROJECT_COLORS: string[] = [
  'gray', 'red', 'orange', 'amber', 'yellow', 'lime', 'green', 'emerald', 'teal',
  'cyan', 'sky', 'blue', 'indigo', 'violet', 'purple', 'fuchsia', 'pink', 'rose',
];

export class ProjectIdentity {
  monogram: string = 'PR';
  color: string = 'blue';
}

function normalizeProjectName(name: string): string {
  return name.normalize('NFKC').trim();
}

function codePoints(text: string): string[] {
  const out: string[] = [];
  for (const glyph of text) {
    out.push(glyph);
  }
  return out;
}

const WORD = /[\p{L}\p{N}]+/gu;
const DIGIT = /\p{N}/u;

function projectMonogram(name: string): string {
  const words: string[] = normalizeProjectName(name).match(WORD) ?? [];
  if (words.length === 0) {
    return 'PR';
  }
  const glyphs = codePoints(words[0]);
  const first = glyphs.length > 0 ? glyphs[0] : 'P';
  let second: string | undefined = glyphs.slice(1).find((g: string) => DIGIT.test(g));
  if (second === undefined) {
    if (words.length > 1) {
      const last = codePoints(words[words.length - 1]);
      second = last.length > 0 ? last[0] : undefined;
    } else {
      second = glyphs.length > 0 ? glyphs[glyphs.length - 1] : undefined;
    }
  }
  return codePoints(`${first}${second ?? first}`.toUpperCase()).slice(0, 2).join('');
}

function projectColor(name: string): string {
  const normalized = normalizeProjectName(name).toLocaleLowerCase('en-US');
  const seed = normalized.length > 0 ? normalized : 'project';
  let index = 0;
  for (const glyph of seed) {
    index = (index * 31 + (glyph.codePointAt(0) ?? 0)) % PROJECT_COLORS.length;
  }
  return PROJECT_COLORS[index] ?? 'blue';
}

export function deriveProjectIdentity(name: string): ProjectIdentity {
  const identity = new ProjectIdentity();
  identity.monogram = projectMonogram(name);
  identity.color = projectColor(name);
  return identity;
}

export function isProjectColor(color: string | undefined): boolean {
  return color !== undefined && PROJECT_COLORS.indexOf(color) >= 0;
}
