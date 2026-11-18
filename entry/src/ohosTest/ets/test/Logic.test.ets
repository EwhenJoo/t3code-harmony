import { describe, expect, it } from '@ohos/hypium';
import { originOf, parsePairingInput, wsUrlFor } from '../../../main/ets/net/Pairing';
import { parseInline, parseMarkdown, MdBlock } from '../../../main/ets/components/Markdown';
import { buildFeed, FeedEntry, ThreadDetailState } from '../../../main/ets/model/ThreadDetail';
import { AppState, EnvironmentState, HomeRow } from '../../../main/ets/model/AppState';
import { ProjectShell, RunRecord, SavedEnvironment, ShellStreamItem, ThreadShell, TurnItem } from '../../../main/ets/model/Types';
import { durationLabel, modelLabel, relativeTime } from '../../../main/ets/common/Format';
import { derToJoseSignature, deviceVerificationCode, dpopHtu } from '../../../main/ets/net/Dpop';
import { deriveProjectIdentity } from '../../../main/ets/common/ProjectIdentity';
import { DiffLine, GitStatus, parseUnifiedDiff, remainingPercent, resolveQuickAction, UsageWindow } from '../../../main/ets/model/Workspace';
import { encodeSpeechRequest, TranscriptionOptions } from '../../../main/ets/services/Voice';
import { util } from '@kit.ArkTS';

function turnItem(id: string, ordinal: number, type: string): TurnItem {
  const item: TurnItem = { id: id, threadId: 't', ordinal: ordinal, type: type, status: 'completed' };
  return item;
}

function withText(item: TurnItem, text: string): TurnItem {
  item.text = text;
  return item;
}

function thread(id: string): ThreadShell {
  const shell: ThreadShell = {
    id: id, projectId: 'p', title: id, providerInstanceId: 'claudeAgent', status: 'completed',
    createdAt: '2026-11-16T00:00:00.000Z', updatedAt: '2026-11-16T00:00:00.000Z',
  };
  return shell;
}

function computer(id: string, label: string): EnvironmentState {
  const env = new SavedEnvironment();
  env.id = id;
  env.label = label;
  return new EnvironmentState(env);
}

function snapshotOf(projects: ProjectShell[], threads: ThreadShell[]): ShellStreamItem {
  const item: ShellStreamItem = { kind: 'snapshot', snapshot: { snapshotSequence: 1, projects: projects, threads: threads } };
  return item;
}

