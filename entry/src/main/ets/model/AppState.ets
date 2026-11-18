import { CloudComputer, ProjectShell, SavedEnvironment, ServerConfig, ShellSnapshot, ShellStreamItem, ThreadShell } from './Types';
import { parseTime } from '../common/Format';

export type ConnectionPhase = 'unpaired' | 'connecting' | 'connected' | 'reconnecting' | 'offline';
export type Hand = 'left' | 'right' | 'both' | 'none' | 'unknown';

const WORKING_STATUSES: string[] = ['preparing', 'queued', 'starting', 'running', 'waiting'];

export function isWorking(thread: ThreadShell): boolean {
  return WORKING_STATUSES.indexOf(thread.status) >= 0 || (thread.activeRunId ?? null) !== null;
}

export function needsAttention(thread: ThreadShell): boolean {
  return (thread.pendingRuntimeRequest ?? null) !== null;
}

export function isSettled(thread: ThreadShell): boolean {
  const settledAt = parseTime(thread.settledAt);
  if (settledAt === 0) {
    return false;
  }
  return parseTime(thread.unsettledAt) <= settledAt;
}

/** When the thread last had something new to read: its latest run ending, else its latest message. */
export function finishedAt(thread: ThreadShell): number {
  return Math.max(parseTime(thread.latestRunCompletedAt), parseTime(thread.latestVisibleMessage?.updatedAt));
}

/**
 * Finished since you last looked at it (here or on any other client), like the desktop's "Completed"
 * pill: once read, it is not news any more.
 */
export function isUnreadDone(thread: ThreadShell): boolean {
  if (thread.status !== 'completed' || isSettled(thread) || isWorking(thread) || needsAttention(thread)) {
    return false;
  }
  const finished = finishedAt(thread) || parseTime(thread.updatedAt);
  return finished > parseTime(thread.lastVisitedAt);
}

/** States a sidebar dot can show, most pressing first. */
const STATE_ORDER: string[] = ['approval', 'input', 'failed', 'working', 'done'];

/** What a status dot says about one thread: approval, input, failed, working, done, or '' for nothing. */
export function threadState(thread: ThreadShell): string {
  if (needsAttention(thread)) {
    return (thread.pendingRuntimeRequest?.kind ?? '') === 'user_input' ? 'input' : 'approval';
  }
  if (isWorking(thread)) {
    return 'working';
  }
  if (thread.status === 'failed' && !isSettled(thread)) {
    return 'failed';
  }
  return isUnreadDone(thread) ? 'done' : '';
}

/** The most pressing state among several threads, for a folded project's dot. */
export function mostPressingState(threads: ThreadShell[]): string {
  let best = STATE_ORDER.length;
  threads.forEach((t: ThreadShell) => {
    const index = STATE_ORDER.indexOf(threadState(t));
    if (index >= 0 && index < best) {
      best = index;
    }
  });
  return best < STATE_ORDER.length ? STATE_ORDER[best] : '';
}

/** Projects with the same name on several computers share one group. */
export function projectNameKey(title: string): string {
  return title.normalize('NFKC').trim();
}

export function isSnoozed(thread: ThreadShell, now: number): boolean {
  return parseTime(thread.snoozedUntil) > now;
}

/**
 * Whether a thread gets its own row, like the desktop sidebar: not archived or deleted, not a subagent,
 * not a side chat (both live inside their parent). See also `AppState.listsThread`, which also folds
 * threads delegated from another connected computer under their parent there.
 */
export function isVisibleInList(thread: ThreadShell): boolean {
  if (thread.deletedAt || thread.archivedAt) {
    return false;
  }
  const relation = thread.lineage?.relationshipToParent ?? null;
  return relation !== 'subagent' && thread.lineage?.sideChat !== true;
}

/** One connected computer: its saved credentials plus live connection state. */
@ObservedV2
export class EnvironmentState {
  @Trace env: SavedEnvironment;
  @Trace phase: ConnectionPhase = 'connecting';
  @Trace phaseDetail: string = '';
  @Trace config: ServerConfig | null = null;
  @Trace shellLoaded: boolean = false;
  snapshotSequence: number = 0;

