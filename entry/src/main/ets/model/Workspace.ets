/**
 * Wire types and pure helpers for the workspace surfaces that mirror the iOS app: git controls,
 * the file browser, terminals, usage and pull requests. Field names follow @t3tools/contracts.
 */

// ---- Git / VCS ---------------------------------------------------------------------------------

export interface GitWorkingFile {
  path: string;
  insertions: number;
  deletions: number;
}

export interface GitWorkingTree {
  files: GitWorkingFile[];
  insertions: number;
  deletions: number;
}

export interface SourceControlProviderInfo {
  kind?: string;
  name?: string;
}

export interface GitChangeRequest {
  number: number;
  title?: string;
  url: string;
  state: string;
  isDraft?: boolean;
}

export interface VcsStatusLocal {
  isRepo: boolean;
  sourceControlProvider?: SourceControlProviderInfo;
  hasPrimaryRemote: boolean;
  isDefaultRef: boolean;
  refName: string | null;
  hasWorkingTreeChanges: boolean;
  workingTree: GitWorkingTree;
}

export interface VcsStatusRemote {
  hasUpstream: boolean;
  aheadCount: number;
  behindCount: number;
  pr: GitChangeRequest | null;
}

export interface VcsStatusEvent {
  _tag: string;
  local?: VcsStatusLocal;
  remote?: VcsStatusRemote | null;
}

export interface VcsStatusInput {
  cwd: string;
  includeRemote?: boolean;
}

export interface VcsRef {
  name: string;
  isRemote?: boolean;
  current: boolean;
  isDefault: boolean;
  worktreePath: string | null;
}

export interface VcsListRefsResult {
  refs: VcsRef[];
  isRepo: boolean;
  totalCount: number;
}

export interface VcsListRefsInput {
  cwd: string;
  refKind: string;
  limit: number;
  query?: string;
}

export interface VcsSwitchRefInput {
  cwd: string;
  refName: string;
}

export interface VcsPullResult {
  status: string;
  refName: string;
}

export interface GitRunStackedActionInput {
  actionId: string;
  cwd: string;
  action: string;
  commitMessage?: string;
  featureBranch?: boolean;
  threadId?: string;
  projectId?: string;
}

export interface GitActionProgressEvent {
  kind: string;
  label?: string;
  message?: string;
  phase?: string | null;
  output?: string;
}

export interface ReviewDiffFileStat {
  path: string;
  previousPath: string | null;
  changeType?: string;
  additions: number;
  deletions: number;
}

export interface ReviewDiffSource {
  id: string;
  kind: string;
  title: string;
  diff: string;
  truncated: boolean;
  files?: ReviewDiffFileStat[];
}

export interface ReviewDiffPreviewInput {
  cwd: string;
  sourceKind: string;
}

export interface ReviewDiffPreviewResult {
  sources: ReviewDiffSource[];
}

/** Combined local + remote status, like VcsStatusResult. */
export class GitStatus {
  isRepo: boolean = true;
  providerKind: string = '';
  hasPrimaryRemote: boolean = false;
  isDefaultRef: boolean = false;
  refName: string | null = null;
  hasWorkingTreeChanges: boolean = false;
  files: GitWorkingFile[] = [];
  insertions: number = 0;
  deletions: number = 0;
  hasUpstream: boolean = false;
  aheadCount: number = 0;
  behindCount: number = 0;
  pr: GitChangeRequest | null = null;
  remoteKnown: boolean = false;

  applyLocal(local: VcsStatusLocal): void {
    this.isRepo = local.isRepo;
    this.providerKind = local.sourceControlProvider?.kind ?? '';
    this.hasPrimaryRemote = local.hasPrimaryRemote;
    this.isDefaultRef = local.isDefaultRef;
    this.refName = local.refName;
    this.hasWorkingTreeChanges = local.hasWorkingTreeChanges;
    this.files = local.workingTree?.files ?? [];
    this.insertions = local.workingTree?.insertions ?? 0;
    this.deletions = local.workingTree?.deletions ?? 0;
  }

