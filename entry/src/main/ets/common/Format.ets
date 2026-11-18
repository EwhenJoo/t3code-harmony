/** Display helpers shared by list and thread views. */

export function parseTime(iso: string | null | undefined): number {
  if (!iso) {
    return 0;
  }
  const t = Date.parse(iso);
  return isNaN(t) ? 0 : t;
}

export function relativeTime(iso: string | null | undefined, now: number): string {
  const t = parseTime(iso);
  if (t === 0) {
    return '';
  }
  const diff = Math.max(0, now - t);
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (diff < minute) {
    return '刚刚';
  }
  if (diff < hour) {
    return `${Math.floor(diff / minute)} 分钟前`;
  }
  if (diff < day) {
    return `${Math.floor(diff / hour)} 小时前`;
  }
  if (diff < 2 * day) {
    return '昨天';
  }
  if (diff < 7 * day) {
    return `${Math.floor(diff / day)} 天前`;
  }
  const d = new Date(t);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

export function durationLabel(fromIso: string | null | undefined, toIso: string | null | undefined, now: number): string {
  const from = parseTime(fromIso);
  if (from === 0) {
    return '';
  }
  const to = toIso ? parseTime(toIso) : now;
  const seconds = Math.max(0, Math.round((to - from) / 1000));
  if (seconds < 1) {
    return '';
  }
  if (seconds < 60) {
    return `${seconds} 秒`;
  }
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes} 分 ${seconds % 60} 秒`;
  }
  return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
}

/** First non-empty line, whitespace-collapsed, for previews. */
export function previewText(text: string | null | undefined, max: number): string {
  if (!text) {
    return '';
  }
  const collapsed = text.replace(/[`*#>_~]/g, '').replace(/\s+/g, ' ').trim();
  return collapsed.length > max ? collapsed.substring(0, max) + '…' : collapsed;
}

export function providerLabel(instanceId: string | undefined): string {
  if (!instanceId) {
    return '';
  }
  const id = instanceId.toLowerCase();
  if (id.indexOf('claude') >= 0) {
    return 'Claude';
  }
  if (id.indexOf('codex') >= 0) {
    return 'Codex';
  }
  if (id.indexOf('cursor') >= 0) {
    return 'Cursor';
  }
  if (id.indexOf('grok') >= 0) {
    return 'Grok';
  }
  if (id.indexOf('opencode') >= 0) {
    return 'OpenCode';
  }
  if (id.indexOf('gemini') >= 0) {
    return 'Gemini';
  }
  return instanceId;
}

export function modelLabel(model: string | undefined): string {
  if (!model) {
    return '';
  }
  return model.replace(/^claude-/, '').replace(/(\d)-(\d)/g, '$1.$2').replace(/-/g, ' ').replace(/\b(\w)/g, (m: string) => m.toUpperCase()).replace(/^Gpt /, 'GPT-');
}

export function shortPath(path: string | null | undefined): string {
  if (!path) {
    return '';
  }
  const parts = path.split(/[\\/]/).filter((p: string) => p.length > 0);
  return parts.length > 0 ? parts[parts.length - 1] : path;
}

export function newId(): string {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 32; i++) {
    out += hex.charAt(Math.floor(Math.random() * 16));
  }
  return `${out.substring(0, 8)}-${out.substring(8, 12)}-4${out.substring(13, 16)}-a${out.substring(17, 20)}-${out.substring(20, 32)}`;
}