  constructor(env: SavedEnvironment) {
    this.env = env;
  }

  get id(): string {
    return this.env.id;
  }

  get label(): string {
    return this.env.label.length > 0 ? this.env.label : '电脑';
  }

  get isConnect(): boolean {
    return this.env.kind === 'connect';
  }
}

/** Conversations shown per project group before "再显示". */
export const PROJECT_ROW_LIMIT = 5;

/** A project offered when starting a conversation: one entry per name, with every computer that has it. */
export class ProjectChoice {
  key: string = '';
  title: string = '';
  /** The project that speaks for the name (its icon). */
  project: ProjectShell | null = null;
  projects: ProjectShell[] = [];
  latest: number = 0;
}

/** Rows of the home list; headers and threads share one flat array for virtual scrolling. */
@ObservedV2
export class HomeRow {
  key: string;
  kind: string; // 'header' | 'thread' | 'more' | 'empty'
  title: string = '';
  count: number = 0;
  thread: ThreadShell | null = null;
  project: ProjectShell | null = null;
  section: string = '';
  /** The last thread of its section draws no separator, so sections read as clean groups. */
  lastInSection: boolean = false;
  /** Header only: the shelf is folded away (the settled shelf when "show settled" is off). */
  collapsed: boolean = false;
  /** Project header only: how many of its threads need you. */
  attention: number = 0;
  /** Project header only: the most pressing state of its threads (see `threadState`), for the folded dot. */
  state: string = '';
  /** Project group (header, its rows and its "more" row): `name:<project name>` or `id:<projectId>`. */
  groupKey: string = '';

  constructor(key: string, kind: string) {
    this.key = key;
    this.kind = kind;
  }
}

@ObservedV2
export class AppState {
  @Trace pairingBusy: boolean = false;
  @Trace pairingError: string = '';
  /** Every computer this phone is connected to; their threads share one list. */
  @Trace environments: EnvironmentState[] = [];
  /** Projects and threads of all computers, each tagged with its `environmentId`. */
  @Trace projects: ProjectShell[] = [];
  @Trace threads: ThreadShell[] = [];
  @Trace now: number = Date.now();

  // Grip awareness (left/right hand) and immersive light preferences.
  /** Raw sensor reading: left / right / both / none / unknown. Changes often while the phone is handled. */
  @Trace hand: Hand = 'unknown';
  /** Last one-handed grip that held steady; the layout follows this so controls never flicker. */
  @Trace thumbHand: Hand = 'right';
  @Trace handSource: string = 'unavailable';
  @Trace handOverride: string = 'auto';
  /** 沉浸光感 is always on (HarmonyOS design default); kept as a flag for the code paths. */
  @Trace lightEffects: boolean = true;
  @Trace immersiveMaterial: boolean = false;
  /** Preferences (see services/UserSettings). */
  @Trace haptics: boolean = true;
  @Trace followUp: string = 'steer';
  @Trace returnKey: string = 'newline';
  @Trace notify: boolean = true;
  @Trace notifyAttention: boolean = true;
  @Trace notifyDone: boolean = true;
  @Trace notifyFailed: boolean = true;
  /** Push helper this phone is bound to (empty when none) and its last status line. */
  @Trace pushHelperName: string = '';
  @Trace pushHelperDetail: string = '';
  /** A one-line message for a toast from outside the UI (deep links); the root page shows and clears it. */
  @Trace notice: string = '';
  @Trace showSettled: boolean = false;
  /** The new-conversation project picker (opened by the compose button and the empty detail pane). */
  @Trace newChatPickerShown: boolean = false;
  /** Conversations with an unsent message written on this phone (see services/Drafts). */
  @Trace draftThreadIds: string[] = [];
  /** Home list grouping: 'project' (like the desktop sidebar) or 'status'. */
  @Trace groupBy: string = 'project';
  /** Folded project groups, `<environmentId>|<projectId>`. */
  @Trace collapsedProjects: string[] = [];
  @Trace appearance: string = 'system';