  applyRemote(remote: VcsStatusRemote | null): void {
    this.remoteKnown = true;
    this.hasUpstream = remote?.hasUpstream ?? false;
    this.aheadCount = remote?.aheadCount ?? 0;
    this.behindCount = remote?.behindCount ?? 0;
    this.pr = remote?.pr ?? null;
  }

  copy(): GitStatus {
    const next = new GitStatus();
    next.isRepo = this.isRepo;
    next.providerKind = this.providerKind;
    next.hasPrimaryRemote = this.hasPrimaryRemote;
    next.isDefaultRef = this.isDefaultRef;
    next.refName = this.refName;
    next.hasWorkingTreeChanges = this.hasWorkingTreeChanges;
    next.files = this.files;
    next.insertions = this.insertions;
    next.deletions = this.deletions;
    next.hasUpstream = this.hasUpstream;
    next.aheadCount = this.aheadCount;
    next.behindCount = this.behindCount;
    next.pr = this.pr;
    next.remoteKnown = this.remoteKnown;
    return next;
  }
}

/** "PR" on GitHub-like hosts, "MR" on GitLab. */
export function changeRequestLabel(status: GitStatus | null): string {
  return (status?.providerKind ?? '') === 'gitlab' ? 'MR' : 'PR';
}

export class GitQuickAction {
  label: string = '';
  disabled: boolean = true;
  /** 'run_action' | 'run_pull' | 'open_pr' | 'show_hint' */
  kind: string = 'show_hint';
  action: string = '';
  hint: string = '';

  static of(label: string, disabled: boolean, kind: string, action: string, hint: string): GitQuickAction {
    const value = new GitQuickAction();
    value.label = label;
    value.disabled = disabled;
    value.kind = kind;
    value.action = action;
    value.hint = hint;
    return value;
  }
}

/** The one-tap git action for the current state; same decision table as the iOS app. */
export function resolveQuickAction(status: GitStatus | null, busy: boolean): GitQuickAction {
  if (busy) {
    return GitQuickAction.of('提交', true, 'show_hint', '', 'Git 操作进行中。');
  }
  if (status === null) {
    return GitQuickAction.of('提交', true, 'show_hint', '', '还没有拿到 Git 状态。');
  }
  if (!status.isRepo) {
    return GitQuickAction.of('Git 不可用', true, 'show_hint', '', '这个工作区不是 Git 仓库。');
  }
  const pr = changeRequestLabel(status);
  const hasBranch = status.refName !== null;
  const hasOpenPr = status.pr?.state === 'open';
  const ahead = status.aheadCount > 0;
  const behind = status.behindCount > 0;
  if (!hasBranch) {
    return GitQuickAction.of('提交', true, 'show_hint', '', `先创建并切换到一个分支，再推送或创建 ${pr}。`);
  }
  if (status.hasWorkingTreeChanges) {
    if (behind || (!status.hasUpstream && !status.hasPrimaryRemote)) {
      return GitQuickAction.of('提交', false, 'run_action', 'commit', '');
    }
    if (hasOpenPr || status.isDefaultRef) {
      return GitQuickAction.of('提交并推送', false, 'run_action', 'commit_push', '');
    }
    return GitQuickAction.of(`提交、推送并创建 ${pr}`, false, 'run_action', 'commit_push_pr', '');
  }
  if (!status.hasUpstream) {
    if (!status.hasPrimaryRemote) {
      if (hasOpenPr && !ahead) {
        return GitQuickAction.of(`查看 ${pr}`, false, 'open_pr', '', '');
      }
      return GitQuickAction.of('推送', true, 'show_hint', '', `先添加 origin 远程仓库，再推送或创建 ${pr}。`);
    }
    if (!ahead) {
      if (hasOpenPr) {
        return GitQuickAction.of(`查看 ${pr}`, false, 'open_pr', '', '');
      }
      return GitQuickAction.of('推送', true, 'show_hint', '', '没有需要推送的本地提交。');
    }
    if (hasOpenPr || status.isDefaultRef) {
      return GitQuickAction.of('推送', false, 'run_action', status.isDefaultRef ? 'commit_push' : 'push', '');
    }
    return GitQuickAction.of(`推送并创建 ${pr}`, false, 'run_action', 'create_pr', '');
  }
  if (ahead && behind) {
    return GitQuickAction.of('同步分支', true, 'show_hint', '', '分支与上游已经分叉，请先变基或合并。');
  }
  if (behind) {
    return GitQuickAction.of('拉取', false, 'run_pull', '', '');
  }
  if (ahead) {
    if (hasOpenPr || status.isDefaultRef) {
      return GitQuickAction.of('推送', false, 'run_action', status.isDefaultRef ? 'commit_push' : 'push', '');
    }
    return GitQuickAction.of(`推送并创建 ${pr}`, false, 'run_action', 'create_pr', '');
  }
  if (hasOpenPr && status.hasUpstream) {
    return GitQuickAction.of(`查看 ${pr}`, false, 'open_pr', '', '');
  }
  return GitQuickAction.of('提交', true, 'show_hint', '', '分支已是最新，无需操作。');
}

