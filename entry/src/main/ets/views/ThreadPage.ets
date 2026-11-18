import { HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { notifier } from '../services/Notifier';
import { defaultModel, findModel, RunSettings, RunSettingsPanel, runSummary } from '../components/RunSettings';
import { immersiveMaterial, systemMaterialOn } from '../common/Material';
import { ButtonMaterial, MaterialStyle } from '../common/Material';
import { FADE, REVEAL, RISE, SWAP } from '../common/Motion';
import { activityTime, appState, AppState, EnvironmentState, finishedAt, isWorking, needsAttention, projectNameKey } from '../model/AppState';
import { FeedEntry, ThreadDetailState } from '../model/ThreadDetail';
import { ChatAttachment, ModelOption, ProjectScript, ProjectShell, ThreadShell } from '../model/Types';
import { detailNav, openWorkspacePage, ThreadRouteParam, WorkspaceRouteParam } from '../common/Nav';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { ThreadWorkspace, workspaces } from '../services/Workspace';
import { modelLabel, parseTime, providerLabel, shortPath, durationLabel } from '../common/Format';
import { ProjectBadge, threadStatusLabel } from '../components/Common';
import { compactTitleBar, imageItem, symbolItem } from '../components/TitleBars';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { confirmDialog, promptDialog } from '../components/Dialogs';
import {
  baseName,
  changeRequestLabel,
  gitStatusSummary,
  needsDefaultBranchConfirmation,
  resolveQuickAction,
  terminalStatusLabel,
  TerminalSummary,
  truncateMiddle,
} from '../model/Workspace';
import { ApprovalCard, AssistantMessage, NoticeRow, QuestionCard, UserBubble, WorkGroup } from './FeedCards';
import { Composer } from './Composer';
import { Type } from '../common/Typography';
import { common } from '@kit.AbilityKit';

/** Like iOS projectScriptMenuLabel: the name, plus its automatic roles. */
function scriptLabel(script: ProjectScript): string {
  const roles: string[] = [];
  if (script.runOnWorktreeCreate) {
    roles.push('初始化');
  }
  if (script.runOnSettle) {
    roles.push('完成时');
  }
  return roles.length === 0 ? script.name : `${script.name}（${roles.join('、')}）`;
}

function quickActionSymbol(kind: string, action: string): Resource {
  if (kind === 'run_pull') {
    return $r('sys.symbol.arrow_down_circle');
  }
  if (kind === 'run_action' && action === 'commit') {
    return $r('sys.symbol.checkmark_circle');
  }
  if (kind === 'run_action' && (action === 'push' || action === 'commit_push')) {
    return $r('sys.symbol.arrow_up_circle');
  }
  return $r('sys.symbol.arrow_up_circle');
}

@ComponentV2
export struct ThreadPage {
  @Local app: AppState = appState;
  @Local detail: ThreadDetailState | null = null;
  @Local busy: boolean = false;
  @Local atBottom: boolean = true;
  /** True when shown as the right-hand pane of the two-column layout. */
  @Local inDetailPane: boolean = false;
  /** Model / reasoning / permission sheet. */
  @Local runSheetShown: boolean = false;
  @Local run: RunSettings = new RunSettings();
  /** Git status and terminals of this conversation's folder (title-bar menus). */
  @Local workspace: ThreadWorkspace | null = null;
  /**
   * A new conversation not started yet (like the desktop's draft thread): the project group it starts
   * in, the project (and so the computer) chosen in it, and the run settings for the first message.
   */
  @Local draftKey: string = '';
  @Local draftProjectId: string = '';
  @Local draftEnvId: string = '';
  @Local draftRun: RunSettings = new RunSettings();
  /** The first message, shown at once while the conversation it started loads. */
  @Local pendingText: string = '';
  @Local pendingFiles: ChatAttachment[] = [];
  /** Puts text back into the composer (a launch that failed). */
  @Local refillText: string = '';
  @Local refillSeq: number = 0;
  private stack: NavPathStack | null = null;
  private routeParam: ThreadRouteParam | null = null;
  private seenTimer: number = -1;
  private threadId: string = '';
  private scroller: ListScroller = new ListScroller();
  private didInitialScroll: boolean = false;
  /** Follow new output until the reader drags upward; survives the list shrinking for the keyboard. */
  private stickToBottom: boolean = true;
  /** Messages and cards already on screen (by item, not by revision), so only new ones rise in. */
  private shownEntries: Set<string> = new Set();
  private feedSettled: boolean = false;

  @Computed
  get shell(): ThreadShell | null {
    return this.app.threadFor(this.detail?.threadId ?? '');
  }

  /** The computer this conversation runs on; its connection drives the banner and composer. */
  @Computed
  get environment(): EnvironmentState | null {
    if (this.draftKey.length > 0) {
      return this.app.environmentFor(this.draftEnvId);
    }
    return this.app.environmentOfThread(this.detail?.threadId ?? '');
  }

  @Computed
  get isDraft(): boolean {
    return this.draftKey.length > 0;
  }

  /** The draft's project on each computer that has one by this name, in the computers' order. */
  @Computed
  get draftProjects(): ProjectShell[] {
    return this.projectsForKey(this.draftKey);
  }

  private projectsForKey(key: string): ProjectShell[] {
    if (key.length === 0) {
      return [];
    }
    const order = (p: ProjectShell): number => this.app.environments.findIndex((e: EnvironmentState) => e.id === p.environmentId);
    return this.app.projects
      .filter((p: ProjectShell) => !p.archivedAt && `name:${projectNameKey(p.title)}` === key)
      .sort((a: ProjectShell, b: ProjectShell) => order(a) - order(b));
  }

  @Computed
  get draftProject(): ProjectShell | null {
    return this.draftProjectId.length > 0 ? this.app.projectFor(this.draftProjectId, this.draftEnvId) : null;
  }

  @Computed
  get running(): boolean {
    const shell = this.shell;
    if (shell !== null) {
      return isWorking(shell);
    }
    return this.detail?.activeRun !== null && this.detail?.activeRun !== undefined;
  }

  /**
   * Reports the conversation as read up to what is on screen, so a finished run you watched (or read
   * here) is not "unread" anywhere. Debounced while output streams; immediate when leaving.
   */
  private markSeen(now: boolean = false): void {
    if (this.seenTimer >= 0) {
      clearTimeout(this.seenTimer);
      this.seenTimer = -1;
    }
    const send = (): void => {
      this.seenTimer = -1;
      if (this.threadId.length === 0 || !notifier.isForeground) {
        return;
      }
      const shell = this.app.threadFor(this.threadId);
      connection.visitThread(this.threadId, shell !== null ? finishedAt(shell) + 1 : 0);
    };
    if (now) {
      send();
    } else {
      this.seenTimer = setTimeout(send, 1500);
    }
  }

  /** A run that ends while the conversation is on screen has been seen too. */
  @Monitor('app.threads')
  onThreadsChanged(): void {
    if (this.threadId.length === 0) {
      return;
    }
    const shell = this.app.threadFor(this.threadId);
    if (shell !== null && finishedAt(shell) > parseTime(shell.lastVisitedAt)) {
      this.markSeen();
    }
  }

  @Monitor('detail.version')
  onFeedChanged(): void {
    this.markSeen();
    if (!this.didInitialScroll || this.atBottom || this.stickToBottom) {
      this.didInitialScroll = true;
      this.scrollToLatest();
    }
  }

  private scrollToLatest(): void {
    this.stickToBottom = true;
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 30);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
  }

  // ---- Draft: a new conversation that starts with the first message --------------------------------

  /** Opens the draft on the computer where its project was used most recently (a connected one first). */
  private startDraft(key: string): void {
    this.draftKey = key;
    const latest = (p: ProjectShell): number => this.app.threads
      .filter((t: ThreadShell) => t.projectId === p.id && t.environmentId === p.environmentId)
      .reduce((max: number, t: ThreadShell) => Math.max(max, activityTime(t)), 0);
    let bestIndex = -1;
    let bestScore = -1;
    // Read straight from the app state: the computed list may not have caught up with draftKey yet.
    const projects = this.projectsForKey(key);
    projects.forEach((p: ProjectShell, index: number) => {
      const connected = this.app.environmentFor(p.environmentId)?.phase === 'connected' ? 1 : 0;
      const score = connected * 1e15 + latest(p);
      if (score > bestScore) {
        bestScore = score;
        bestIndex = index;
      }
    });
    if (bestIndex >= 0) {
      this.pickDraftProject(projects[bestIndex]);
    }
  }

  /** The newest conversation on a computer: its model, options and permission are the default. */
  private recentThread(environmentId: string): ThreadShell | null {
    const recent = this.app.threads
      .filter((t: ThreadShell) => (t.environmentId ?? '') === environmentId && (t.modelSelection?.model ?? '').length > 0)
      .sort((a: ThreadShell, b: ThreadShell) => activityTime(b) - activityTime(a));
    return recent.length > 0 ? recent[0] : null;
  }

  /** Choosing the project on another computer brings that computer's models; keep the run valid. */
  private pickDraftProject(project: ProjectShell): void {
    const environmentId = project.environmentId ?? '';
    const changedComputer = environmentId !== this.draftEnvId || this.draftRun.model.length === 0;
    this.draftProjectId = project.id;
    this.draftEnvId = environmentId;
    if (!changedComputer) {
      return;
    }
    const run = new RunSettings();
    run.environmentId = environmentId;
    const recent = this.recentThread(environmentId);
    const selection = recent?.modelSelection;
    if (selection !== undefined && selection.model.length > 0 &&
      (findModel(environmentId, selection.instanceId, selection.model) !== null ||
        (this.app.environmentFor(environmentId)?.config?.providers ?? []).length === 0)) {
      run.instanceId = selection.instanceId;
      run.model = selection.model;
      run.options = (selection.options ?? []).map((o: ModelOption) => {
        const copy: ModelOption = { id: o.id, value: o.value };
        return copy;
      });
    } else {
      const fallback = defaultModel(environmentId);
      if (fallback !== null) {
        run.instanceId = fallback.instanceId;
        run.model = fallback.slug;
      }
    }
    run.runtimeMode = recent?.runtimeMode ?? 'full-access';
    run.interactionMode = this.draftRun.interactionMode;
    this.draftRun = run;
  }

  /** The first message starts the conversation, and this page becomes it: no new page, no reload. */
  private async launch(text: string, files: ChatAttachment[]): Promise<void> {
    const project = this.draftProject;
    if (project === null || this.draftRun.model.length === 0) {
      this.toast(project === null ? '先选一个项目' : '先选一个模型');
      this.refill(text);
      return;
    }
    this.busy = true;
    this.pendingText = text;
    this.pendingFiles = files;
    try {
      const threadId = await connection.launchThread(project.id, this.draftEnvId, text, this.draftRun.selection(),
        this.draftRun.runtimeMode, this.draftRun.interactionMode, files);
      lightEffects.tap();
      // Moving between one and two columns re-creates the page from its route: make it the thread now.
      if (this.routeParam !== null) {
        this.routeParam.threadId = threadId;
        this.routeParam.draftKey = '';
      }
      this.draftKey = '';
      this.attachThread(threadId);
      if (this.inDetailPane) {
        this.app.selectedThreadId = threadId;
      }
    } catch (e) {
      this.pendingText = '';
      this.pendingFiles = [];
      this.refill(text);
      this.toast(`没能开始对话：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  private refill(text: string): void {
    this.refillText = text;
    this.refillSeq++;
  }

  private attachThread(threadId: string): void {
    this.threadId = threadId;
    this.detail = connection.openThread(threadId);
    connection.visitThread(threadId);
    this.workspace = workspaces.acquire(threadId);
    notifier.visibleThreadId = threadId;
    if (!this.detail.loading) {
      this.onFeedChanged();
    }
  }

  private async send(text: string, files: ChatAttachment[] = []): Promise<void> {
    if (this.isDraft) {
      await this.launch(text, files);
      return;
    }
    if (this.detail === null) {
      return;
    }
    this.busy = true;
    // Whatever the reader was looking at, sending means they want to see their message and the reply.
    this.scrollToLatest();
    try {
      await connection.sendMessage(this.detail.threadId, text, this.running, this.app.followUp, files);
      this.atBottom = true;
    } catch (e) {
      this.toast(`发送失败：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  private async stop(): Promise<void> {
    if (this.detail === null) {
      return;
    }
    try {
      await connection.stopThread(this.detail.threadId);
      this.toast('已请求停止');
    } catch (e) {
      this.toast(`停止失败：${(e as Error).message}`);
    }
  }

  private async decide(requestId: string, decision: string): Promise<void> {
    if (this.detail === null) {
      return;
    }
    this.busy = true;
    try {
      await connection.respondApproval(this.detail.threadId, requestId, decision);
    } catch (e) {
      this.toast(`提交失败：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  private async answer(requestId: string, answers: Record<string, Object>): Promise<void> {
    if (this.detail === null) {
      return;
    }
    this.busy = true;
    try {
      await connection.answerQuestion(this.detail.threadId, requestId, answers);
    } catch (e) {
      this.toast(`提交失败：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  private subtitle(): string {
    const parts: string[] = [];
    if (this.app.multiEnv && this.environment !== null) {
      parts.push(this.environment.label);
    }
    const shell = this.shell;
    const project = shell !== null ? this.app.projectFor(shell.projectId) : null;
    if (project !== null) {
      parts.push(project.title);
    }
    const model = shell?.modelSelection?.model ?? this.detail?.thread?.modelSelection?.model;
    parts.push(model ? modelLabel(model) : providerLabel(shell?.providerInstanceId));
    const branch = shell?.branch ?? this.detail?.thread?.branch;
    if (branch) {
      parts.push(branch);
    }
    return parts.join(' · ');
  }

  private composerCaption(): string {
    const shell = this.shell;
    if (shell === null) {
      return '';
    }
    if (needsAttention(shell)) {
      return '';
    }
    if (this.running) {
      const run = this.detail?.activeRun;
      const parts: string[] = [threadStatusLabel(shell)];
      const took = durationLabel(run?.startedAt ?? run?.requestedAt, null, this.app.now);
      if (took.length > 0) {
        parts.push(took);
      }
      return parts.join(' · ');
    }
    const where = shortPath(shell.worktreePath);
    return where.length > 0 ? `工作目录 ${where}` : '';
  }

  /**
   * Your messages, approvals, questions and notices rise in when they arrive; redrawing one that is
   * already there (its state changed) does not. The agent's answer and its work log already grow in
   * place as they stream, so they appear as they are. What is there on opening just appears.
   */
  private entryEffect(entry: FeedEntry): TransitionEffect {
    const id = entry.kind === 'work' ? entry.key : `${entry.kind}:${entry.item?.id ?? entry.key}`;
    if (this.shownEntries.has(id)) {
      return TransitionEffect.IDENTITY;
    }
    this.shownEntries.add(id);
    const streams = entry.kind === 'assistant' || entry.kind === 'work';
    return this.feedSettled && !streams ? RISE : TransitionEffect.IDENTITY;
  }

  @Builder
  feedEntry(entry: FeedEntry) {
    if (entry.kind === 'user') {
      UserBubble({
        text: entry.item?.text ?? '', alignLeft: false, files: entry.item?.attachments ?? [],
        environmentId: this.environment?.id ?? ''
      })
    } else if (entry.kind === 'assistant') {
      AssistantMessage({ text: entry.item?.text ?? '', streaming: entry.running })
    } else if (entry.kind === 'work') {
      WorkGroup({ entry: entry, now: this.app.now })
    } else if (entry.kind === 'approval') {
      ApprovalCard({
        item: entry.item, pending: entry.pending, busy: this.busy,
        onDecision: (decision: string) => this.decide(entry.item?.requestId ?? '', decision)
      })
    } else if (entry.kind === 'question') {
      QuestionCard({
        item: entry.item, pending: entry.pending, busy: this.busy,
        onAnswer: (answers: Record<string, Object>) => this.answer(entry.item?.requestId ?? '', answers)
      })
    } else if (entry.kind === 'plan') {
      Column({ space: 6 }) {
        Text('提议的计划').fontSize(Type.small).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary'))
        AssistantMessage({ text: entry.item?.text ?? '', streaming: false })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 10, bottom: 4 })
      .borderRadius(18)
      .backgroundColor($r('app.color.primary_soft'))
      .width('100%')
      .margin({ top: 6, bottom: 6 })
    } else {
      NoticeRow({ item: entry.item })
    }
  }

  // ---- Model, reasoning, speed, permission and plan mode -----------------------------------------

  /** The conversation's current settings, from the shell (or the detail while the shell loads). */
  private currentRun(): RunSettings {
    const run = new RunSettings();
    run.environmentId = this.environment?.id ?? '';
    const selection = this.shell?.modelSelection ?? this.detail?.thread?.modelSelection;
    run.instanceId = selection?.instanceId ?? this.shell?.providerInstanceId ?? '';
    run.model = selection?.model ?? '';
    run.options = (selection?.options ?? []).map((o: ModelOption) => {
      const copy: ModelOption = { id: o.id, value: o.value };
      return copy;
    });
    run.runtimeMode = this.shell?.runtimeMode ?? this.detail?.thread?.runtimeMode ?? 'full-access';
    run.interactionMode = this.shell?.interactionMode ?? this.detail?.thread?.interactionMode ?? 'default';
    return run;
  }

  @Computed
  get modelSummary(): string {
    const selection = this.shell?.modelSelection ?? this.detail?.thread?.modelSelection;
    if (selection === undefined || selection.model.length === 0) {
      return '';
    }
    return runSummary(this.currentRun());
  }

  private openRunSettings(): void {
    this.getUIContext().getFocusController().clearFocus();
    // A draft edits its own settings in place; a conversation sends each change to the computer.
    this.run = this.isDraft ? this.draftRun : this.currentRun();
    this.runSheetShown = true;
  }

  private async applyModel(): Promise<void> {
    if (this.isDraft) {
      return;
    }
    try {
      await connection.setThreadModel(this.threadId, this.run.selection());
    } catch (e) {
      this.toast(`切换模型失败：${(e as Error).message}`);
    }
  }

  private async applyRuntime(): Promise<void> {
    if (this.isDraft) {
      return;
    }
    try {
      await connection.setThreadRuntimeMode(this.threadId, this.run.runtimeMode);
    } catch (e) {
      this.toast(`修改权限失败：${(e as Error).message}`);
    }
  }

  private async applyMode(): Promise<void> {
    if (this.isDraft) {
      return;
    }
    try {
      await connection.setThreadInteractionMode(this.threadId, this.run.interactionMode);
    } catch (e) {
      this.toast(`切换模式失败：${(e as Error).message}`);
    }
  }

  private async togglePlan(): Promise<void> {
    if (this.isDraft) {
      this.draftRun.interactionMode = this.draftRun.interactionMode === 'plan' ? 'default' : 'plan';
      return;
    }
    const plan = (this.shell?.interactionMode ?? this.detail?.thread?.interactionMode ?? 'default') === 'plan';
    try {
      await connection.setThreadInteractionMode(this.threadId, plan ? 'default' : 'plan');
      this.toast(plan ? '已切回对话模式' : '已切到计划模式');
    } catch (e) {
      this.toast(`切换模式失败：${(e as Error).message}`);
    }
  }

  @Builder
  runSheet() {
    RunSettingsPanel({
      settings: this.run,
      showModes: true,
      onModelChanged: () => this.applyModel(),
      onOptionChanged: () => this.applyModel(),
      onRuntimeChanged: () => this.applyRuntime(),
      onModeChanged: () => this.applyMode(),
    })
  }

  // ---- Title bar: files, git and terminal, as on the iOS thread bar ----------------------------

  private get hasCwd(): boolean {
    return (this.workspace?.cwd ?? '').length > 0;
  }

  private titleMenus(): HdsNavigationMenuItemOptions[] {
    const menus: HdsNavigationMenuItemOptions[] = [];
    if (this.hasCwd) {
      menus.push(symbolItem($r('sys.symbol.folder'), '文件', 'thread.files', () => this.openFiles()));
      menus.push(imageItem($r('app.media.ic_git'), 'Git', 'thread.git', () => this.showGitMenu()));
      menus.push(imageItem($r('app.media.ic_terminal'), '终端', 'thread.terminal', () => this.showTerminalMenu()));
    }
    return menus;
  }

  private openFiles(): void {
    openWorkspacePage(this.stack, 'files', new WorkspaceRouteParam(this.threadId, ''));
  }

  private showGitMenu(): void {
    const workspace = this.workspace;
    if (workspace === null) {
      return;
    }
    const status = workspace.git;
    const quick = resolveQuickAction(status, workspace.gitBusy.length > 0);
    const branch = status?.refName ?? this.shell?.branch ?? '分离的 HEAD';
    const rows: ActionMenuRow[] = [
      ActionMenuRow.of('menu.git.status', truncateMiddle(branch, 28), workspace.gitBusy.length > 0 ? workspace.gitBusy : gitStatusSummary(status), () => {
      }).withImage($r('app.media.ic_git')).asInfo(),
      ActionMenuRow.of('menu.git.quick', quick.label, quick.disabled ? quick.hint : '', () => this.runQuickAction())
        .withSymbol(quickActionSymbol(quick.kind, quick.action)).disabled(quick.disabled),
      ActionMenuRow.of('menu.git.review', '查看改动', '', () => {
        openWorkspacePage(this.stack, 'diff', new WorkspaceRouteParam(this.threadId, ''));
      }).withSymbol($r('sys.symbol.doc_text')).disabled(status !== null && !status.isRepo),
      ActionMenuRow.of('menu.git.more', '更多', '', () => {
        openWorkspacePage(this.stack, 'git', new WorkspaceRouteParam(this.threadId, ''));
      }).withSymbol($r('sys.symbol.ellipsis_circle')),
    ];
    showActionMenu(this.getUIContext(), 'thread.git', rows);
  }

  private async runQuickAction(): Promise<void> {
    const workspace = this.workspace;
    if (workspace === null) {
      return;
    }
    const status = workspace.git;
    const quick = resolveQuickAction(status, workspace.gitBusy.length > 0);
    if (quick.disabled) {
      return;
    }
    try {
      if (quick.kind === 'open_pr') {
        const url = status?.pr?.url ?? '';
        if (url.length > 0) {
          this.openUrl(url);
        }
        return;
      }
      if (quick.kind === 'run_pull') {
        this.toast(await workspace.pull());
        return;
      }
      let message = '';
      if (quick.action === 'commit' || quick.action === 'commit_push' || quick.action === 'commit_push_pr') {
        const entered = await promptDialog(this.getUIContext(), quick.label, '留空则由代理生成提交说明。', '提交说明（可选）', quick.label);
        if (entered === null) {
          return;
        }
        message = entered;
      }
      if (status !== null && needsDefaultBranchConfirmation(quick.action, status.isDefaultRef)) {
        const ok = await confirmDialog(this.getUIContext(), `推送到 ${status.refName ?? '默认分支'}？`,
          `这会直接推送到默认分支。也可以先创建功能分支，再推送并创建 ${changeRequestLabel(status)}。`, '直接推送');
        if (!ok) {
          return;
        }
      }
      this.toast(await workspace.runAction(quick.action, message));
    } catch (e) {
      this.toast(`Git 操作失败：${(e as Error).message}`);
    }
  }

  private showTerminalMenu(): void {
    const workspace = this.workspace;
    if (workspace === null) {
      return;
    }
    const canOperate = this.environment?.phase === 'connected';
    const rows: ActionMenuRow[] = [];
    const shell = this.shell;
    const scripts: ProjectScript[] = shell !== null ? (this.app.projectFor(shell.projectId, shell.environmentId ?? '')?.scripts ?? []) : [];
    if (scripts.length === 0) {
      rows.push(ActionMenuRow.of('menu.terminal.noScripts', '没有项目脚本', '', () => {
      }).withSymbol($r('sys.symbol.play')).disabled());
    }
    scripts.forEach((script: ProjectScript) => {
      rows.push(ActionMenuRow.of(`menu.terminal.script.${script.id}`, scriptLabel(script), script.command, () => {
        openWorkspacePage(this.stack, 'terminal', new WorkspaceRouteParam(this.threadId, workspace.nextTerminalId(), script.command));
      }).withSymbol($r('sys.symbol.play')).disabled(!canOperate));
    });
    workspace.terminals.forEach((terminal: TerminalSummary) => {
      rows.push(ActionMenuRow.of(`menu.terminal.${terminal.terminalId}`, terminal.label.length > 0 ? terminal.label : terminal.terminalId,
        [terminalStatusLabel(terminal), baseName(terminal.cwd)].filter((s: string) => s.length > 0).join(' · '),
        () => this.openTerminal(terminal.terminalId)).withImage($r('app.media.ic_terminal')));
    });
    rows.push(ActionMenuRow.of('menu.terminal.new', '打开新终端', '', () => {
      this.openTerminal(workspace.nextTerminalId());
    }).withSymbol($r('sys.symbol.plus')).disabled(!canOperate));
    showActionMenu(this.getUIContext(), 'thread.terminal', rows);
  }

  private openTerminal(terminalId: string): void {
    openWorkspacePage(this.stack, 'terminal', new WorkspaceRouteParam(this.threadId, terminalId));
  }

  private openUrl(url: string): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.openLink(url).catch(() => this.toast('无法打开链接'));
    } catch (e) {
      this.toast('无法打开链接');
    }
  }

  @Builder
  connectionBanner() {
    Row({ space: 8 }) {
      LoadingProgress().width(16).height(16).color($r('app.color.warning_fg'))
      Text(this.environment?.phase === 'offline' ? `${this.environment?.label ?? '电脑'} 已离线，正在重试…` : '正在重新连接…')
        .id('thread.offline')
        .fontSize(Type.small)
        .fontColor($r('app.color.warning_fg'))
    }
    .padding({ left: 12, right: 14, top: 6, bottom: 6 })
    .borderRadius(16)
    .backgroundColor($r('app.color.warning_bg'))
    .shadow({ radius: 8, color: '#14000000', offsetY: 2 })
    .margin({ top: 8 })
    .transition(REVEAL)
  }

  /** The conversation's title, smaller than a page title: the name, and where / which model under it. */
  @Builder
  titleContent() {
    Column({ space: 1 }) {
      Text(this.isDraft ? '新对话'
        : (this.shell?.title ?? this.detail?.thread?.title ?? (this.pendingText.length > 0 ? '新对话' : '对话')))
        .id('thread.title')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (!this.isDraft && this.subtitle().length > 0) {
        Text(this.subtitle())
          .id('thread.title.sub')
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .height('100%')
    .width('100%')
    // Drawn over the whole bar: keep clear of the back button and the glass menus.
    .padding({ left: this.inDetailPane ? 16 : 64, right: this.isDraft || !this.hasCwd ? 16 : 164 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** The draft's middle: which project (and, when it exists on several, which computer) it starts in. */
  @Builder
  draftHero() {
    Column({ space: 10 }) {
      ProjectBadge({ project: this.draftProject, badgeSize: 52 })
      Text(this.draftProject?.title ?? '选择项目')
        .id('draft.project')
        .fontSize(Type.pageTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
        .maxLines(2)
        .textAlign(TextAlign.Center)
      if (this.draftProjects.length > 1) {
        // The same project on several computers: say which one, and let the reader switch.
        Row({ space: 8 }) {
          ForEach(this.draftProjects, (project: ProjectShell) => {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.matebook')).fontSize(14)
                .fontColor([project.environmentId === this.draftEnvId ? $r('app.color.prominent_fg') : $r('app.color.fg_secondary')])
              Text(this.app.environmentFor(project.environmentId)?.label ?? '电脑')
                .fontSize(Type.small)
                .fontColor(project.environmentId === this.draftEnvId ? $r('app.color.prominent_fg') : $r('app.color.fg_secondary'))
                .maxLines(1)
            }
            .id(`draft.env.${project.environmentId ?? ''}`)
            .height(32)
            .padding({ left: 12, right: 12 })
            .borderRadius(16)
            .backgroundColor(project.environmentId === this.draftEnvId ? $r('app.color.prominent') : $r('app.color.chip_bg'))
            .accessibilityText(`在 ${this.app.environmentFor(project.environmentId)?.label ?? '电脑'} 上做`)
            .onClick(() => {
              lightEffects.tap();
              this.pickDraftProject(project);
            })
          }, (project: ProjectShell) => `${project.environmentId ?? ''}:${project.id}:${project.environmentId === this.draftEnvId}`)
        }
      } else if (this.app.multiEnv && this.environment !== null) {
        Text(`在 ${this.environment.label} 上`)
          .id('draft.env')
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_secondary'))
      }
      if ((this.draftProject?.workspaceRoot ?? '').length > 0) {
        Text(shortPath(this.draftProject?.workspaceRoot))
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.CENTER)
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding({ left: 32, right: 32, bottom: 24 })
    .transition(FADE)
  }

  /** The first message of a conversation that is still loading, where the feed will put it. */
  @Builder
  pendingMessage() {
    Column() {
      Column().height(8)
      UserBubble({ text: this.pendingText, alignLeft: false, files: this.pendingFiles, environmentId: this.environment?.id ?? '' })
    }
    .width('100%')
    .constraintSize({ maxWidth: 680 })
    .height('100%')
    .transition(FADE)
  }

  @Builder
  jumpToLatest() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(18).fontColor([$r('app.color.fg')])
    }
    .id('thread.jumpLatest')
    .width(40)
    .height(40)
    .backgroundColor($r('app.color.glass'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: 0.5, color: $r('app.color.border') })
    .shadow({ radius: 12, color: '#1F000000', offsetY: 3 })
    .attributeModifier(new ButtonMaterial(MaterialStyle.THICK))
    .margin({ bottom: 12 })
    .transition(SWAP)
    .accessibilityText('回到最新')
    .onClick(() => {
      this.atBottom = true;
      this.stickToBottom = true;
      this.scroller.scrollEdge(Edge.Bottom, { velocity: 2400 });
    })
  }

  build() {
    HdsNavDestination() {
      Column() {
        Stack({ alignContent: Alignment.Top }) {
          if (this.isDraft) {
            this.draftHero()
          } else if ((this.pendingText.length > 0 || this.pendingFiles.length > 0) &&
            (this.detail === null || this.detail.loading || this.detail.feed.length === 0)) {
            this.pendingMessage()
          } else if (this.detail === null || (this.detail.loading && this.detail.error.length === 0)) {
            Column({ space: 10 }) {
              LoadingProgress().width(32).height(32).color($r('app.color.fg_secondary'))
              Text('正在加载对话…').fontSize(14).fontColor($r('app.color.fg_secondary'))
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .height('100%')
            .transition(FADE)
          } else if (this.detail.loading && this.detail.error.length > 0) {
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(32).fontColor([$r('app.color.danger_fg')])
              Text(this.detail.error).fontSize(14).fontColor($r('app.color.fg_secondary')).textAlign(TextAlign.Center)
            }
            .justifyContent(FlexAlign.Center)
            .padding(32)
            .width('100%')
            .height('100%')
            .transition(FADE)
          } else {
            List({ scroller: this.scroller }) {
              ListItem() {
                Column().height(8)
              }
              if (this.detail.hasMoreHistory) {
                ListItem() {
                  Text('更早的消息请在电脑上查看')
                    .fontSize(12)
                    .fontColor($r('app.color.fg_tertiary'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding(8)
                }
              }
              ForEach(this.detail.feed, (entry: FeedEntry) => {
                ListItem() {
                  Column() {
                    this.feedEntry(entry)
                  }
                  .padding({ left: entry.kind === 'user' || entry.kind === 'assistant' || entry.kind === 'notice' ? 0 : 16, right: entry.kind === 'user' || entry.kind === 'assistant' || entry.kind === 'notice' ? 0 : 16 })
                  .width('100%')
                }
                .transition(this.entryEffect(entry))
              }, (entry: FeedEntry) => `${entry.key}:${entry.signature}:${entry.running}`)
              ListItem() {
                Column().height(12)
              }
            }
            .width('100%')
            .constraintSize({ maxWidth: 680 })
            .height('100%')
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
            .transition(FADE)
            .onAppear(() => {
              // What was there on opening is settled; from now on new entries rise in.
              setTimeout(() => {
                this.feedSettled = true;
              }, 400);
            })
            .onReachEnd(() => {
              this.atBottom = true;
              this.stickToBottom = true;
            })
            .onDidScroll((offset: number, state: ScrollState) => {
              // Only the reader's own drag toward older messages stops following.
              if (state === ScrollState.Scroll && offset < -2) {
                this.stickToBottom = false;
              }
            })
            .onAreaChange((oldArea: Area, newArea: Area) => {
              // The keyboard (or a fold) changes the list height; keep the latest message in view.
              if (this.stickToBottom && Number(oldArea.height) !== Number(newArea.height)) {
                this.scrollToLatest();
              }
            })
            .onScrollIndex((start: number, end: number) => {
              const atBottom = this.detail !== null && end >= this.detail.feed.length;
              if (atBottom !== this.atBottom) {
                this.getUIContext().animateTo({ duration: 180 }, () => {
                  this.atBottom = atBottom;
                });
              }
            })
          }
          if (!this.atBottom && this.detail !== null && !this.detail.loading && this.detail.feed.length > 3) {
            Column() {
              this.jumpToLatest()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .hitTestBehavior(HitTestMode.Transparent)
          }
          if (this.environment !== null && this.environment.phase !== 'connected') {
            this.connectionBanner()
          }
        }
        .layoutWeight(1)
        .width('100%')

        Composer({
          running: this.isDraft ? false : this.running,
          active: !this.busy && this.environment?.phase === 'connected' && (!this.isDraft || this.draftProject !== null),
          placeholder: this.environment?.phase !== 'connected' ? '未连接'
            : this.isDraft ? '描述要做的任务'
            : (this.running ? (this.app.followUp === 'queue' ? '排队一条消息…' : '引导正在进行的任务…') : '给代理发消息'),
          caption: this.isDraft ? '' : this.composerCaption(),
          bottomInset: this.app.bottomInset,
          modelSummary: this.isDraft ? (this.draftRun.model.length > 0 ? runSummary(this.draftRun) : '选择模型') : this.modelSummary,
          planMode: this.isDraft ? this.draftRun.interactionMode === 'plan'
            : (this.shell?.interactionMode ?? this.detail?.thread?.interactionMode ?? 'default') === 'plan',
          returnKey: this.app.returnKey,
          // A question or approval waiting for you comes first; the suggestion is for what to say next.
          suggestion: this.isDraft || (this.shell?.pendingRuntimeRequest ?? null) !== null ? '' : (this.detail?.suggestionText ?? ''),
          environmentId: this.environment?.id ?? '',
          refillText: this.refillText,
          refillSeq: this.refillSeq,
          draftKey: this.isDraft ? '' : (this.detail?.threadId ?? ''),
          onSend: (text: string, files: ChatAttachment[]) => this.send(text, files),
          onStop: () => this.stop(),
          onModelTap: () => this.openRunSettings(),
          onPlanToggle: () => this.togglePlan(),
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.screen'))
      .bindSheet(this.runSheetShown!!, this.runSheet(), {
        height: SheetSize.LARGE,
        dragBar: true,
        showClose: false,
        title: { title: '模型与权限' },
        systemMaterial: immersiveMaterial(MaterialStyle.ULTRA_THICK),
        backgroundColor: systemMaterialOn() ? undefined : $r('app.color.glass'),
        blurStyle: systemMaterialOn() ? undefined : BlurStyle.COMPONENT_ULTRA_THICK,
      })
    }
    .titleBar(compactTitleBar(() => this.titleContent(), this.isDraft ? [] : this.titleMenus(), 'thread.back',
      () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    // In two columns the list stays on the left, so the pane needs no back button.
    .hideBackButton(this.inDetailPane)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.screen'))
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      this.inDetailPane = context.pathStack === detailNav;
      const param = context.pathInfo.param as ThreadRouteParam;
      this.routeParam = param ?? null;
      const threadId = param?.threadId ?? '';
      if (threadId.length > 0) {
        this.attachThread(threadId);
      } else if ((param?.draftKey ?? '').length > 0) {
        this.startDraft(param.draftKey);
      }
      lightEffects.tap();
    })
    .onWillDisappear(() => {
      if (this.threadId.length > 0) {
        this.markSeen(true);
        if (this.inDetailPane && this.app.selectedThreadId === this.threadId) {
          this.app.selectedThreadId = '';
        }
        connection.closeThread(this.threadId);
        workspaces.release(this.workspace);
        this.workspace = null;
        if (notifier.visibleThreadId === this.threadId) {
          notifier.visibleThreadId = '';
        }
        this.threadId = '';
      }
    })
  }
}
