import { appState } from '../model/AppState';
import { ThreadShell } from '../model/Types';
import {
  GitActionProgressEvent,
  GitRunStackedActionInput,
  GitStatus,
  TerminalMetadataEvent,
  TerminalSummary,
  VcsPullResult,
  VcsStatusEvent,
  VcsStatusInput,
  EmptyInput,
} from '../model/Workspace';
import { connection } from './Connection';
import { newId } from '../common/Format';
import { Log } from '../common/Log';

const TAG = 'Workspace';

/** Where a thread's agent works: its worktree, else the project's checkout. */
export function cwdForThread(thread: ThreadShell | null): string {
  if (thread === null) {
    return '';
  }
  const worktree = thread.worktreePath ?? '';
  if (worktree.length > 0) {
    return worktree;
  }
  return appState.projectFor(thread.projectId, thread.environmentId ?? '')?.workspaceRoot ?? '';
}

/**
 * Live git status and terminal sessions for one open conversation, as the iOS thread bar shows
 * them: one status stream for the thread's folder, one terminal-metadata stream for its computer.
 */
@ObservedV2
export class ThreadWorkspace {
  readonly threadId: string;
  readonly environmentId: string;
  @Trace cwd: string = '';
  @Trace git: GitStatus | null = null;
  @Trace gitError: string = '';
  /** Label of the git operation in flight ('' when idle). */
  @Trace gitBusy: string = '';
  @Trace terminals: TerminalSummary[] = [];
  private vcsRequest: string = '';
  private terminalRequest: string = '';
  private refs: number = 0;
  private restartTimer: number = -1;

  constructor(threadId: string, environmentId: string) {
    this.threadId = threadId;
    this.environmentId = environmentId;
  }

  get active(): boolean {
    return this.refs > 0;
  }

  get projectId(): string {
    return appState.threadFor(this.threadId, this.environmentId)?.projectId ?? '';
  }

  retain(): void {
    this.refs++;
    if (this.refs === 1) {
      this.start();
    }
  }

  release(): void {
    this.refs = Math.max(0, this.refs - 1);
    if (this.refs === 0) {
      this.stop();
    }
  }

  /** (Re)subscribes, e.g. after the thread moved to a worktree or the computer reconnected. */
  start(): void {
    this.stop();
    this.cwd = cwdForThread(appState.threadFor(this.threadId, this.environmentId));
    if (this.cwd.length > 0) {
      const input: VcsStatusInput = { cwd: this.cwd, includeRemote: true };
      this.vcsRequest = connection.rpcStream(this.environmentId, 'subscribeVcsStatus', input, (values: Object[]) => {
        values.forEach((value: Object) => this.applyVcs(value as VcsStatusEvent));
      }, (ok: boolean, value: Object | null, error: string) => {
        if (!ok && error.length > 0 && this.vcsRequest.length > 0) {
          this.gitError = error;
          Log.w(TAG, `vcs stream ended: ${error}`);
          this.scheduleRestart();
        }
      });
    }
    const empty: EmptyInput = {};
    this.terminalRequest = connection.rpcStream(this.environmentId, 'subscribeTerminalMetadata', empty, (values: Object[]) => {
      values.forEach((value: Object) => this.applyTerminal(value as TerminalMetadataEvent));
    }, (ok: boolean, value: Object | null, error: string) => {
      if (!ok && error.length > 0 && this.terminalRequest.length > 0) {
        Log.d(TAG, `terminal metadata ended: ${error}`);
        this.scheduleRestart();
      }
    });
  }

  /** The socket dropped: reopen both streams once the computer is back. */
  private scheduleRestart(): void {
    if (this.restartTimer >= 0 || this.refs === 0) {
      return;
    }
    this.restartTimer = setTimeout(() => {
      this.restartTimer = -1;
      if (this.refs === 0) {
        return;
      }
      if (appState.environmentFor(this.environmentId)?.phase === 'connected') {
        this.start();
      } else {
        this.scheduleRestart();
      }
    }, 2000);
  }

  stop(): void {
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
    if (this.vcsRequest.length > 0) {
      const id = this.vcsRequest;
      this.vcsRequest = '';
      connection.rpcInterrupt(this.environmentId, id);
    }
    if (this.terminalRequest.length > 0) {
      const id = this.terminalRequest;
      this.terminalRequest = '';
      connection.rpcInterrupt(this.environmentId, id);
    }
  }

  private applyVcs(event: VcsStatusEvent): void {
    const next = this.git !== null ? this.git.copy() : new GitStatus();
    if (event.local !== undefined) {
      next.applyLocal(event.local);
    }
    if (event._tag === 'snapshot' || event._tag === 'remoteUpdated') {
      next.applyRemote(event.remote ?? null);
    }
    this.gitError = '';
    this.git = next;
  }