/** Pushing straight to the default branch asks first, as on iOS. */
export function needsDefaultBranchConfirmation(action: string, isDefaultRef: boolean): boolean {
  return isDefaultRef && (action === 'push' || action === 'create_pr' || action === 'commit_push' || action === 'commit_push_pr');
}

/** "main · 3 处改动 · 领先 1" for the branch row of the git menu. */
export function gitStatusSummary(status: GitStatus | null): string {
  if (status === null) {
    return '正在检查状态';
  }
  if (!status.isRepo) {
    return '不是 Git 仓库';
  }
  const parts: string[] = [];
  if (status.hasWorkingTreeChanges) {
    parts.push(`${status.files.length} 处改动`);
  } else if (status.aheadCount === 0 && status.behindCount === 0) {
    parts.push('无改动');
  }
  if (status.aheadCount > 0) {
    parts.push(`领先 ${status.aheadCount}`);
  }
  if (status.behindCount > 0) {
    parts.push(`落后 ${status.behindCount}`);
  }
  if (status.pr?.state === 'open') {
    parts.push(`${changeRequestLabel(status)} #${status.pr.number}`);
  }
  return parts.join(' · ');
}

export function truncateMiddle(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  const head = Math.ceil((maxLength - 1) / 2);
  const tail = Math.floor((maxLength - 1) / 2);
  return `${value.substring(0, head)}…${value.substring(value.length - tail)}`;
}

// ---- Diffs -------------------------------------------------------------------------------------

export class DiffLine {
  /** 'add' | 'del' | 'ctx' | 'hunk' | 'meta' */
  kind: string = 'ctx';
  text: string = '';
  oldNo: number = 0;
  newNo: number = 0;
}

export class DiffFile {
  path: string = '';
  previousPath: string = '';
  additions: number = 0;
  deletions: number = 0;
  lines: DiffLine[] = [];
}

/** Splits a unified diff into files with numbered lines. */
export function parseUnifiedDiff(diff: string): DiffFile[] {
  const files: DiffFile[] = [];
  let current: DiffFile | null = null;
  let oldNo = 0;
  let newNo = 0;
  const lines = diff.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('diff --git ')) {
      current = new DiffFile();
      const match = /^diff --git a\/(.+) b\/(.+)$/.exec(line);
      if (match !== null) {
        current.previousPath = match[1];
        current.path = match[2];
      }
      files.push(current);
      continue;
    }
    if (current === null) {
      continue;
    }
    if (line.startsWith('+++ ') || line.startsWith('--- ') || line.startsWith('index ') ||
      line.startsWith('new file') || line.startsWith('deleted file') || line.startsWith('similarity') ||
      line.startsWith('rename ') || line.startsWith('old mode') || line.startsWith('new mode')) {
      if (line.startsWith('+++ b/')) {
        current.path = line.substring(6);
      }
      continue;
    }
    const entry = new DiffLine();
    if (line.startsWith('@@')) {
      const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/.exec(line);
      if (hunk !== null) {
        oldNo = Number(hunk[1]);
        newNo = Number(hunk[2]);
      }
      entry.kind = 'hunk';
      entry.text = line;
    } else if (line.startsWith('+')) {
      entry.kind = 'add';
      entry.text = line.substring(1);
      entry.newNo = newNo++;
      current.additions++;
    } else if (line.startsWith('-')) {
      entry.kind = 'del';
      entry.text = line.substring(1);
      entry.oldNo = oldNo++;
      current.deletions++;
    } else if (line.startsWith('\\')) {
      entry.kind = 'meta';
      entry.text = line;
    } else {
      if (line.length === 0 && i === lines.length - 1) {
        continue;
      }
      entry.kind = 'ctx';
      entry.text = line.startsWith(' ') ? line.substring(1) : line;
      entry.oldNo = oldNo++;
      entry.newNo = newNo++;
    }
    current.lines.push(entry);
  }
  return files;
}