  // T3 Connect account (see services/CloudAccount).
  /** Signed-in T3 account email; empty when signed out. */
  @Trace cloudEmail: string = '';
  /** Sign-in flow step: 'email' → 'code' → 'computers'. */
  @Trace cloudStep: string = 'email';
  @Trace cloudBusy: boolean = false;
  @Trace cloudError: string = '';
  @Trace cloudCodeSentTo: string = '';
  @Trace cloudComputers: CloudComputer[] = [];
  @Trace cloudComputersLoaded: boolean = false;
  /** Environment id currently being connected through the relay. */
  @Trace cloudConnectingId: string = '';
  /** Shown while the computer must approve this device; matches the code on the computer. */
  @Trace cloudApprovalCode: string = '';
  @Trace cloudApprovalHost: string = '';

  /** Thread shown in the detail pane of the two-column (unfolded / tablet) layout. */
  @Trace selectedThreadId: string = '';

  // Window metrics written by EntryAbility.
  @Trace topInset: number = 0;
  @Trace bottomInset: number = 0;
  /** Soft keyboard height in vp (0 when hidden); floating controls step aside while typing. */
  @Trace keyboardHeight: number = 0;
  @Trace windowWidth: number = 360;
  /** Vertical fold crease (vp from the window's left edge) while unfolded; 0 when there is none. */
  @Trace creaseX: number = 0;
  @Trace creaseWidth: number = 0;

  /**
   * Two columns (list + conversation) from HarmonyOS's medium breakpoint up: an unfolded
   * Pura X Max (~795vp) or a tablet. The folded cover screen and phones stay single-column.
   */
  get isWide(): boolean {
    return this.windowWidth >= 600;
  }

  /**
   * Width of the thread list column; the whole window when single-column. On an unfolded
   * book-style foldable the split sits on the crease so neither pane straddles the fold
   * (HarmonyOS crease avoidance, same rule as the official app's hinge alignment).
   */
  get listPaneWidth(): number {
    if (!this.isWide) {
      return this.windowWidth;
    }
    if (this.onCrease) {
      return this.creaseX;
    }
    return Math.min(380, Math.max(280, Math.round(this.windowWidth * 0.32)));
  }

  /** Gap between the panes: the crease itself when the split is aligned to it. */
  get paneGap(): number {
    return this.isWide && this.onCrease ? this.creaseWidth : 0;
  }

  private get onCrease(): boolean {
    return this.creaseX >= 280 && this.windowWidth - this.creaseX - this.creaseWidth >= 320;
  }

  /**
   * Effective hand that UI should lay out for. Two-handed, set-down and unknown readings keep the
   * last steady one-handed grip instead of snapping back to the right.
   */
  get layoutHand(): Hand {
    if (this.handOverride === 'left' || this.handOverride === 'right') {
      return this.handOverride as Hand;
    }
    return this.thumbHand === 'left' ? 'left' : 'right';
  }

  get hasEnvironments(): boolean {
    return this.environments.length > 0;
  }

  /** More than one computer: rows, headers and pickers name the computer. */
  get multiEnv(): boolean {
    return this.environments.length > 1;
  }

  /** The list has something to show once any computer has delivered its first snapshot. */
  get anyShellLoaded(): boolean {
    return this.environments.some((e: EnvironmentState) => e.shellLoaded);
  }

  /** Overall status: connected when every computer is; offline only when none is reachable. */
  get phase(): ConnectionPhase {
    if (this.environments.length === 0) {
      return 'unpaired';
    }
    if (this.environments.every((e: EnvironmentState) => e.phase === 'connected')) {
      return 'connected';
    }
    if (this.environments.every((e: EnvironmentState) => e.phase === 'offline')) {
      return 'offline';
    }
    return this.environments.some((e: EnvironmentState) => e.shellLoaded) ? 'reconnecting' : 'connecting';
  }

  environmentFor(id: string | undefined): EnvironmentState | null {
    if (id === undefined || id.length === 0) {
      return null;
    }
    for (const env of this.environments) {
      if (env.id === id) {
        return env;
      }
    }
    return null;
  }