  private applyTerminal(event: TerminalMetadataEvent): void {
    if (event.type === 'snapshot') {
      this.terminals = (event.terminals ?? []).filter((t: TerminalSummary) => t.threadId === this.threadId);
    } else if (event.type === 'upsert' && event.terminal !== undefined) {
      const terminal = event.terminal;
      if (terminal.threadId !== this.threadId) {
        return;
      }
      const others = this.terminals.filter((t: TerminalSummary) => t.terminalId !== terminal.terminalId);
      this.terminals = others.concat([terminal]).sort((a: TerminalSummary, b: TerminalSummary) =>
      a.terminalId.localeCompare(b.terminalId));
    } else if (event.type === 'remove') {
      this.terminals = this.terminals.filter((t: TerminalSummary) =>
      !(t.threadId === event.threadId && t.terminalId === event.terminalId));
    }
  }

  /** A terminal id not used by this thread yet: term-1, term-2, … */
  nextTerminalId(): string {
    for (let n = 1; n < 100; n++) {
      const id = `term-${n}`;
      if (this.terminals.every((t: TerminalSummary) => t.terminalId !== id)) {
        return id;
      }
    }
    return `term-${Date.now()}`;
  }

  async pull(): Promise<string> {
    const input: VcsStatusInput = { cwd: this.cwd };
    this.gitBusy = '正在拉取…';
    try {
      const result = await connection.rpc(this.environmentId, 'vcs.pull', input) as VcsPullResult;
      return result.status === 'pulled' ? `已拉取 ${result.refName}` : '已是最新';
    } finally {
      this.gitBusy = '';
    }
  }

  /** Runs commit / push / PR creation as one stacked action; resolves with a short summary. */
  runAction(action: string, commitMessage: string = '', featureBranch: boolean = false): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const input: GitRunStackedActionInput = {
        actionId: newId(),
        cwd: this.cwd,
        action: action,
        threadId: this.threadId,
      };
      if (this.projectId.length > 0) {
        input.projectId = this.projectId;
      }
      if (commitMessage.trim().length > 0) {
        input.commitMessage = commitMessage.trim();
      }
      if (featureBranch) {
        input.featureBranch = true;
      }
      this.gitBusy = '正在执行 Git 操作…';
      let failure = '';
      let finished = false;
      connection.rpcStream(this.environmentId, 'git.runStackedAction', input, (values: Object[]) => {
        values.forEach((value: Object) => {
          const event = value as GitActionProgressEvent;
          if (event.kind === 'phase_started' && event.label) {
            this.gitBusy = `${event.label}…`;
          } else if (event.kind === 'action_failed') {
            failure = event.message ?? 'Git 操作失败';
          } else if (event.kind === 'action_finished') {
            finished = true;
          }
        });
      }, (ok: boolean, value: Object | null, error: string) => {
        this.gitBusy = '';
        if (failure.length > 0) {
          reject(new Error(failure));
        } else if (!ok) {
          reject(new Error(error.length > 0 ? error : 'Git 操作失败'));
        } else {
          resolve(finished ? actionDoneLabel(action) : '已完成');
        }
      });
    });
  }
}

function actionDoneLabel(action: string): string {
  switch (action) {
    case 'commit':
      return '已提交';
    case 'push':
      return '已推送';
    case 'create_pr':
      return '已推送并创建 PR';
    case 'commit_push':
      return '已提交并推送';
    case 'commit_push_pr':
      return '已提交、推送并创建 PR';
    default:
      return '已完成';
  }
}

class WorkspaceRegistry {
  private byThread: Map<string, ThreadWorkspace> = new Map();

  /** Shared per thread, so the thread page and its git / terminal pages read one stream. */
  acquire(threadId: string): ThreadWorkspace | null {
    const env = appState.environmentOfThread(threadId);
    if (env === null) {
      return null;
    }
    let workspace = this.byThread.get(threadId);
    if (workspace === undefined) {
      workspace = new ThreadWorkspace(threadId, env.id);
      this.byThread.set(threadId, workspace);
    }
    workspace.retain();
    return workspace;
  }

  release(workspace: ThreadWorkspace | null): void {
    if (workspace === null) {
      return;
    }
    workspace.release();
  }

  /** After a computer reconnects, its streams must be opened again on the new socket. */
  restartFor(environmentId: string): void {
    this.byThread.forEach((workspace: ThreadWorkspace) => {
      if (workspace.environmentId === environmentId && workspace.active) {
        workspace.start();
      }
    });
  }
}

export const workspaces: WorkspaceRegistry = new WorkspaceRegistry();