// ---- Files -------------------------------------------------------------------------------------

export interface ProjectEntry {
  path: string;
  kind: string;
  ignored?: boolean;
}

export interface ProjectListEntriesInput {
  cwd: string;
  directoryPath?: string;
}

export interface ProjectListEntriesResult {
  entries: ProjectEntry[];
  truncated: boolean;
}

export interface ProjectReadFileInput {
  cwd: string;
  relativePath: string;
}

export interface ProjectReadFileResult {
  relativePath: string;
  contents: string;
  byteLength: number;
  truncated: boolean;
}

export function baseName(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, '');
  const index = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'));
  return index >= 0 ? trimmed.substring(index + 1) : trimmed;
}

export function fileExtension(path: string): string {
  const name = baseName(path);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// ---- Terminal ----------------------------------------------------------------------------------

export interface TerminalSummary {
  threadId: string;
  terminalId: string;
  cwd: string;
  status: string;
  hasRunningSubprocess: boolean;
  label: string;
  updatedAt: string;
}

export interface TerminalMetadataEvent {
  type: string;
  terminals?: TerminalSummary[];
  terminal?: TerminalSummary;
  threadId?: string;
  terminalId?: string;
}

export interface TerminalSnapshot {
  threadId: string;
  terminalId: string;
  cwd: string;
  status: string;
  history: string;
  exitCode: number | null;
  label: string;
  cols?: number;
  rows?: number;
  error?: string;
}

export interface TerminalAttachEvent {
  type: string;
  snapshot?: TerminalSnapshot;
  data?: string;
  exitCode?: number | null;
  message?: string;
  hasRunningSubprocess?: boolean;
  label?: string;
}

export interface TerminalAttachInput {
  threadId: string;
  terminalId: string;
  cwd: string;
  worktreePath?: string | null;
  cols: number;
  rows: number;
  maxHistoryBytes: number;
  resume?: boolean;
}

export interface TerminalWriteInput {
  threadId: string;
  terminalId: string;
  data: string;
}

export interface TerminalResizeInput {
  threadId: string;
  terminalId: string;
  cols: number;
  rows: number;
}

export interface TerminalCloseInput {
  threadId: string;
  terminalId: string;
}

export interface EmptyInput {
}

export function terminalStatusLabel(summary: TerminalSummary): string {
  if (summary.status === 'running' || summary.status === 'starting') {
    return summary.hasRunningSubprocess ? '运行中' : '空闲';
  }
  if (summary.status === 'exited') {
    return '已退出';
  }
  if (summary.status === 'error') {
    return '出错';
  }
  return summary.status;
}

// ---- Usage -------------------------------------------------------------------------------------

export interface UsageWindow {
  id: string;
  kind: string;
  label: string;
  usedPercent: number;
  resetsAt?: string;
  windowDurationMins?: number;
}

export interface UsageLimitsUnavailable {
  reason: string;
  message?: string;
}

export interface ProviderUsageLimits {
  checkedAt: string;
  windows: UsageWindow[];
  unavailable?: UsageLimitsUnavailable;
  zeroSpendCap?: boolean;
}

export interface UsageTokenTotals {
  uncachedInputTokens: number;
  cachedInputTokens: number;
  cacheCreationTokens: number;
  outputTokens: number;
  reasoningTokens: number;
}

export interface UsageBucket {
  day: string;
  hourStart?: string;
  provider: string;
  model: string;
  totals: UsageTokenTotals;
  costUsd: number;
  sessions: number;
}

export interface UsageSummary {
  contractVersion: number;
  buckets: UsageBucket[];
}

export interface UsageSummaryInput {
  sinceDay: string;
  untilDay: string;
  timeZone: string;
  resolution: string;
  sinceTime?: string;
  untilTime?: string;
}

export function bucketTokens(bucket: UsageBucket): number {
  const t = bucket.totals;
  if (t === undefined || t === null) {
    return 0;
  }
  return (t.uncachedInputTokens ?? 0) + (t.cachedInputTokens ?? 0) + (t.cacheCreationTokens ?? 0) + (t.outputTokens ?? 0);
}

export function remainingPercent(window: UsageWindow): number {
  return Math.round(100 - Math.max(0, Math.min(100, window.usedPercent)));
}

/** Share of the window's time still left, for the pace tick on the bar. */
export function paceRemainingPercent(window: UsageWindow, now: number): number | null {
  if (window.resetsAt === undefined || window.windowDurationMins === undefined || window.windowDurationMins <= 0) {
    return null;
  }
  const resetsAt = Date.parse(window.resetsAt);
  if (!Number.isFinite(resetsAt)) {
    return null;
  }
  const length = window.windowDurationMins * 60000;
  const elapsed = Math.max(0, Math.min(1, (length - (resetsAt - now)) / length));
  return Math.round((1 - elapsed) * 100);
}

export function paceLabel(window: UsageWindow, now: number): string {
  const left = paceRemainingPercent(window, now);
  if (left === null) {
    return '';
  }
  const gap = window.usedPercent - (100 - left);
  if (gap > 5) {
    return '超出进度';
  }
  if (gap < -5) {
    return '低于进度';
  }
  return '符合进度';
}

export function formatDurationShort(ms: number): string {
  const remaining = Math.max(0, ms);
  const days = Math.floor(remaining / 86400000);
  const hours = Math.floor((remaining % 86400000) / 3600000);
  const minutes = Math.floor((remaining % 3600000) / 60000);
  if (days > 0) {
    return `${days} 天 ${hours} 小时`;
  }
  if (hours > 0) {
    return `${hours} 小时 ${minutes} 分`;
  }
  return `${minutes} 分钟`;
}

export function resetsInLabel(window: UsageWindow, now: number): string {
  if (window.resetsAt === undefined) {
    return '';
  }
  const at = Date.parse(window.resetsAt);
  if (!Number.isFinite(at)) {
    return '';
  }
  if (at <= now) {
    return '即将重置';
  }
  return `${formatDurationShort(at - now)}后重置`;
}

export function formatUsd(value: number): string {
  if (value >= 1000) {
    return `$${(value / 1000).toFixed(1)}k`;
  }
  if (value >= 100) {
    return `$${value.toFixed(0)}`;
  }
  return `$${value.toFixed(2)}`;
}

export function formatTokens(value: number): string {
  if (value >= 1e9) {
    return `${(value / 1e9).toFixed(1)}B`;
  }
  if (value >= 1e6) {
    return `${(value / 1e6).toFixed(1)}M`;
  }
  if (value >= 1e3) {
    return `${(value / 1e3).toFixed(1)}K`;
  }
  return `${Math.round(value)}`;
}

export function usageProviderLabel(provider: string): string {
  switch (provider) {
    case 'claude':
    case 'claudeAgent':
      return 'Claude';
    case 'codex':
      return 'Codex';
    case 'grok':
      return 'Grok';
    case 'cursor':
      return 'Cursor';
    case 'opencode':
      return 'OpenCode';
    case 'antigravity':
      return 'Antigravity';
    case 'pi':
      return 'Pi';
    case 'muse':
      return 'Muse';
    default:
      return provider;
  }
}

/** Calendar day in local time, as the server's UsageDay. */
export function localDay(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// ---- Pull requests -----------------------------------------------------------------------------

export interface PullRequestActor {
  login: string;
  name: string | null;
  avatarUrl: string | null;
  isBot?: boolean;
}

export interface PullRequestLabel {
  name: string;
  color: string | null;
}

export interface PullRequestEntry {
  provider: string;
  host: string;
  projectId: string;
  projectTitle: string;
  repository: string;
  number: number;
  title: string;
  url: string;
  author: PullRequestActor | null;
  headBranch: string;
  baseBranch: string;
  state: string;
  isDraft: boolean;
  mergeability: string;
  additions: number;
  deletions: number;
  createdAt: string;
  updatedAt: string;
  viewerReviewRequested: boolean;
  labels: PullRequestLabel[];
  reviewDecision?: string;
  checksState?: string;
  /** Client-side: the computer the listing came from. */
  environmentId?: string;
}

export interface PullRequestListError {
  projectId: string;
  projectTitle: string;
  message: string;
}

export interface PullRequestProviderSummary {
  host: string;
  kind: string;
  configured: boolean;
  detail: string | null;
}

export interface PullRequestListResult {
  entries: PullRequestEntry[];
  errors: PullRequestListError[];
  providers: PullRequestProviderSummary[];
  truncated: boolean;
}

export interface PullRequestListInput {
  state: string;
  involvement: string;
  limit: number;
  query?: string;
}

export interface PullRequestRef {
  projectId: string;
  host?: string;
  repository: string;
  number: number;
}

export interface PullRequestCheck {
  name: string;
  status: string;
  description: string | null;
  url: string | null;
  required?: boolean;
}

export interface PullRequestMergeCapabilities {
  merge: boolean;
  squash: boolean;
  rebase: boolean;
}

export interface PullRequestDetail {
  provider: string;
  projectId: string;
  projectTitle: string;
  repository: string;
  number: number;
  title: string;
  body: string;
  url: string;
  author: PullRequestActor | null;
  state: string;
  isDraft: boolean;
  mergeability: string;
  additions: number;
  deletions: number;
  changedFiles: number;
  headBranch: string;
  baseBranch: string;
  createdAt: string;
  updatedAt: string;
  mergedAt: string | null;
  closedAt: string | null;
  reviewers: PullRequestActor[];
  labels: PullRequestLabel[];
  checks: PullRequestCheck[];
  reviewDecision?: string | null;
  behindBy?: number;
  mergeCapabilities?: PullRequestMergeCapabilities;
}

/** PullRequestRef fields plus the action, flat as in the contract. */
export interface PullRequestActionInput {
  projectId: string;
  host?: string;
  repository: string;
  number: number;
  action: string;
  mergeMethod?: string;
}

export function prStateLabel(state: string, isDraft: boolean): string {
  if (isDraft && state === 'open') {
    return '草稿';
  }
  switch (state) {
    case 'open':
      return '打开';
    case 'merged':
      return '已合并';
    case 'closed':
      return '已关闭';
    default:
      return state;
  }
}

export function checksLabel(state: string | undefined): string {
  switch (state) {
    case 'passing':
      return '检查通过';
    case 'failing':
      return '检查失败';
    case 'pending':
      return '检查中';
    default:
      return '';
  }
}

export function reviewLabel(decision: string | undefined | null): string {
  switch (decision) {
    case 'approved':
      return '已批准';
    case 'changes-requested':
      return '需修改';
    case 'review-required':
      return '待审查';
    default:
      return '';
  }
}

export function checkStatusLabel(status: string): string {
  switch (status) {
    case 'success':
      return '通过';
    case 'failure':
      return '失败';
    case 'pending':
      return '进行中';
    case 'action-required':
      return '需要操作';
    case 'skipped':
      return '已跳过';
    case 'cancelled':
      return '已取消';
    default:
      return '中性';
  }
}

/** "owner/repo" → "repo". */
export function repoName(repository: string): string {
  const index = repository.lastIndexOf('/');
  return index >= 0 ? repository.substring(index + 1) : repository;
}