function hex(text: string): Uint8Array {
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(text.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function toHex(bytes: Uint8Array): string {
  let s = '';
  bytes.forEach((b: number) => {
    s += (b < 16 ? '0' : '') + b.toString(16);
  });
  return s;
}

export default function logicTest() {
  describe('Dpop', () => {
    it('convertsDerSignaturesWithLeadingZeros', 0, () => {
      // Node's crypto.sign output where both integers carry a 0x00 sign byte.
      const der = hex('30460221009db6e9c0bc70d20c16334c58bf68e06f72121f9379777386815b0dcd3772c544022100e59d607c2413d662b893db97bf446e10c6af5c12ac2a1a4a5b202afbe644b338');
      expect(toHex(derToJoseSignature(der))).assertEqual(
        '9db6e9c0bc70d20c16334c58bf68e06f72121f9379777386815b0dcd3772c544e59d607c2413d662b893db97bf446e10c6af5c12ac2a1a4a5b202afbe644b338');
    });
    it('padsShortIntegers', 0, () => {
      const r = '11'.repeat(31);
      const s = '22'.repeat(32);
      const raw = derToJoseSignature(hex(`3043021f${r}0220${s}`));
      expect(raw.length).assertEqual(64);
      expect(toHex(raw)).assertEqual(`00${r}${s}`);
    });
    it('dropsQueryAndFragmentFromHtu', 0, () => {
      expect(dpopHtu('wss://abc.example.com/ws?wsTicket=1#x')).assertEqual('wss://abc.example.com/ws');
      expect(dpopHtu('https://relay.t3.codes/v1/environments/e1/connect')).assertEqual('https://relay.t3.codes/v1/environments/e1/connect');
    });
    it('derivesTheSameApprovalCodeAsTheComputer', 0, () => {
      expect(deviceVerificationCode('NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs')).assertEqual('FMVD-ER3W');
    });
  });

  describe('PairingLinks', () => {
    it('readsTokenFromHash', 0, () => {
      const t = parsePairingInput('http://192.168.1.5:3773/pair#token=abc123');
      expect(t.baseUrl).assertEqual('http://192.168.1.5:3773');
      expect(t.token).assertEqual('abc123');
    });
    it('unwrapsDesktopAppLink', 0, () => {
      const inner = encodeURIComponent('https://puli.example.ts.net/pair#token=xyz');
      const t = parsePairingInput(`t3code://pair?pairingUrl=${inner}`);
      expect(t.baseUrl).assertEqual('https://puli.example.ts.net');
      expect(t.token).assertEqual('xyz');
    });
    it('readsHostedPairingRequest', 0, () => {
      const t = parsePairingInput('https://app.t3.codes/pair?host=10.0.0.2:3773&label=Office#token=k1');
      expect(t.baseUrl).assertEqual('http://10.0.0.2:3773');
      expect(t.token).assertEqual('k1');
      expect(t.label).assertEqual('Office');
    });
    it('addsSchemeForBareHosts', 0, () => {
      expect(originOf('192.168.1.5:3773')).assertEqual('http://192.168.1.5:3773');
      expect(originOf('box.example.com/x')).assertEqual('https://box.example.com');
      expect(wsUrlFor('https://a.b')).assertEqual('wss://a.b');
    });
    it('emptyInputHasNoTarget', 0, () => {
      expect(parsePairingInput('   ').token).assertEqual('');
    });
  });

  describe('Markdown', () => {
    it('splitsBlocks', 0, () => {
      const blocks = parseMarkdown('# 标题\n\n段落 **粗体** 和 `代码`\n\n- 一\n- 二\n\n```ts\nconst a = 1;\n```\n\n> 引用');
      const kinds = blocks.map((b: MdBlock) => b.kind).join(',');
      expect(kinds).assertEqual('h,p,li,li,code,quote');
      expect(blocks[4].lang).assertEqual('ts');
      expect(blocks[4].text).assertEqual('const a = 1;');
    });
    it('parsesInlineStyles', 0, () => {
      const spans = parseInline('a **b** `c` [d](https://e) *f*');
      expect(spans.some((s) => s.bold && s.text === 'b')).assertTrue();
      expect(spans.some((s) => s.code && s.text === 'c')).assertTrue();
      expect(spans.some((s) => s.link === 'https://e' && s.text === 'd')).assertTrue();
      expect(spans.some((s) => s.italic && s.text === 'f')).assertTrue();
    });
    it('rendersTablesAsMonospaceRows', 0, () => {
      const blocks = parseMarkdown('| a | b |\n|---|---|\n| 1 | 2 |');
      expect(blocks[0].kind).assertEqual('table');
      expect(blocks[0].text.split('\n').length).assertEqual(2);
    });
  });

  describe('ThreadFeed', () => {
    it('groupsWorkBetweenMessagesAndHidesRoutinePreparation', 0, () => {
      const state = new ThreadDetailState('t');
      const prep = turnItem('prep', 0, 'command_execution');
      prep.input = 'Preparing workspace';
      prep.exitCode = 0;
      const command = turnItem('c1', 2, 'command_execution');
      command.input = 'ls';
      const child = turnItem('child', 5, 'command_execution');
      child.parentItemId = 'c1';
      const items: TurnItem[] = [
        prep,
        withText(turnItem('u', 1, 'user_message'), '你好'),
        command,
        withText(turnItem('r1', 3, 'reasoning'), '想一想'),
        withText(turnItem('a', 4, 'assistant_message'), '完成'),
        child,
      ];
      const feed = buildFeed(items, state);
      expect(feed.map((e: FeedEntry) => e.kind).join(',')).assertEqual('user,work,assistant');
      expect(feed[1].items.length).assertEqual(2);
    });
    it('marksApprovalsPendingOnlyWhileTheRequestIsPending', 0, () => {
      const state = new ThreadDetailState('t');
      state.requests = [{ id: 'r', kind: 'command', status: 'pending', createdAt: '' }];
      const approval = turnItem('ap', 1, 'approval_request');
      approval.requestId = 'r';
      expect(buildFeed([approval], state)[0].pending).assertTrue();
      state.requests = [{ id: 'r', kind: 'command', status: 'resolved', createdAt: '' }];
      expect(buildFeed([approval], state)[0].pending).assertFalse();
    });
    it('dropsEmptyFinishedAssistantMessages', 0, () => {
      const state = new ThreadDetailState('t');
      const feed = buildFeed([withText(turnItem('a', 1, 'assistant_message'), '  ')], state);
      expect(feed.length).assertEqual(0);
    });
  });

  describe('HomeList', () => {
    it('groupsThreadsLikeTheIosList', 0, () => {
      const app = new AppState();
      const project: ProjectShell = { id: 'p', title: 'proj' };
      app.projects = [project];
      const attention = thread('attention');
      attention.status = 'running';
      attention.pendingRuntimeRequest = { id: 'x', kind: 'command', createdAt: '' };
      const working = thread('working');
      working.status = 'running';
      working.activeRunId = 'run';
      const settled = thread('settled');
      settled.settledAt = '2026-11-16T00:00:00.000Z';
      const child = thread('child');
      child.lineage = { relationshipToParent: 'subagent' };
      const archived = thread('archived');
      archived.archivedAt = '2026-11-16T00:00:00.000Z';
      app.threads = [attention, working, thread('inbox'), settled, child, archived];
      app.showSettled = true;
      const rows = app.buildHomeRows('', '', 25);
      const headers = rows.filter((r: HomeRow) => r.kind === 'header').map((r: HomeRow) => r.section).join(',');
      expect(headers).assertEqual('attention,working,inbox,settled');
      const ids = rows.filter((r: HomeRow) => r.kind === 'thread').map((r: HomeRow) => r.thread?.id ?? '').join(',');
      expect(ids).assertEqual('attention,working,inbox,settled');
    });
    it('groupsByProjectLikeTheDesktopSidebar', 0, () => {
      const app = new AppState();
      app.projects = [{ id: 'a', title: 'alpha' }, { id: 'b', title: 'beta' }];
      const waiting = thread('waiting');
      waiting.projectId = 'b';
      waiting.pendingRuntimeRequest = { id: 'x', kind: 'command', createdAt: '' };
      const running = thread('running');
      running.projectId = 'b';
      running.status = 'queued';
      running.activeRunId = 'run';
      const older = thread('older');
      older.projectId = 'a';
      const done = thread('done');
      done.projectId = 'a';
      done.settledAt = '2026-11-16T00:00:00.000Z';
      // A failure that was settled is history too (the desktop hides it), not something to look at.
      const oldFailure = thread('oldFailure');
      oldFailure.projectId = 'a';
      oldFailure.status = 'failed';
      oldFailure.settledAt = '2026-11-16T00:00:00.000Z';
      app.threads = [older, running, waiting, done, oldFailure];
      // Settled conversations are hidden in their group by default.
      expect(app.showSettled).assertFalse();
      let rows = app.buildHomeRows('', '', 25, 'project');
      const headers = rows.filter((r: HomeRow) => r.kind === 'header').map((r: HomeRow) => `${r.title}:${r.count}:${r.attention}`).join(',');
      expect(headers.indexOf('beta:2:1') >= 0 && headers.indexOf('alpha:1:0') >= 0).assertTrue();
      const inBeta = rows.filter((r: HomeRow) => r.kind === 'thread' && r.project?.id === 'b').map((r: HomeRow) => r.thread?.id ?? '').join(',');
      expect(inBeta).assertEqual('waiting,running');
      // Folding a project keeps its header and hides its conversations.
      app.collapsedProjects = [rows.filter((r: HomeRow) => r.kind === 'header' && r.title === 'beta')[0].groupKey];
      rows = app.buildHomeRows('', '', 25, 'project');
      expect(rows.some((r: HomeRow) => r.kind === 'thread' && r.thread?.id === 'waiting')).assertFalse();
      expect(rows.some((r: HomeRow) => r.kind === 'header' && r.title === 'beta' && r.collapsed)).assertTrue();
      // With "show settled" on, the settled one is back at the end of its group.
      app.showSettled = true;
      rows = app.buildHomeRows('', '', 25, 'project');
      const inAlpha = rows.filter((r: HomeRow) => r.kind === 'thread' && r.project?.id === 'a').map((r: HomeRow) => r.thread?.id ?? '').join(',');
      expect(inAlpha.split(',').sort().join(',')).assertEqual('done,oldFailure,older');
    });
    it('offersThePromptSuggestionOnlyForTheLatestCompletedRun', 0, () => {
      const state = new ThreadDetailState('t');
      const done: RunRecord = { id: 'r1', ordinal: 1, status: 'completed', startedAt: '2026-11-16T00:00:00.000Z' };
      state.runs = [done];
      state.promptSuggestion = { runId: 'r1', text: ' 再跑一遍测试 ' };
      expect(state.suggestionText).assertEqual('再跑一遍测试');
      // A newer run makes it stale, whether it is still going or already finished.
      state.runs = [done, { id: 'r2', ordinal: 2, status: 'running', startedAt: '2026-11-16T00:01:00.000Z' }];
      expect(state.suggestionText).assertEqual('');
      // A message withdrawn before its run started does not count as newer.
      state.runs = [done, { id: 'r2', ordinal: 2, status: 'cancelled', startedAt: null }];
      expect(state.suggestionText).assertEqual('再跑一遍测试');
      state.promptSuggestion = null;
      expect(state.suggestionText).assertEqual('');
    });
    it('mergesSameNameProjectsAndDotsFoldedOnes', 0, () => {
      const app = new AppState();
      const home = computer('home', '家里的电脑');
      const lab = computer('lab', '实验室');
      app.environments = [home, lab];
      const h1 = thread('h1');
      h1.projectId = 'p';
      app.applyShellItem(home, snapshotOf([{ id: 'p', title: 'web', projectIcon: { kind: 'emoji', emoji: 'W' } }], [h1]));
      const l1 = thread('l1');
      l1.projectId = 'q';
      l1.status = 'running';
      l1.activeRunId = 'run';
      const l2 = thread('l2');
      l2.projectId = 'r';
      app.applyShellItem(lab, snapshotOf([{ id: 'q', title: ' web ' }, { id: 'r', title: 'trainer' }], [l1, l2]));
      let rows = app.buildHomeRows('', '', 25, 'project');
      const headers = rows.filter((r: HomeRow) => r.kind === 'header');
      // One "web" group for both computers, speaking with the project that has an icon.
      expect(headers.map((r: HomeRow) => `${r.title}:${r.count}`).sort().join(',')).assertEqual('trainer:1,web:2');
      const web = headers.filter((r: HomeRow) => r.title === 'web')[0];
      expect(web.project?.id ?? '').assertEqual('p');
      expect(web.state).assertEqual('working');
      const inWeb = rows.filter((r: HomeRow) => r.kind === 'thread' && r.groupKey === web.groupKey).map((r: HomeRow) => r.thread?.id ?? '');
      expect(inWeb.join(',')).assertEqual('l1,h1');
      // The dot follows the most pressing state: approval beats running; opened completions show none.
      (app.threadFor('h1') as ThreadShell).pendingRuntimeRequest = { id: 'x', kind: 'command', createdAt: '' };
      expect(app.buildHomeRows('', '', 25, 'project').filter((r: HomeRow) => r.groupKey === web.groupKey)[0].state).assertEqual('approval');
      expect(headers.filter((r: HomeRow) => r.title === 'trainer')[0].state).assertEqual('done');
      (app.threadFor('l2') as ThreadShell).lastVisitedAt = '2026-11-17T00:00:00.000Z';
      rows = app.buildHomeRows('', '', 25, 'project');
      expect(rows.filter((r: HomeRow) => r.kind === 'header' && r.title === 'trainer')[0].state).assertEqual('');
      // A run that finished after that visit is news again.
      (app.threadFor('l2') as ThreadShell).latestRunCompletedAt = '2026-11-18T00:00:00.000Z';
      rows = app.buildHomeRows('', '', 25, 'project');
      expect(rows.filter((r: HomeRow) => r.kind === 'header' && r.title === 'trainer')[0].state).assertEqual('done');
    });
    it('foldsSideChatsAndDelegatedThreadsUnderTheirParentLikeTheDesktop', 0, () => {
      const app = new AppState();
      const home = computer('home', '家里的电脑');
      const lab = computer('lab', '实验室');
      app.environments = [home, lab];
      const parent = thread('parent');
      const side = thread('side');
      side.lineage = { parentThreadId: 'parent', relationshipToParent: null, sideChat: true };
      app.applyShellItem(home, snapshotOf([{ id: 'p', title: 'web' }], [parent, side]));
      // Handed to the lab by `parent` on the home computer: shown under the parent there.
      const delegated = thread('delegated');
      delegated.delegatedFrom = { environmentId: 'home', threadId: 'parent' };
      // Delegated by a computer this phone is not connected to: nowhere else to see it, so it stays.
      const orphan = thread('orphan');
      orphan.delegatedFrom = { environmentId: 'elsewhere', threadId: 'x' };
      app.applyShellItem(lab, snapshotOf([{ id: 'p', title: 'web' }], [delegated, orphan]));
      const ids = (): string => app.buildHomeRows('', '', 25, 'project')
        .filter((r: HomeRow) => r.kind === 'thread').map((r: HomeRow) => r.thread?.id ?? '').sort().join(',');
      expect(ids()).assertEqual('orphan,parent');
      // Once the parent is archived, the delegated thread gets its own row again.
      (app.threadFor('parent', 'home') as ThreadShell).archivedAt = '2026-11-17T00:00:00.000Z';
      app.threads = app.threads.slice();
      expect(ids()).assertEqual('delegated,orphan');
    });
    it('hidesProjectsWhoseConversationsAreAllSettled', 0, () => {
      const app = new AppState();
      app.projects = [{ id: 'live', title: 'live' }, { id: 'done', title: 'done' }];
      const active = thread('active');
      active.projectId = 'live';
      const old = thread('old');
      old.projectId = 'done';
      old.settledAt = '2026-11-16T00:00:00.000Z';
      app.threads = [active, old];
      let rows = app.buildHomeRows('', '', 25, 'project');
      expect(rows.some((r: HomeRow) => r.kind === 'header' && r.title === 'done')).assertFalse();
      // No row about them; "show settled" brings them back, and search always looks everywhere.
      expect(rows.some((r: HomeRow) => r.kind === 'more')).assertFalse();
      app.showSettled = true;
      rows = app.buildHomeRows('', '', 25, 'project');
      expect(rows.some((r: HomeRow) => r.kind === 'header' && r.title === 'done')).assertTrue();
      app.showSettled = false;
      rows = app.buildHomeRows('old', '', 25, 'project');
      expect(rows.some((r: HomeRow) => r.kind === 'thread' && r.thread?.id === 'old')).assertTrue();
    });
    it('projectIdentityMatchesTheDesktop', 0, () => {
      // Expected values computed with the desktop's own deriveProjectIdentity.
      const cases: string[][] = [
        ['storefront-web', 'SW', 'cyan'], ['billing-api', 'BA', 'sky'], ['trainer', 'TR', 'violet'],
        ['xuanji-simulator', 'XS', 'gray'], ['XuanJiData', 'XA', 'fuchsia'], ['测试项目', '测目', 'emerald'],
        ['agent-access', 'AA', 'yellow'], ['slurm', 'SM', 'rose'], ['web3 app', 'W3', 'orange'], ['', 'PR', 'fuchsia'],
      ];
      cases.forEach((c: string[]) => {
        const identity = deriveProjectIdentity(c[0]);
        expect(`${c[0]}:${identity.monogram}:${identity.color}`).assertEqual(`${c[0]}:${c[1]}:${c[2]}`);
      });
    });
    it('searchMatchesTitleAndProject', 0, () => {
      const app = new AppState();
      app.projects = [{ id: 'p', title: 'billing-api' }];
      const a = thread('a');
      a.title = '修复登录';
      const b = thread('b');
      b.title = '其他';
      app.threads = [a, b];
      expect(app.buildHomeRows('登录', '', 25).filter((r: HomeRow) => r.kind === 'thread').length).assertEqual(1);
      expect(app.buildHomeRows('billing', '', 25).filter((r: HomeRow) => r.kind === 'thread').length).assertEqual(2);
      expect(app.buildHomeRows('nothing', '', 25)[0].kind).assertEqual('empty');
    });
    it('mergesSeveralComputersIntoOneList', 0, () => {
      const app = new AppState();
      const home = computer('home', '家里的电脑');
      const lab = computer('lab', '实验室');
      app.environments = [home, lab];
      app.applyShellItem(home, snapshotOf([{ id: 'p', title: 'web' }], [thread('h1'), thread('h2')]));
      const q = thread('l1');
      q.projectId = 'q';
      app.applyShellItem(lab, snapshotOf([{ id: 'q', title: 'trainer' }], [q]));
      // Both computers' threads in one list, each knowing where it runs.
      expect(app.threads.length).assertEqual(3);
      expect(app.environmentOfThread('l1')?.label ?? '').assertEqual('实验室');
      expect(app.projectFor('q')?.environmentId ?? '').assertEqual('lab');
      // Filtering by computer keeps only its threads.
      const labRows = app.buildHomeRows('', 'env:lab', 25).filter((r: HomeRow) => r.kind === 'thread');
      expect(labRows.map((r: HomeRow) => r.thread?.id ?? '').join(',')).assertEqual('l1');
      // Searching matches the computer name too.
      expect(app.buildHomeRows('实验室', '', 25).filter((r: HomeRow) => r.kind === 'thread').length).assertEqual(1);
      // A fresh snapshot from one computer replaces only that computer's share.
      app.applyShellItem(home, snapshotOf([{ id: 'p', title: 'web' }], [thread('h3')]));
      expect(app.threads.map((t: ThreadShell) => t.id).sort().join(',')).assertEqual('h3,l1');
      // Removing a computer drops its threads and projects.
      app.clearEnvironmentData('lab');
      expect(app.threads.map((t: ThreadShell) => t.id).join(',')).assertEqual('h3');
      expect(app.projectFor('q')).assertNull();
    });
    it('limitsSettledAndOffersMore', 0, () => {
      const app = new AppState();
      const many: ThreadShell[] = [];
      for (let i = 0; i < 30; i++) {
        const s = thread(`s${i}`);
        s.settledAt = '2026-11-16T00:00:00.000Z';
        many.push(s);
      }
      app.threads = many;
      app.showSettled = true;
      const rows = app.buildHomeRows('', '', 25);
      const more = rows.find((r: HomeRow) => r.kind === 'more');
      expect(more?.count ?? 0).assertEqual(5);
    });
  });

  describe('Formatting', () => {
    it('labelsModelsReadably', 0, () => {
      expect(modelLabel('claude-opus-5-5')).assertEqual('Opus 5.5');
      expect(modelLabel('gpt-6.1-sol')).assertEqual('GPT-6.1 Sol');
    });
    it('describesTimeNaturally', 0, () => {
      const now = Date.parse('2026-11-16T12:00:00.000Z');
      expect(relativeTime('2026-11-16T11:59:30.000Z', now)).assertEqual('刚刚');
      expect(relativeTime('2026-11-16T11:30:00.000Z', now)).assertEqual('30 分钟前');
      expect(relativeTime('2026-11-15T09:00:00.000Z', now)).assertEqual('昨天');
      expect(durationLabel('2026-11-16T11:59:59.800Z', '2026-11-16T12:00:00.000Z', now)).assertEqual('');
      expect(durationLabel('2026-11-16T11:58:00.000Z', '2026-11-16T12:00:05.000Z', now)).assertEqual('2 分 5 秒');
    });

    it('picksTheGitQuickActionLikeIos', 0, () => {
      const status = new GitStatus();
      status.refName = 'feature/x';
      status.hasPrimaryRemote = true;
      status.hasUpstream = true;
      status.hasWorkingTreeChanges = true;
      expect(resolveQuickAction(status, false).action).assertEqual('commit_push_pr');
      status.isDefaultRef = true;
      expect(resolveQuickAction(status, false).action).assertEqual('commit_push');
      status.isDefaultRef = false;
      status.hasWorkingTreeChanges = false;
      status.behindCount = 2;
      expect(resolveQuickAction(status, false).kind).assertEqual('run_pull');
      status.aheadCount = 1;
      expect(resolveQuickAction(status, false).disabled).assertTrue();
      status.behindCount = 0;
      expect(resolveQuickAction(status, false).action).assertEqual('create_pr');
      status.aheadCount = 0;
      status.pr = { number: 7, url: 'https://example.com/pull/7', state: 'open' };
      expect(resolveQuickAction(status, false).kind).assertEqual('open_pr');
      expect(resolveQuickAction(status, true).disabled).assertTrue();
      expect(resolveQuickAction(null, false).disabled).assertTrue();
    });

    it('parsesUnifiedDiffsWithLineNumbers', 0, () => {
      const files = parseUnifiedDiff([
        'diff --git a/a.ts b/a.ts',
        '--- a/a.ts',
        '+++ b/a.ts',
        '@@ -3,3 +3,4 @@',
        ' keep',
        '-old',
        '+new',
        '+added',
        ' tail',
        '',
      ].join(String.fromCharCode(10)));
      expect(files.length).assertEqual(1);
      expect(files[0].path).assertEqual('a.ts');
      expect(files[0].additions).assertEqual(2);
      expect(files[0].deletions).assertEqual(1);
      const added = files[0].lines.filter((l: DiffLine) => l.kind === 'add');
      expect(added[0].newNo).assertEqual(4);
      expect(files[0].lines.filter((l: DiffLine) => l.kind === 'del')[0].oldNo).assertEqual(4);
    });

    it('encodesRecordingsTheWayTheComputerDecodesThem', 0, () => {
      const options: TranscriptionOptions = {
        speechLanguage: 'zh', speechTranslateToEnglish: false, speechCustomWords: [],
        speechRemoveFillerWords: true, speechSilenceFiltering: false,
      };
      const first = new Int16Array([0, 16384, -32768]);
      const second = new Int16Array([32767]);
      const body = encodeSpeechRequest(options, [first.buffer, second.buffer]);
      const length = new DataView(body).getUint32(0, true);
      // The options are padded to whole words so the samples are aligned Float32s right after.
      expect(length % 4).assertEqual(0);
      expect(body.byteLength).assertEqual(4 + length + 4 * 4);
      const json = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(body, 4, length));
      const decoded = JSON.parse(json) as TranscriptionOptions;
      expect(decoded.speechLanguage).assertEqual('zh');
      expect(decoded.speechSilenceFiltering).assertFalse();
      const samples = new Float32Array(body, 4 + length, 4);
      expect(samples[0]).assertEqual(0);
      expect(samples[1]).assertEqual(0.5);
      expect(samples[2]).assertEqual(-1);
      expect(samples[3] < 1 && samples[3] > 0.999).assertTrue();
    });

    it('roundsUsageWindowsToWhatIsLeft', 0, () => {
      const window: UsageWindow = { id: 'w', kind: 'weekly', label: '每周', usedPercent: 63.4 };
      expect(remainingPercent(window)).assertEqual(37);
      window.usedPercent = 120;
      expect(remainingPercent(window)).assertEqual(0);
    });
  });
}
