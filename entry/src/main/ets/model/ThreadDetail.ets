import {
  AppThread,
  ConversationMessage,
  DomainEvent,
  ProjectedTurnItem,
  PromptSuggestion,
  RunRecord,
  RuntimeRequest,
  ThreadProjection,
  ThreadStreamItem,
  TurnItem,
} from './Types';

const WORK_TYPES: string[] = [
  'command_execution', 'dynamic_tool', 'file_change', 'web_search', 'file_search', 'mcp_tool_call',
  'todo_list', 'subagent', 'compaction', 'reasoning', 'checkpoint', 'image_view', 'context_compaction',
];
const HIDDEN_TYPES: string[] = ['fork', 'handoff', 'checkpoint'];

export class FeedEntry {
  key: string;
  kind: string; // user | assistant | work | approval | question | notice | plan
  item: TurnItem | null = null;
  items: TurnItem[] = [];
  pending: boolean = false;
  running: boolean = false;
  /** Used by work groups so expansion survives re-renders. */
  signature: string = '';

  constructor(key: string, kind: string) {
    this.key = key;
    this.kind = kind;
  }
}

@ObservedV2
export class ThreadDetailState {
  threadId: string;
  @Trace loading: boolean = true;
  @Trace error: string = '';
  @Trace thread: AppThread | null = null;
  @Trace items: TurnItem[] = [];
  @Trace requests: RuntimeRequest[] = [];
  @Trace runs: RunRecord[] = [];
  @Trace feed: FeedEntry[] = [];
  @Trace version: number = 0;
  @Trace hasMoreHistory: boolean = false;
  /** The server's latest suggestion for this thread; see `suggestionText` for when it applies. */
  @Trace promptSuggestion: PromptSuggestion | null = null;
  sequence: number = 0;
  private rebuildTimer: number = -1;

  constructor(threadId: string) {
    this.threadId = threadId;
  }

  applyProjection(projection: ThreadProjection, sequence: number, hasMoreHistory: boolean): void {
    this.thread = projection.thread;
    const visible: ProjectedTurnItem[] = projection.visibleTurnItems ?? [];
    this.items = visible.length > 0 ? visible.map((p: ProjectedTurnItem) => p.item) : projection.turnItems.slice();
    this.requests = projection.runtimeRequests.slice();
    this.runs = projection.runs.slice();
    this.sequence = sequence;
    this.hasMoreHistory = hasMoreHistory;
    this.loading = false;
    this.error = '';
    this.rebuildNow();
  }

  applyStreamItem(item: ThreadStreamItem): void {
    if (item.kind === 'snapshot' && item.projection) {
      this.applyProjection(item.projection, item.snapshotSequence ?? 0, false);
      return;
    }
    if (item.kind === 'event' && item.event) {
      if (item.sequence !== undefined) {
        this.sequence = Math.max(this.sequence, item.sequence);
      }
      this.applyEvent(item.event);
    }
  }

  private applyEvent(event: DomainEvent): void {
    if (event.threadId !== undefined && event.threadId !== this.threadId) {
      return;
    }
    switch (event.type) {
      case 'turn-item.updated': {
        const next = event.payload as TurnItem;
        if (next.threadId !== this.threadId) {
          return;
        }
        const list = this.items.slice();
        const idx = list.findIndex((it: TurnItem) => it.id === next.id);
        if (idx >= 0) {
          list[idx] = next;
        } else {
          list.push(next);
        }
        this.items = list;
        this.scheduleRebuild();
        break;
      }
      case 'message.updated': {
        const message = event.payload as ConversationMessage;
        const list = this.items.slice();
        const idx = list.findIndex((it: TurnItem) => it.messageId === message.id);
        if (idx >= 0) {
          const updated: TurnItem = cloneItem(list[idx]);
          updated.text = message.text;
          updated.streaming = message.streaming ?? false;
          list[idx] = updated;
          this.items = list;
          this.scheduleRebuild();
        }
        break;
      }
      case 'runtime-request.updated': {
        const request = event.payload as RuntimeRequest;
        const list = this.requests.slice();
        const idx = list.findIndex((r: RuntimeRequest) => r.id === request.id);
        if (idx >= 0) {
          list[idx] = request;
        } else {
          list.push(request);
        }
        this.requests = list;
        this.scheduleRebuild();
        break;
      }
      case 'run.created':
      case 'run.updated': {
        const run = event.payload as RunRecord;
        if (!run || run.id === undefined) {
          return;
        }
        const list = this.runs.slice();
        const idx = list.findIndex((r: RunRecord) => r.id === run.id);
        if (idx >= 0) {
          list[idx] = run;
        } else {
          list.push(run);
        }
        this.runs = list;
        this.scheduleRebuild();
        break;
      }
      default:
        break;
    }
  }

  /**
   * The suggestion to offer, like the desktop: only while it belongs to the latest run and that run
   * completed (a message withdrawn before it started does not count as a newer run). '' = none.
   */
  get suggestionText(): string {
    const suggestion = this.promptSuggestion;
    if (suggestion === null || (suggestion.text ?? '').trim().length === 0) {
      return '';
    }
    let latestIndex = -1;
    for (let i = 0; i < this.runs.length; i++) {
      const run = this.runs[i];
      const withdrawn = run.status === 'cancelled' && (run.startedAt ?? null) === null;
      if (!withdrawn && (latestIndex < 0 || run.ordinal > this.runs[latestIndex].ordinal)) {
        latestIndex = i;
      }
    }
    if (latestIndex < 0) {
      return '';
    }
    const last = this.runs[latestIndex];
    return last.id === suggestion.runId && last.status === 'completed' ? suggestion.text.trim() : '';
  }