  /** The computer a thread runs on (falls back to the only computer when untagged). */
  environmentOfThread(threadId: string): EnvironmentState | null {
    const thread = this.threadFor(threadId);
    const tagged = this.environmentFor(thread?.environmentId);
    if (tagged !== null) {
      return tagged;
    }
    return this.environments.length > 0 ? this.environments[0] : null;
  }

  projectFor(id: string, environmentId: string = ''): ProjectShell | null {
    for (const project of this.projects) {
      if (project.id === id && (environmentId.length === 0 || project.environmentId === environmentId)) {
        return project;
      }
    }
    return null;
  }

  threadFor(id: string, environmentId: string = ''): ThreadShell | null {
    for (const thread of this.threads) {
      if (thread.id === id && (environmentId.length === 0 || thread.environmentId === environmentId)) {
        return thread;
      }
    }
    return null;
  }

  /** Drops a computer's threads and projects (it was removed, or its route changed). */
  clearEnvironmentData(environmentId: string): void {
    this.threads = this.threads.filter((t: ThreadShell) => t.environmentId !== environmentId);
    this.projects = this.projects.filter((p: ProjectShell) => p.environmentId !== environmentId);
  }

  /**
   * A thread another computer delegated here, while that computer is connected too and the parent is
   * still there: the desktop shows it under the parent (on the other computer), so it gets no row.
   */
  isDelegatedUnderParent(thread: ThreadShell): boolean {
    const from = thread.delegatedFrom ?? null;
    if (from === null || !this.environments.some((e: EnvironmentState) => e.id === from.environmentId)) {
      return false;
    }
    const parent = this.threadFor(from.threadId, from.environmentId);
    return parent !== null && !parent.archivedAt && !parent.deletedAt;
  }

  /** The threads that get a row in the list (and count in the header), as in the desktop sidebar. */
  listsThread(thread: ThreadShell): boolean {
    return isVisibleInList(thread) && !this.isDelegatedUnderParent(thread);
  }

  get workingCount(): number {
    // Matches the 运行中 section: a thread waiting on the user is counted once, under 待处理.
    return this.threads.filter((t: ThreadShell) => this.listsThread(t) && isWorking(t) && !needsAttention(t)).length;
  }

  get attentionCount(): number {
    return this.threads.filter((t: ThreadShell) => this.listsThread(t) && needsAttention(t)).length;
  }

  private applySnapshot(env: EnvironmentState, snapshot: ShellSnapshot, mergeProjectsOnly: boolean): void {
    const envId = env.id;
    const projects = snapshot.projects.map((p: ProjectShell) => tagProject(p, envId));
    if (mergeProjectsOnly) {
      const next = this.projects.slice();
      projects.forEach((project: ProjectShell) => {
        const idx = next.findIndex((p: ProjectShell) => p.id === project.id && p.environmentId === envId);
        if (idx >= 0) {
          next[idx] = project;
        } else {
          next.push(project);
        }
      });
      this.projects = next;
      return;
    }
    // Replace only this computer's share of the merged list.
    this.projects = this.projects.filter((p: ProjectShell) => p.environmentId !== envId).concat(projects);
    this.threads = this.threads.filter((t: ThreadShell) => t.environmentId !== envId)
      .concat(snapshot.threads.map((t: ThreadShell) => tagThread(t, envId)));
    env.snapshotSequence = snapshot.snapshotSequence;
    env.shellLoaded = true;
  }

