import { describe, expect, it } from '@ohos/hypium';
import { Driver, MatchPattern, ON } from '@kit.TestKit';
import {
  backToHome,
  bringRowToMiddle,
  callsOf,
  commandsOfType,
  ensureHome,
  MockCommand,
  MockState,
  MockThreadState,
  openThreadFromHome,
  tapId,
  tapTab,
  typeInto,
  waitFor,
  waitGone,
  waitId,
  waitText,
  waitTextOf,
  waitForMock,
} from './Support';

/** Polls the mock until it has logged a call matching `match`. */
async function waitForCall(tag: string, match: (c: MockCommand) => boolean, timeoutMs: number = 10000): Promise<MockCommand> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = (await callsOf(tag)).find(match);
    if (found !== undefined) {
      return found;
    }
    await new Promise<void>((resolve: () => void) => setTimeout(resolve, 250));
  }
  throw new Error(`Mock never received ${tag}`);
}

async function back(driver: Driver): Promise<void> {
  await tapId(driver, 'page.back');
  await driver.delayMs(700);
}

/** Pops sub-pages until the conversation is back; a tap during a pop animation can be swallowed. */
async function backToThread(driver: Driver): Promise<void> {
  for (let i = 0; i < 4; i++) {
    if (await driver.findComponent(ON.id('thread.title')) !== null) {
      return;
    }
    const pageBack = await driver.findComponent(ON.id('page.back'));
    if (pageBack !== null) {
      await pageBack.click();
    }
    await driver.delayMs(800);
  }
  await waitId(driver, 'thread.title');
}

/**
 * The iOS-parity surfaces: the conversation's title-bar Files / Git / Terminal buttons, and the
 * PR and Usage tabs. Runs against tools/mock-t3/server.mjs (workspace.mjs fixtures).
 */