  get activeRun(): RunRecord | null {
    for (let i = this.runs.length - 1; i >= 0; i--) {
      const status = this.runs[i].status;
      if (status === 'running' || status === 'starting' || status === 'preparing' || status === 'queued' || status === 'waiting') {
        return this.runs[i];
      }
    }
    return null;
  }

  pendingRequest(requestId: string | undefined): RuntimeRequest | null {
    if (!requestId) {
      return null;
    }
    for (const request of this.requests) {
      if (request.id === requestId && request.status === 'pending') {
        return request;
      }
    }
    return null;
  }

  private scheduleRebuild(): void {
    if (this.rebuildTimer >= 0) {
      return;
    }
    this.rebuildTimer = setTimeout(() => {
      this.rebuildTimer = -1;
      this.rebuildNow();
    }, 60);
  }

  rebuildNow(): void {
    this.feed = buildFeed(this.items, this);
    this.version++;
  }
}

function cloneItem(item: TurnItem): TurnItem {
  return JSON.parse(JSON.stringify(item)) as TurnItem;
}

/** The server's own "Preparing workspace" step is noise once it succeeds; failures still show. */
function isRoutinePreparation(item: TurnItem): boolean {
  return item.type === 'command_execution' && item.input === 'Preparing workspace' &&
    item.status === 'completed' && (item.exitCode ?? 0) === 0;
}

function isWork(item: TurnItem): boolean {
  return WORK_TYPES.indexOf(item.type) >= 0;
}

export function buildFeed(items: TurnItem[], state: ThreadDetailState): FeedEntry[] {
  const topLevel = items
    .filter((it: TurnItem) => (it.parentItemId ?? null) === null && HIDDEN_TYPES.indexOf(it.type) < 0 && !isRoutinePreparation(it))
    .sort((a: TurnItem, b: TurnItem) => a.ordinal - b.ordinal);
  const feed: FeedEntry[] = [];
  let group: FeedEntry | null = null;
  const flushGroup = (): void => {
    if (group !== null) {
      group.signature = `${group.items.length}:${group.items[group.items.length - 1].status ?? ''}`;
      group.running = group.items.some((it: TurnItem) => it.status === 'running' || it.status === 'in_progress' || it.streaming === true);
      feed.push(group);
      group = null;
    }
  };
  topLevel.forEach((item: TurnItem) => {
    if (isWork(item)) {
      if (group === null) {
        group = new FeedEntry(`w:${item.id}`, 'work');
      }
      group.items.push(item);
      return;
    }
    flushGroup();
    let kind = 'notice';
    switch (item.type) {
      case 'user_message':
        kind = 'user';
        break;
      case 'assistant_message':
        kind = 'assistant';
        break;
      case 'approval_request':
        kind = 'approval';
        break;
      case 'user_input_request':
        kind = 'question';
        break;
      case 'proposed_plan':
        kind = 'plan';
        break;
      default:
        kind = 'notice';
    }
    if (kind === 'assistant' && (item.text ?? '').trim().length === 0 && item.streaming !== true) {
      return;
    }
    const entry = new FeedEntry(`${kind}:${item.id}:${item.updatedAt ?? ''}:${(item.text ?? '').length}`, kind);
    entry.item = item;
    entry.running = item.streaming === true || item.status === 'running';
    if (kind === 'approval' || kind === 'question') {
      entry.pending = state.pendingRequest(item.requestId) !== null;
      entry.key = `${entry.key}:${entry.pending ? 'p' : 'r'}`;
    }
    feed.push(entry);
  });
  flushGroup();
  return feed;
}

export function workItemTitle(item: TurnItem): string {
  switch (item.type) {
    case 'command_execution':
      return typeof item.input === 'string' ? (item.input as string) : (item.title ?? '运行命令');
    case 'dynamic_tool': {
      const name = item.toolName ?? item.title ?? '工具';
      return `${name}${toolInputSummary(item)}`;
    }
    case 'file_change': {
      const parts = (item.fileName ?? '').split(/[\\/]/);
      const counts = (item.additions !== undefined || item.deletions !== undefined)
        ? `  +${item.additions ?? 0} −${item.deletions ?? 0}` : '';
      return `${parts[parts.length - 1]}${counts}`;
    }
    case 'web_search':
      return `搜索 ${item.query ?? item.title ?? ''}`;
    case 'file_search':
      return `查找 ${item.query ?? item.title ?? ''}`;
    case 'reasoning':
      return item.title ?? '思考';
    case 'todo_list':
      return item.title ?? '待办清单';
    case 'subagent':
      return item.title ?? '子代理';
    case 'compaction':
      return '上下文已压缩';
    default:
      return item.title ?? item.type;
  }
}

function toolInputSummary(item: TurnItem): string {
  const input = item.input;
  if (input === undefined || input === null) {
    return '';
  }
  if (typeof input === 'string') {
    return ` · ${(input as string).substring(0, 80)}`;
  }
  const record = input as Record<string, Object>;
  const preferred = ['command', 'file_path', 'path', 'pattern', 'query', 'url', 'description', 'prompt'];
  for (const key of preferred) {
    const value = record[key];
    if (typeof value === 'string' && (value as string).length > 0) {
      return ` · ${(value as string).replace(/\s+/g, ' ').substring(0, 80)}`;
    }
  }
  return '';
}

export function workItemIcon(item: TurnItem): string {
  switch (item.type) {
    case 'command_execution':
      return '❯';
    case 'file_change':
      return '✎';
    case 'web_search':
    case 'file_search':
      return '⌕';
    case 'reasoning':
      return '✦';
    case 'todo_list':
      return '☑';
    case 'subagent':
      return '◎';
    default:
      return '⚙';
  }
}