  applyShellItem(env: EnvironmentState, item: ShellStreamItem): void {
    const envId = env.id;
    if (item.sequence !== undefined && item.sequence > env.snapshotSequence) {
      env.snapshotSequence = item.sequence;
    }
    switch (item.kind) {
      case 'snapshot':
        if (item.snapshot) {
          this.applySnapshot(env, item.snapshot, item.resolvedRepositoryIdentityRoots !== undefined && env.shellLoaded);
        }
        break;
      case 'thread.updated': {
        if (!item.thread) {
          break;
        }
        const thread = tagThread(item.thread, envId);
        const next = this.threads.slice();
        const idx = next.findIndex((t: ThreadShell) => t.id === thread.id && t.environmentId === envId);
        if (item.location === 'archive') {
          if (idx >= 0) {
            next.splice(idx, 1);
          }
        } else if (idx >= 0) {
          next[idx] = thread;
        } else {
          next.push(thread);
        }
        this.threads = next;
        break;
      }
      case 'thread.removed': {
        const id = item.threadId ?? '';
        this.threads = this.threads.filter((t: ThreadShell) => !(t.id === id && t.environmentId === envId));
        break;
      }
      case 'project.updated': {
        if (!item.project) {
          break;
        }
        const project = tagProject(item.project, envId);
        const next = this.projects.slice();
        const idx = next.findIndex((p: ProjectShell) => p.id === project.id && p.environmentId === envId);
        if (idx >= 0) {
          next[idx] = project;
        } else {
          next.push(project);
        }
        this.projects = next;
        break;
      }
      case 'project.removed': {
        const id = item.projectId ?? '';
        this.projects = this.projects.filter((p: ProjectShell) => !(p.id === id && p.environmentId === envId));
        break;
      }
      default:
        break;
    }
  }

  /**
   * Builds the sectioned home list the way the iOS list groups threads, across every computer.
   * `filter` is '' (everything), `env:<id>` (one computer) or a project id.
   */
  buildHomeRows(query: string, filter: string, settledLimit: number, groupBy: string = 'status',
    expandedProjects: string[] = [], includeSettledProjects: boolean = false): HomeRow[] {
    const now = this.now;
    const q = query.trim().toLowerCase();
    const envFilter = filter.startsWith('env:') ? filter.substring(4) : '';
    const projectFilter = envFilter.length === 0 ? filter : '';
    const visible = this.threads.filter((t: ThreadShell) => {
      if (!this.listsThread(t)) {
        return false;
      }
      if (envFilter.length > 0 && t.environmentId !== envFilter) {
        return false;
      }
      if (projectFilter.length > 0 && t.projectId !== projectFilter) {
        return false;
      }
      if (q.length === 0) {
        return true;
      }
      const project = this.projectFor(t.projectId, t.environmentId ?? '');
      const env = this.environmentFor(t.environmentId);
      return t.title.toLowerCase().indexOf(q) >= 0 ||
        (project !== null && project.title.toLowerCase().indexOf(q) >= 0) ||
        (env !== null && env.label.toLowerCase().indexOf(q) >= 0) ||
        (t.latestVisibleMessage?.text ?? '').toLowerCase().indexOf(q) >= 0;
    });
    const byRecent = (a: ThreadShell, b: ThreadShell): number => activityTime(b) - activityTime(a);

    if (groupBy === 'project') {
      return this.buildProjectRows(visible, q.length > 0, expandedProjects, includeSettledProjects);
    }
    const attention: ThreadShell[] = [];
    const working: ThreadShell[] = [];
    const inbox: ThreadShell[] = [];
    const snoozed: ThreadShell[] = [];
    const settled: ThreadShell[] = [];
    visible.forEach((t: ThreadShell) => {
      if (needsAttention(t)) {
        attention.push(t);
      } else if (isWorking(t)) {
        working.push(t);
      } else if (isSnoozed(t, now)) {
        snoozed.push(t);
      } else if (!isSettled(t) || (t.pinnedAt ?? null) !== null) {
        inbox.push(t);
      } else {
        settled.push(t);
      }
    });
    const rows: HomeRow[] = [];
    const pushSection = (key: string, title: string, list: ThreadShell[], limit: number, collapsed: boolean = false): void => {
      if (list.length === 0) {
        return;
      }
      list.sort(byRecent);
      const header = new HomeRow(`h:${key}`, 'header');
      header.title = title;
      header.count = list.length;
      header.section = key;
      header.collapsed = collapsed;
      rows.push(header);
      if (collapsed) {
        return;
      }
      const shown = list.slice(0, limit);
      shown.forEach((t: ThreadShell, index: number) => {
        const row = new HomeRow(`t:${t.environmentId ?? ''}:${t.id}`, 'thread');
        row.thread = t;
        row.project = this.projectFor(t.projectId, t.environmentId ?? '');
        row.section = key;
        row.lastInSection = index === shown.length - 1;
        rows.push(row);
      });
      if (list.length > limit) {
        const more = new HomeRow(`m:${key}`, 'more');
        more.count = list.length - limit;
        more.section = key;
        rows.push(more);
      }
    };
    pushSection('attention', '待处理', attention, 1000);
    pushSection('working', '运行中', working, 1000);
    pushSection('inbox', '收件箱', inbox, 1000);
    pushSection('snoozed', '稍后', snoozed, 1000);
    // Settled stays reachable as a collapsible shelf; searching always looks inside it.
    pushSection('settled', '已完成', settled, settledLimit, !this.showSettled && q.length === 0);
    if (rows.length === 0) {
      rows.push(new HomeRow('empty', 'empty'));
    }
    return rows;
  }

