import { appState } from '../model/AppState';

/** App-wide navigation stack: full-screen pages (and threads on phones / folded screens). */
export const appNav: NavPathStack = new NavPathStack();

/** Right-hand pane of the two-column layout (unfolded Pura X Max, tablets). */
export const detailNav: NavPathStack = new NavPathStack();

export class ThreadRouteParam {
  threadId: string;
  /** A new conversation not started yet: its project group (`name:<project name>`); threadId is ''. */
  draftKey: string;

  constructor(threadId: string, draftKey: string = '') {
    this.threadId = threadId;
    this.draftKey = draftKey;
  }
}

/** Terminal, files, git and diff pages of one conversation. */
export class WorkspaceRouteParam {
  threadId: string;
  /** Terminal id for 'terminal'; folder or file path for 'files' / 'file'. */
  target: string;
  /** Terminal only: a project script to run once the shell is attached. */
  command: string;

  constructor(threadId: string, target: string = '', command: string = '') {
    this.threadId = threadId;
    this.target = target;
    this.command = command;
  }
}

export class PullRequestRouteParam {
  environmentId: string;
  projectId: string;
  host: string;
  repository: string;
  number: number;
  title: string;

  constructor(environmentId: string, projectId: string, host: string, repository: string, num: number, title: string) {
    this.environmentId = environmentId;
    this.projectId = projectId;
    this.host = host;
    this.repository = repository;
    this.number = num;
    this.title = title;
  }
}

/** Pushes a conversation's sub-page onto whichever stack shows the conversation. */
export function openWorkspacePage(stack: NavPathStack | null, name: string, param: WorkspaceRouteParam): void {
  (stack ?? appNav).pushPathByName(name, param, true);
}

/** Pull request detail: in the detail pane when wide, else pushed. */
export function openPullRequest(param: PullRequestRouteParam): void {
  if (appState.isWide) {
    appState.selectedThreadId = '';
    detailNav.clear(false);
    detailNav.pushPathByName('pullRequest', param, false);
  } else {
    appNav.pushPathByName('pullRequest', param, true);
  }
}

/** Shows a thread: in the detail pane when wide (replacing the previous one), else as a pushed page. */
export function openThread(threadId: string): void {
  if (appState.isWide) {
    appState.selectedThreadId = threadId;
    detailNav.clear(false);
    detailNav.pushPathByName('thread', new ThreadRouteParam(threadId), false);
  } else {
    appNav.pushPathByName('thread', new ThreadRouteParam(threadId), true);
  }
}

/** New conversation, as on the desktop: first the project picker (shown by the root page). */
export function openNewTask(): void {
  appState.newChatPickerShown = true;
}

/**
 * Opens a new conversation in a project group: the conversation page itself, empty, which becomes the
 * conversation when the first message is sent. Wide: in the detail pane, in place of what was there.
 */
export function openDraftThread(projectKey: string): void {
  const param = new ThreadRouteParam('', projectKey);
  if (appState.isWide) {
    appState.selectedThreadId = '';
    detailNav.clear(false);
    detailNav.pushPathByName('thread', param, false);
  } else {
    appNav.pushPathByName('thread', param, true);
  }
}

export function openPairing(): void {
  appNav.pushPathByName('pair', null, true);
}

/** Settings › 语音输入: where recordings are transcribed, and with which model. */
export function openVoiceSettings(): void {
  appNav.pushPathByName('voice', null, true);
}

/** T3 Connect sign-in and computer picker. */
export function openConnect(): void {
  appNav.pushPathByName('connect', null, true);
}

/** Closes conversations whose thread is gone, e.g. after its computer was removed. */
export function closeMissingThreads(): void {
  const stacks: NavPathStack[] = [appNav, detailNav];
  stacks.forEach((stack: NavPathStack) => {
    const names = stack.getAllPathName();
    for (let index = names.length - 1; index >= 0; index--) {
      if (names[index] !== 'thread') {
        continue;
      }
      const param = stack.getParamByIndex(index) as ThreadRouteParam;
      if (param !== undefined && appState.threadFor(param.threadId) === null) {
        stack.removeByIndexes([index]);
      }
    }
  });
  if (appState.selectedThreadId.length > 0 && appState.threadFor(appState.selectedThreadId) === null) {
    appState.selectedThreadId = '';
  }
}

/**
 * Folding or unfolding crosses the two-column breakpoint. Carry the open conversation (and a
 * new-task draft page) across so the person keeps reading what they were reading.
 */
export function relocateForWidth(wide: boolean): void {
  const from = wide ? appNav : detailNav;
  const to = wide ? detailNav : appNav;
  const names = from.getAllPathName();
  const moved: MovedRoute[] = [];
  const indexes: number[] = [];
  for (let index = 0; index < names.length; index++) {
    if (DETAIL_ROUTES.indexOf(names[index]) >= 0) {
      moved.push(new MovedRoute(names[index], from.getParamByIndex(index) as Object));
      indexes.push(index);
    }
  }
  if (moved.length === 0) {
    if (!wide) {
      appState.selectedThreadId = '';
    }
    return;
  }
  if (wide) {
    appNav.removeByIndexes(indexes);
  }
  detailNav.clear(false);
  // The conversation and whatever was opened from it (files, git, terminal) move together, in order.
  moved.forEach((route: MovedRoute) => to.pushPathByName(route.name, route.param, false));
  const thread = moved.find((route: MovedRoute) => route.name === 'thread');
  appState.selectedThreadId = wide && thread !== undefined ? (thread.param as ThreadRouteParam).threadId : '';
}

/** Pages that live in the detail pane when the screen is wide. */
const DETAIL_ROUTES: string[] = ['thread', 'terminal', 'files', 'file', 'git', 'diff', 'pullRequest'];

class MovedRoute {
  name: string;
  param: Object;

  constructor(name: string, param: Object) {
    this.name = name;
    this.param = param;
  }
}