export default function workspaceJourneyTest() {
  describe('WorkspaceJourney', () => {
    const driver: Driver = Driver.create();

    it('20_gitMenuShowsTheBranchAndOpensTheDiff', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await tapId(driver, 'thread.git');
      // The first row is the live status of the conversation's folder.
      await waitText(driver, 'feature/checkout-steps');
      await waitText(driver, '2 处改动');
      await tapId(driver, 'menu.git.review');
      await waitId(driver, 'diff.file.src/checkout/Steps.tsx', 10000);
      await waitText(driver, "import { AddressStep } from './Address';");
      await back(driver);
      await backToThread(driver);
    });

    it('21_quickActionCommitsPushesAndOpensAPullRequest', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await tapId(driver, 'thread.git');
      await waitId(driver, 'menu.git.quick');
      await waitText(driver, '提交、推送并创建 PR');
      await tapId(driver, 'menu.git.quick');
      // Asks for an optional commit message on a light-material dialog.
      await waitTextOf(driver, 'dialog.title', '提交、推送并创建 PR');
      await typeInto(driver, 'dialog.input', 'split checkout');
      await tapId(driver, 'dialog.confirm');
      const call = await waitForCall('git.runStackedAction', (c: MockCommand) => (c.payload['action'] as string) === 'commit_push_pr');
      expect((call.payload['commitMessage'] as string)).assertEqual('split checkout');
      expect((call.payload['cwd'] as string)).assertEqual('C:\\code\\storefront-web');
      // The status stream reports the new pull request; the quick action becomes "view".
      await driver.delayMs(1200);
      await tapId(driver, 'thread.git');
      await waitId(driver, 'menu.git.quick');
      await waitText(driver, '查看 PR', 10000);
      await driver.pressBack();
      await driver.delayMs(400);
    });

    it('22_gitPageSwitchesBranches', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await tapId(driver, 'thread.git');
      await tapId(driver, 'menu.git.more');
      await waitId(driver, 'git.ref.main', 10000);
      // Let the page finish sliding in; a tap during the push animation can be dropped.
      await driver.delayMs(800);
      await tapId(driver, 'git.ref.main');
      const asked = await driver.waitForComponent(ON.id('dialog.title'), 3000);
      if (asked === null || asked === undefined) {
        await tapId(driver, 'git.ref.main');
      }
      await waitTextOf(driver, 'dialog.title', 'main');
      await tapId(driver, 'dialog.confirm');
      await waitForCall('vcs.switchRef', (c: MockCommand) => (c.payload['refName'] as string) === 'main');
      await waitTextOf(driver, 'git.branch', 'main', 10000);
      await back(driver);
    });

    it('23_filesBrowseFoldersAndOpenFiles', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await tapId(driver, 'thread.files');
      await waitId(driver, 'files.entry.src', 10000);
      await tapId(driver, 'files.entry.src');
      await tapId(driver, 'files.entry.src/checkout', 10000);
      await tapId(driver, 'files.entry.src/checkout/Steps.tsx', 10000);
      await waitId(driver, 'file.source', 10000);
      await waitText(driver, 'export function Steps()');
      await back(driver);
      await back(driver);
      await back(driver);
      // Markdown renders as a document, with a toggle to the source.
      await tapId(driver, 'files.entry.README.md', 10000);
      await waitId(driver, 'file.markdown', 10000);
      await tapId(driver, 'file.toggleSource');
      await waitId(driver, 'file.source');
      await back(driver);
      await backToThread(driver);
    });

    it('24_terminalOpensAShellAndSendsKeys', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await tapId(driver, 'thread.terminal');
      await tapId(driver, 'menu.terminal.new');
      await waitId(driver, 'terminal.web', 10000);
      await waitForCall('terminal.attach', (c: MockCommand) => (c.payload['threadId'] as string) === 't-inbox', 15000);
      await waitGone(driver, ON.id('terminal.status'), 10000);
      // Keys a phone keyboard lacks come from the accessory row.
      await tapId(driver, 'terminal.key.ctrlc');
      await waitForCall('terminal.write', (c: MockCommand) => (c.payload['data'] as string) === '\u0003');
      await tapId(driver, 'terminal.key.tab');
      await waitForCall('terminal.write', (c: MockCommand) => (c.payload['data'] as string) === '\t');
      await back(driver);
      // The session keeps running and is listed in the terminal menu.
      await tapId(driver, 'thread.terminal');
      await waitId(driver, 'menu.terminal.term-1', 8000);
      // A project script runs in a fresh terminal.
      await tapId(driver, 'menu.terminal.script.test');
      await waitForCall('terminal.write', (c: MockCommand) => (c.payload['data'] as string) === 'pnpm test\r', 15000);
      await back(driver);
    });

    it('25_pullRequestsTabListsReviewsAndMerges', 0, async () => {
      await ensureHome(driver);
      await tapTab(driver, 'PR');
      await waitId(driver, 'prs.row.42', 15000);
      await waitId(driver, 'prs.row.41');
      // Involvement filter: only what waits for my review.
      await (await waitText(driver, '待我审查')).click();
      await waitGone(driver, ON.id('prs.row.42'), 8000);
      await waitId(driver, 'prs.row.41');
      await (await waitFor(driver, ON.text('全部', MatchPattern.EQUALS), 8000, 'involvement all')).click();
      await waitId(driver, 'prs.row.42', 8000);
      await tapId(driver, 'prs.row.42');
      await waitTextOf(driver, 'pr.detailTitle', '拆分结账步骤组件', 10000);
      await waitId(driver, 'pr.check.build');
      await tapId(driver, 'pr.merge');
      await tapId(driver, 'pr.merge.squash');
      await tapId(driver, 'dialog.confirm');
      await waitForCall('pullRequests.runAction', (c: MockCommand) =>
      (c.payload['action'] as string) === 'merge' && (c.payload['mergeMethod'] as string) === 'squash');
      await waitId(driver, 'pr.state');
      await waitText(driver, '已合并', 10000);
      const pageBack = await driver.findComponent(ON.id('page.back'));
      if (pageBack !== null && pageBack !== undefined) {
        await pageBack.click();
        await driver.delayMs(400);
      }
      await tapTab(driver, '对话');
    });

    it('26_usageTabShowsLimitsAndSpend', 0, async () => {
      await ensureHome(driver);
      await tapTab(driver, '用量');
      // Limits first, as on iOS: what is left in each window and when it resets.
      await waitId(driver, 'usage.limit.session', 15000);
      await waitText(driver, '剩余 58%');
      await (await waitText(driver, '费用')).click();
      await waitTextOf(driver, 'usage.total', '$', 15000);
      await waitId(driver, 'usage.chart');
      await tapId(driver, 'usage.window.7');
      await waitText(driver, '过去 7 天');
      await (await waitFor(driver, ON.text('Token', MatchPattern.EQUALS), 8000, 'tokens')).click();
      await waitText(driver, 'Token');
      await tapTab(driver, '对话');
    });

    it('28_modelPickerSwitchesHarnessInAConversation', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await tapId(driver, 'composer.model');
      // Harnesses on the left, their models in the middle, the model's settings on the right.
      await tapId(driver, 'runSettings.harness.codex');
      await tapId(driver, 'runSettings.model.codex.gpt-6.1-sol-mini');
      await tapId(driver, 'runSettings.option.reasoningEffort.high');
      await tapId(driver, 'runSettings.option.fastMode.on');
      await driver.pressBack();
      await driver.delayMs(600);
      await waitText(driver, 'Sol mini · 高 · 快速');
      const sent = await commandsOfType('thread.model-selection.set');
      expect(sent.length > 0).assertTrue();
      const last = sent[sent.length - 1].payload['modelSelection'] as Record<string, Object>;
      expect(last['instanceId'] as string).assertEqual('codex');
      expect(last['model'] as string).assertEqual('gpt-6.1-sol-mini');
      expect(JSON.stringify(last['options'])).assertContain('"fastMode","value":true');
      expect(JSON.stringify(last['options'])).assertContain('"high"');
      await backToHome(driver);
    });

    it('27_longPressMenuSnoozesRenamesAndDeletes', 0, async () => {
      const thread = (id: string, s: MockState): MockThreadState | undefined =>
        s.threads.find((t: MockThreadState) => t.id === id);
      await ensureHome(driver);
      // 稍后提醒 → 明天上午: the thread leaves the active sections until then.
      await (await bringRowToMiddle(driver, 'home.thread.t-long')).longClick();
      await tapId(driver, 'home.menu.snooze');
      await tapId(driver, 'home.menu.snooze.tomorrow');
      await waitForMock((s: MockState) => (thread('t-long', s)?.snoozedUntil ?? null) !== null);
      // And back.
      await (await bringRowToMiddle(driver, 'home.thread.t-long')).longClick();
      await tapId(driver, 'home.menu.unsnooze');
      await waitForMock((s: MockState) => (thread('t-long', s)?.snoozedUntil ?? null) === null);
      // 重命名 opens the glass prompt with the current title.
      await (await bringRowToMiddle(driver, 'home.thread.t-long')).longClick();
      await tapId(driver, 'home.menu.rename');
      await typeInto(driver, 'dialog.input', 'nightly docs');
      await tapId(driver, 'dialog.confirm');
      await waitForMock((s: MockState) => thread('t-long', s)?.title === 'nightly docs');
      await waitText(driver, 'nightly docs');
      // 删除 asks first, then the row goes.
      await (await bringRowToMiddle(driver, 'home.thread.t-long')).longClick();
      await tapId(driver, 'home.menu.delete');
      await waitTextOf(driver, 'dialog.title', '删除');
      await tapId(driver, 'dialog.confirm');
      await waitGone(driver, ON.id('home.thread.t-long'));
      await waitForMock((s: MockState) => thread('t-long', s) === undefined);
    });
  });
}