  /**
   * Grouped by project, like the desktop sidebar: projects ordered by their most recent conversation;
   * inside a project, what needs you first, then what is running, then the rest. A project with the
   * same name on several computers is one group. Settled conversations stay hidden unless "show
   * settled" is on (search always looks everywhere); projects with nothing else wait behind one row.
   */
  private buildProjectRows(visible: ThreadShell[], searching: boolean, expanded: string[],
    includeSettledProjects: boolean): HomeRow[] {
    // Needs you, running, pinned or failed, everything else, then what is already settled.
    // A failure counts only until it is settled, as on the desktop (a settled failed thread is history).
    const rank = (t: ThreadShell): number => needsAttention(t) ? 0 : isWorking(t) ? 1
      : (t.pinnedAt ?? null) !== null || (t.status === 'failed' && !isSettled(t)) ? 2 : isSettled(t) ? 4 : 3;
    const groups: Map<string, ThreadShell[]> = new Map();
    const projectsOf: Map<string, ProjectShell[]> = new Map();
    visible.forEach((t: ThreadShell) => {
      const project = this.projectFor(t.projectId, t.environmentId ?? '');
      const key = project !== null ? `name:${projectNameKey(project.title)}` : `id:${t.projectId ?? ''}`;
      const list = groups.get(key);
      if (list === undefined) {
        groups.set(key, [t]);
        projectsOf.set(key, project !== null ? [project] : []);
      } else {
        list.push(t);
        const projects = projectsOf.get(key) as ProjectShell[];
        if (project !== null && projects.indexOf(project) < 0) {
          projects.push(project);
        }
      }
    });
    const byThread = (a: ThreadShell, b: ThreadShell): number => {
      const r = rank(a) - rank(b);
      return r !== 0 ? r : activityTime(b) - activityTime(a);
    };
    const keys: string[] = [];
    groups.forEach((list: ThreadShell[], key: string) => {
      list.sort(byThread);
      keys.push(key);
    });
    // Projects by their latest activity, like the desktop's "recent" order.
    const latest = (list: ThreadShell[]): number =>
      list.reduce((max: number, t: ThreadShell) => Math.max(max, activityTime(t)), 0);
    keys.sort((a: string, b: string) => latest(groups.get(b) as ThreadShell[]) - latest(groups.get(a) as ThreadShell[]));
    const rows: HomeRow[] = [];
    keys.forEach((key: string) => {
      const list = groups.get(key) as ThreadShell[];
      const open = list.filter((t: ThreadShell) => rank(t) < 4);
      // A project whose conversations are all settled stays out of the way: it shows with
      // "show settled" on, or in a search.
      const quiet = open.length === 0;
      if (quiet && !searching && !includeSettledProjects && !this.showSettled) {
        return;
      }
      const all = searching || this.showSettled || quiet ? list : open;
      const project = this.projectForGroup(projectsOf.get(key) as ProjectShell[]);
      const header = new HomeRow(`p:${key}`, 'header');
      header.title = project?.title ?? '其它对话';
      header.count = all.length;
      header.section = `project:${project?.id ?? key}`;
      header.project = project;
      header.groupKey = key;
      header.attention = list.filter((t: ThreadShell) => needsAttention(t)).length;
      header.state = mostPressingState(list);
      header.collapsed = !searching && this.collapsedProjects.indexOf(key) >= 0;
      rows.push(header);
      if (header.collapsed) {
        return;
      }
      // A few per project, like the desktop sidebar; the rest one tap away.
      const shown = searching || expanded.indexOf(key) >= 0 ? all : all.slice(0, PROJECT_ROW_LIMIT);
      shown.forEach((t: ThreadShell, index: number) => {
        const row = new HomeRow(`t:${t.environmentId ?? ''}:${t.id}`, 'thread');
        row.thread = t;
        row.project = this.projectFor(t.projectId, t.environmentId ?? '');
        row.section = rank(t) === 4 ? 'settled' : header.section;
        row.groupKey = key;
        row.lastInSection = index === shown.length - 1;
        rows.push(row);
      });
      if (shown.length < all.length) {
        const more = new HomeRow(`m:${key}`, 'more');
        more.count = all.length - shown.length;
        more.section = header.section;
        more.groupKey = key;
        rows.push(more);
      }
    });
    if (rows.length === 0) {
      rows.push(new HomeRow('empty', 'empty'));
    }
    return rows;
  }

  /**
   * Projects to start a conversation in, most recently used first; a name on several computers is one
   * choice (the conversation page then asks which computer).
   */
  newChatProjects(): ProjectChoice[] {
    const byKey: Map<string, ProjectChoice> = new Map();
    this.projects.forEach((p: ProjectShell) => {
      if (p.archivedAt) {
        return;
      }
      const key = `name:${projectNameKey(p.title)}`;
      let choice = byKey.get(key);
      if (choice === undefined) {
        choice = new ProjectChoice();
        choice.key = key;
        byKey.set(key, choice);
      }
      choice.projects.push(p);
    });
    const latestOf: Map<string, number> = new Map();
    this.threads.forEach((t: ThreadShell) => {
      const id = `${t.environmentId ?? ''}|${t.projectId ?? ''}`;
      latestOf.set(id, Math.max(latestOf.get(id) ?? 0, activityTime(t)));
    });
    const choices: ProjectChoice[] = [];
    byKey.forEach((choice: ProjectChoice) => {
      choice.project = this.projectForGroup(choice.projects);
      choice.title = choice.project?.title ?? '';
      choice.latest = choice.projects.reduce((max: number, p: ProjectShell) =>
        Math.max(max, latestOf.get(`${p.environmentId ?? ''}|${p.id}`) ?? 0, parseTime(p.updatedAt)), 0);
      choices.push(choice);
    });
    return choices.sort((a: ProjectChoice, b: ProjectChoice) => b.latest - a.latest || a.title.localeCompare(b.title));
  }

  /**
   * The project that speaks for a merged group: one with an icon chosen on the desktop, else one with a
   * favicon, else the first computer's. Stable, so the header never swaps icons as threads move.
   */
  projectForGroup(projects: ProjectShell[]): ProjectShell | null {
    if (projects.length === 0) {
      return null;
    }
    const order = (p: ProjectShell): number => {
      const env = this.environments.findIndex((e: EnvironmentState) => e.id === p.environmentId);
      const icon = (p.projectIcon ?? null) !== null ? 0 : (p.faviconPath ?? '').length > 0 ? 1 : 2;
      return icon * 1000 + (env < 0 ? 999 : env);
    };
    return projects.slice().sort((a: ProjectShell, b: ProjectShell) => order(a) - order(b))[0];
  }
}

function tagThread(thread: ThreadShell, environmentId: string): ThreadShell {
  thread.environmentId = environmentId;
  return thread;
}

function tagProject(project: ProjectShell, environmentId: string): ProjectShell {
  project.environmentId = environmentId;
  return project;
}

export function activityTime(thread: ThreadShell): number {
  return Math.max(
    parseTime(thread.latestVisibleMessage?.updatedAt),
    parseTime(thread.latestUserMessageAt),
    parseTime(thread.updatedAt),
  );
}

export const appState: AppState = new AppState();
