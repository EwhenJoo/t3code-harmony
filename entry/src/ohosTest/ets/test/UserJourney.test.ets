import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, MatchPattern, ON } from '@kit.TestKit';
import {
  allowMicrophone,
  allowNotifications,
  backToHome,
  commandsOfType,
  MOCK_HOST,
  LAB_HOST,
  labPairLink,
  labReset,
  MockCommand,
  MockState,
  MockThreadState,
  mockOutage,
  mockReset,
  mockState,
  ensureHome,
  isTwoColumn,
  typeInto,
  tapTab,
  bringRowToMiddle,
  waitTextOfAny,
  scrollToId,
  openThreadFromHome,
  pairLink,
  pickProjectFilter,
  listToTop,
  startApp,
  startNewChat,
  hideKeyboard,
  pickInFilePicker,
  commandsWithTag,
  tapId,
  waitFor,
  waitForMock,
  waitGone,
  waitId,
  waitText,
  waitTextOf,
  waitConnected,
} from './Support';

/**
 * End-to-end journeys written from the user's point of view, run against tools/mock-t3/server.mjs.
 * Each step drives the real UI (taps, swipes, typing, long presses) and checks what the user sees,
 * then confirms with the mock what the server actually received.
 */
async function checkHandLayout(hand: string): Promise<void> {
  const driver = Driver.create();
  await ensureHome(driver);
  const wide = await isTwoColumn(driver);
  await tapTab(driver, '设置');
  await (await scrollToId(driver, 'settings.scroll', `settings.simulate${hand}`)).click();
  await tapTab(driver, '对话');
  await listToTop(driver);
  const fab = await (await waitId(driver, 'home.newTask')).getBounds();
  const list = await (await waitId(driver, 'home.list')).getBounds();
  const fabOnLeft = (fab.left + fab.right) / 2 < (list.left + list.right) / 2;
  expect(fabOnLeft).assertEqual(!wide && hand === 'Left');
  await openThreadFromHome(driver, 't-inbox');
  const input = await (await waitId(driver, 'composer.input')).getBounds();
  // The action button sits on the right whatever it offers (send, or 补全 for a suggestion).
  const complete = await driver.findComponent(ON.id('composer.complete'));
  const send = complete !== null && complete !== undefined ? await complete.getBounds()
    : await (await waitId(driver, 'composer.send')).getBounds();
  expect((send.left + send.right) / 2 > (input.left + input.right) / 2).assertTrue();
  await backToHome(driver);
}

export default function userJourneyTest() {
  describe('UserJourney', () => {
    const driver: Driver = Driver.create();

    beforeAll(async () => {
      await mockReset();
    });

    it('01_firstLaunchShowsPairingGuide', 0, async () => {
      await startApp('');
      await waitId(driver, 'pair.title', 10000);
      // T3 Connect leads; direct pairing (scan / paste / steps) follows below it.
      await waitId(driver, 'pair.connectSignIn');
      await scrollToId(driver, 'pair.scroll', 'pair.scan');
      await scrollToId(driver, 'pair.scroll', 'pair.paste');
      await driver.assertComponentExist(ON.text('Sharing', MatchPattern.CONTAINS));
    });

    it('02_wrongPairingLinkExplainsTheProblem', 0, async () => {
      await scrollToId(driver, 'pair.scroll', 'pair.input');
      await typeInto(driver, 'pair.input', `${MOCK_HOST}/pair#token=expired-code`);
      await tapId(driver, 'pair.connect');
      await driver.delayMs(1500);
      await scrollToId(driver, 'pair.scroll', 'pair.error');
      const message = await waitTextOf(driver, 'pair.error', '配对失败', 10000);
      expect(message.indexOf('过期') >= 0).assertTrue();
      // Still on the pairing screen, not silently half-connected.
      await waitId(driver, 'pair.connect');
      await driver.assertComponentExist(ON.id('pair.scroll'));
    });

    it('03_scanningTheDesktopQrPairsAndShowsThreads', 0, async () => {
      await startApp(pairLink('mock-pair'));
      await waitConnected(driver, 15000);
      // One dot per computer, no names in the header.
      await waitId(driver, 'home.computer.mock-env');
      // Grouped by project by default, like the desktop sidebar.
      // The first group sits at the top of the list; the others are further down.
      await waitId(driver, 'home.project.p-web');
      await waitText(driver, '重构结账流程');
      await bringRowToMiddle(driver, 'home.project.p-api');
      await bringRowToMiddle(driver, 'home.project.p-docs');
      await listToTop(driver);
      // The first computer is a good moment to ask about notifications.
      await driver.delayMs(800);
      await allowNotifications(driver);
      const state = await mockState();
      expect(state.commands.some((c: MockCommand) => c.tag === 'oauth.token')).assertTrue();
    });

    it('04_searchNarrowsTheListAndClearingRestoresIt', 0, async () => {
      await ensureHome(driver);
      // The system Search field neither clears nor reads back through UiTest, so results are the check.
      await tapId(driver, 'home.searchToggle');
      await typeInto(driver, 'home.searchField', 'loginform', false);
      await waitText(driver, '修复登录页样式');
      await waitGone(driver, ON.id('home.thread.t-failed'));
      // Closing search clears the query and brings everything back.
      await tapId(driver, 'home.searchToggle');
      await waitId(driver, 'home.thread.t-failed');
      await tapId(driver, 'home.searchToggle');
      await typeInto(driver, 'home.searchField', 'zzzz', false);
      await waitId(driver, 'home.emptySearch');
      await tapId(driver, 'home.searchToggle');
      await waitId(driver, 'home.thread.t-failed');
    });

    it('05_projectFilterMenuNarrowsThreads', 0, async () => {
      await ensureHome(driver);
      await pickProjectFilter(driver, 'p-docs');
      await waitText(driver, '项目：docs-site');
      await waitId(driver, 'home.thread.t-long');
      await waitGone(driver, ON.id('home.thread.t-inbox'));
      // The tag under the header clears the filter in one tap.
      await tapId(driver, 'home.filterTag');
      await waitId(driver, 'home.thread.t-inbox');
      await waitGone(driver, ON.id('home.filterTag'));
    });

    it('05b_groupingByProjectOrStatusAndFoldingAProject', 0, async () => {
      await ensureHome(driver);
      await tapId(driver, 'home.filterMenu');
      await tapId(driver, 'home.group.status');
      await waitId(driver, 'home.section.attention');
      await waitId(driver, 'home.section.working');
      // Let the menu finish closing before opening it again (a tap during the fade is swallowed).
      await waitGone(driver, ON.id('home.group.status'));
      await driver.delayMs(400);
      await tapId(driver, 'home.filterMenu');
      await tapId(driver, 'home.group.project');
      await waitGone(driver, ON.id('home.group.project'));
      await (await bringRowToMiddle(driver, 'home.project.p-api')).click();
      // Folding a project hides its conversations; it is remembered until unfolded. Folded, its header
      // carries one dot for the most pressing state (an approval here), like the desktop sidebar.
      await waitGone(driver, ON.id('home.thread.t-approval'));
      await waitId(driver, 'home.projectState.p-api.approval');
      await (await bringRowToMiddle(driver, 'home.project.p-api')).click();
      await waitGone(driver, ON.id('home.projectState.p-api.approval'));
      await bringRowToMiddle(driver, 'home.thread.t-approval');
    });

    it('06_runningThreadStreamsUntilDone', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-running');
      await waitId(driver, 'composer.stop', 4000);
      await waitText(driver, '结账流程已重构完成', 15000);
      await waitGone(driver, ON.id('composer.stop'), 8000);
      await backToHome(driver);
    });

    it('07_sendingAMessageShowsItAndTheReply', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await waitText(driver, '登录页的样式问题已经修好了');
      // The desktop's prompt suggestion: the empty field shows it, send becomes 补全 and fills it in.
      await tapId(driver, 'composer.complete');
      await waitTextOf(driver, 'composer.input', '再检查一下深色模式下的登录页');
      await waitGone(driver, ON.id('composer.complete'));
      // The same button now sends it.
      await tapId(driver, 'composer.send');
      await waitText(driver, '收到：再检查一下深色模式下的登录页', 12000);
      // When the reply is done, the next suggestion arrives for the new run.
      await tapId(driver, 'composer.complete', 10000);
      await waitTextOf(driver, 'composer.input', '好的，把这些改动提交一下');
      const sent = await commandsOfType('message.dispatch');
      expect(sent.length).assertEqual(1);
      expect(sent[0].payload['text'] as string).assertEqual('再检查一下深色模式下的登录页');
      expect(sent[0].payload['creationSource'] as string).assertEqual('mobile');
      // Send that one too: text left in the field would stay as the conversation's draft.
      await tapId(driver, 'composer.send');
      await waitText(driver, '收到：好的，把这些改动提交一下', 12000);
      await backToHome(driver);
    });

    it('07b_attachingAFileAndAPictureFromTheFilePicker', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      // Each pick lands above the field and starts uploading to the computer straight away.
      await tapId(driver, 'composer.attach');
      await tapId(driver, 'composer.attach.files');
      await pickInFilePicker(driver, 'mock-note.txt');
      await waitId(driver, 'composer.file.mock-note.txt', 10000);
      await tapId(driver, 'composer.attach');
      await tapId(driver, 'composer.attach.files');
      await pickInFilePicker(driver, 'mock-screenshot.png');
      await waitId(driver, 'composer.file.mock-screenshot.png', 10000);
      const deadline = Date.now() + 10000;
      while ((await commandsWithTag('attachment.upload')).length < 2 && Date.now() < deadline) {
        await driver.delayMs(300);
      }
      const uploads = await commandsWithTag('attachment.upload');
      expect(uploads.length).assertEqual(2);
      expect(uploads.some((c: MockCommand) => (c.payload['contentType'] as string) === 'image/png')).assertTrue();
      // Sent with the message; the conversation shows the picture and the file card.
      await typeInto(driver, 'composer.input', 'two files');
      await tapId(driver, 'composer.send');
      await waitText(driver, '收到：two files', 12000);
      await waitId(driver, 'message.file.mock-note.txt');
      await waitId(driver, 'message.file.mock-screenshot.png');
      const sent = (await commandsOfType('message.dispatch')).find((c: MockCommand) => (c.payload['text'] as string) === 'two files');
      const files = (sent?.payload['attachments'] ?? []) as Record<string, Object>[];
      expect(files.map((f: Record<string, Object>) => `${f['type']}:${f['name']}`).sort().join(','))
        .assertEqual('file:mock-note.txt,image:mock-screenshot.png');
      await backToHome(driver);
    });

    it('07c_unsentTextStaysAsADraft', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-inbox');
      await typeInto(driver, 'composer.input', 'half a thought');
      await hideKeyboard(driver);
      await backToHome(driver);
      // The list says the conversation has a draft; opening it puts the text back.
      await bringRowToMiddle(driver, 'home.draft.t-inbox');
      await openThreadFromHome(driver, 't-inbox');
      await waitTextOf(driver, 'composer.input', 'half a thought');
      // Sending it ends the draft.
      await tapId(driver, 'composer.send');
      await waitText(driver, '收到：half a thought', 12000);
      await backToHome(driver);
      await waitGone(driver, ON.id('home.draft.t-inbox'));
    });

    it('08_approvingACommandUnblocksTheAgent', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-approval');
      await waitText(driver, 'pnpm up --latest');
      await tapId(driver, 'approval.accept');
      await waitText(driver, '已获批准，正在执行。', 10000);
      await waitText(driver, '已处理');
      await waitGone(driver, ON.id('approval.accept'));
      const responses = await commandsOfType('runtime-request.respond');
      expect(responses[0].payload['decision'] as string).assertEqual('accept');
      expect(responses[0].payload['requestId'] as string).assertEqual('req-approve');
      await backToHome(driver);
    });

    it('09_answeringAQuestionWithOneTap', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-question');
      await tapId(driver, 'question.option.PostgreSQL');
      await waitText(driver, '问题已回答', 10000);
      await waitText(driver, '好的，使用 PostgreSQL。', 10000);
      const responses = await commandsOfType('runtime-request.respond');
      const answers = responses[responses.length - 1].payload['answers'] as Record<string, Object>;
      expect(answers['q-db'] as string).assertEqual('PostgreSQL');
      await backToHome(driver);
    });

    it('09b_answeringSeveralQuestionsPageByPage', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-plan');
      // One question per page, with where you are on top.
      await waitTextOf(driver, 'question.page', '1 / 3');
      await waitText(driver, '这次发布包含哪些部分？');
      expect(await driver.findComponent(ON.text('什么时候上线？'))).assertNull();
      // Several choices: pick two, then move on.
      await tapId(driver, 'question.option.API 参考');
      await tapId(driver, 'question.option.教程');
      await tapId(driver, 'question.next');
      await waitTextOf(driver, 'question.page', '2 / 3');
      await waitText(driver, '什么时候上线？');
      expect(await driver.findComponent(ON.text('这次发布包含哪些部分？'))).assertNull();
      // Swipe back to look again (the choices are kept), and forward.
      const body = await (await waitId(driver, 'question.body')).getBounds();
      const y = Math.round((body.top + body.bottom) / 2);
      await driver.swipe(body.left + 30, y, body.right - 30, y, 2000);
      await waitTextOf(driver, 'question.page', '1 / 3');
      await driver.swipe(body.right - 30, y, body.left + 30, y, 2000);
      await waitTextOf(driver, 'question.page', '2 / 3');
      // A single choice moves on by itself; the last page waits for 提交回答.
      await tapId(driver, 'question.option.今晚');
      await waitTextOf(driver, 'question.page', '3 / 3');
      await tapId(driver, 'question.option.只通知团队');
      await driver.delayMs(600);
      expect((await commandsOfType('runtime-request.respond')).some((c: MockCommand) =>
        (c.payload['requestId'] as string) === 'req-plan')).assertFalse();
      await tapId(driver, 'question.submit');
      await waitText(driver, '问题已回答', 10000);
      const responses = (await commandsOfType('runtime-request.respond')).filter((c: MockCommand) =>
        (c.payload['requestId'] as string) === 'req-plan');
      const answers = responses[responses.length - 1].payload['answers'] as Record<string, Object>;
      expect((answers['q-scope'] as string[]).join(',')).assertEqual('API 参考,教程');
      expect(answers['q-when'] as string).assertEqual('今晚');
      expect(answers['q-notify'] as string).assertEqual('只通知团队');
      await backToHome(driver);
    });

    it('10_stoppingALongTask', 0, async () => {
      await ensureHome(driver);
      await openThreadFromHome(driver, 't-long');
      await tapId(driver, 'composer.stop');
      await waitText(driver, '任务已按你的要求停止', 8000);
      await waitGone(driver, ON.id('composer.stop'));
      expect((await commandsOfType('thread.stop')).length).assertEqual(1);
      await backToHome(driver);
    });

    it('11_creatingANewTaskEndToEnd', 0, async () => {
      await ensureHome(driver);
      // As on the desktop: pick the project, and an empty conversation opens in it.
      await startNewChat(driver, 'p-docs', 'docs-site');
      // Harness / model / reasoning in three columns, plan mode and permission underneath.
      await tapId(driver, 'composer.model');
      await tapId(driver, 'runSettings.model.claudeAgent.claude-sonnet-5-5');
      await waitId(driver, 'runSettings.option.effort');
      await tapId(driver, 'runSettings.option.effort.xhigh');
      await tapId(driver, 'runSettings.runtime');
      await tapId(driver, 'runSettings.runtime.approval-required');
      await driver.delayMs(600);
      // Close the sheet (a back press right after the menu closes can be swallowed).
      for (let i = 0; i < 3 && await driver.findComponent(ON.id('runSettings.sheet')) !== null; i++) {
        await driver.pressBack();
        await driver.delayMs(700);
      }
      await waitTextOf(driver, 'composer.model.value', 'Sonnet 5.5 · 超高');
      // The first message starts the conversation, and this same page becomes it.
      await typeInto(driver, 'composer.input', 'docs search');
      await tapId(driver, 'composer.send');
      await waitTextOf(driver, 'thread.title', 'docs search', 10000);
      await waitText(driver, '好的，我已经开始处理这个任务了。', 12000);
      await waitGone(driver, ON.id('draft.project'));
      const state = await mockState();
      const launch = state.commands.find((c: MockCommand) => c.tag === 'orchestration.launchThread');
      expect(launch !== undefined).assertTrue();
      expect((launch as MockCommand).payload['projectId'] as string).assertEqual('p-docs');
      expect((launch as MockCommand).payload['runtimeMode'] as string).assertEqual('approval-required');
      const model = (launch as MockCommand).payload['modelSelection'] as Record<string, Object>;
      expect(model['model'] as string).assertEqual('claude-sonnet-5-5');
      expect(JSON.stringify(model['options'])).assertContain('xhigh');
      await backToHome(driver);
    });

    it('12_swipeToArchive', 0, async () => {
      await ensureHome(driver);
      const row = await bringRowToMiddle(driver, 'home.thread.t-failed');
      const bounds = await row.getBounds();
      const y = Math.round((bounds.top + bounds.bottom) / 2);
      // Start well inside the screen: a swipe from the edge opens the system side dock instead.
      const width = bounds.right - bounds.left;
      await driver.swipe(bounds.left + Math.round(width * 0.72), y, bounds.left + Math.round(width * 0.18), y, 1600);
      await tapId(driver, 'home.swipe.archive.t-failed');
      await waitGone(driver, ON.id('home.thread.t-failed'));
      await waitForMock((s: MockState) => s.threads.some((t: MockThreadState) => t.id === 't-failed' && t.archivedAt !== null));
    });

    it('13_longPressMenuPinsAThread', 0, async () => {
      await ensureHome(driver);
      const row = await bringRowToMiddle(driver, 'home.thread.t-inbox');
      await row.longClick();
      const pin = await waitFor(driver, ON.text('置顶'), 8000, 'menu:置顶');
      await pin.click();
      await waitForMock((s: MockState) => s.threads.some((t: MockThreadState) => t.id === 't-inbox' && t.pinnedAt !== null));
    });

    it('14_recoversAfterTheComputerGoesAway', 0, async () => {
      await ensureHome(driver);
      await mockOutage(2500);
      // The header must say the link dropped (not stay silently green), then recover by itself.
      await waitTextOfAny(driver, 'home.connection', ['重新连接', '离线', '正在连接'], 8000);
      await waitConnected(driver, 20000);
      await waitId(driver, 'home.thread.t-inbox');
    });

    // Send / stop is always on the composer's right. The new-conversation button sits in the
    // holding hand's corner on one screen, and the list column's bottom-right when unfolded. One hand per test keeps
    // each under the runner's time limit.
    it('15a_leftHand', 0, async () => {
      await checkHandLayout('Left');
    });

    it('15b_rightHand', 0, async () => {
      await checkHandLayout('Right');
    });

    it('17_unfoldedScreenShowsListAndConversationSideBySide', 0, async () => {
      await ensureHome(driver);
      if (!(await isTwoColumn(driver))) {
        // Phones and folded screens keep the single-column flow covered above.
        return;
      }
      await openThreadFromHome(driver, 't-question');
      // Both columns at once: the list stays put and the conversation fills the right pane.
      await waitId(driver, 'home.list');
      await waitText(driver, '帮我规划账单表的迁移');
      const list = await (await waitId(driver, 'home.list')).getBounds();
      const title = await (await waitId(driver, 'thread.title')).getBounds();
      expect(title.left >= list.right - 2).assertTrue();
      await waitGone(driver, ON.id('thread.back'));
      // Picking another thread swaps the pane in place instead of stacking pages.
      await openThreadFromHome(driver, 't-inbox');
      await waitTextOf(driver, 'thread.title', '修复登录页样式');
      // A new conversation opens in the pane, next to the list; picking a thread brings it back.
      await startNewChat(driver, 'p-docs', 'docs-site');
      await waitId(driver, 'home.list');
      await openThreadFromHome(driver, 't-inbox');
      await waitTextOf(driver, 'thread.title', '修复登录页样式');
      // Usage and Settings open in the list column: the conversation pane stays exactly where it was.
      for (const tab of ['用量', '设置']) {
        await tapTab(driver, tab);
        await driver.delayMs(500);
        const pane = await (await waitId(driver, 'thread.title')).getBounds();
        expect(Math.abs(pane.left - title.left) <= 2).assertTrue();
      }
      const settings = await (await waitId(driver, 'settings.scroll')).getBounds();
      expect(settings.right <= list.right + 2).assertTrue();
      await tapTab(driver, '对话');
      await waitId(driver, 'home.list');
    });

    it('16_appearanceSwitchesWithoutLosingState', 0, async () => {
      await ensureHome(driver);
      await tapTab(driver, '设置');
      // A choice row: tap it, pick from its light-material menu.
      for (const value of ['dark', 'light', 'system']) {
        await (await scrollToId(driver, 'settings.scroll', 'settings.appearance')).click();
        await tapId(driver, `settings.appearance.${value}`);
        await driver.delayMs(600);
      }
      await tapTab(driver, '对话');
      await waitConnected(driver);
    });

    it('18_secondComputerJoinsTheSameList', 0, async () => {
      await labReset();
      await ensureHome(driver);
      // Add another computer from Settings; the first one stays connected.
      await tapTab(driver, '设置');
      await (await scrollToId(driver, 'settings.scroll', 'settings.addComputer')).click();
      await scrollToId(driver, 'pair.scroll', 'pair.input');
      await typeInto(driver, 'pair.input', labPairLink());
      await tapId(driver, 'pair.connect');

      // One list for both: each computer's status in the header, its name on its rows.
      await waitId(driver, 'home.computers', 15000);
      await waitId(driver, 'home.computer.lab-env');
      await waitId(driver, 'home.computer.mock-env');
      // Grouped by project: a project with the same name on both computers is one group, and rows
      // under a project header do not name the computer (the conversation shows it).
      await bringRowToMiddle(driver, 'home.thread.l-inbox');
      await bringRowToMiddle(driver, 'home.thread.l-web');
      expect(await driver.findComponent(ON.id('home.project.p-lab-web'))).assertNull();
      // The merged group is the most recent one, at the top of the list.
      await listToTop(driver);
      await waitId(driver, 'home.project.p-web');
      // (Within the list: an open conversation beside it still names its computer.)
      expect(await driver.findComponent(ON.text('实验室服务器 · ', MatchPattern.CONTAINS).within(ON.id('home.list')))).assertNull();
      expect(await driver.findComponent(ON.text('Mock 工作站 · ', MatchPattern.CONTAINS).within(ON.id('home.list')))).assertNull();

      // A new conversation in that project asks which computer: start it on the lab.
      await startNewChat(driver, 'p-web', 'storefront-web');
      await waitId(driver, 'draft.env.mock-env');
      await tapId(driver, 'draft.env.lab-env');
      const onMainBefore = (await commandsWithTag('orchestration.launchThread')).length;
      await typeInto(driver, 'composer.input', 'lab load test');
      await tapId(driver, 'composer.send');
      await waitTextOf(driver, 'thread.title', 'lab load test', 10000);
      const launched = await commandsWithTag('orchestration.launchThread', LAB_HOST);
      expect(launched.some((c: MockCommand) => (c.payload['projectId'] as string) === 'p-lab-web')).assertTrue();
      expect((await commandsWithTag('orchestration.launchThread')).length).assertEqual(onMainBefore);
      await backToHome(driver);

      // Narrow to one computer, then back to everything.
      await listToTop(driver);
      await pickProjectFilter(driver, 'env.lab-env');
      await waitText(driver, '电脑：实验室服务器');
      await waitId(driver, 'home.thread.l-running');
      await waitGone(driver, ON.id('home.thread.t-running'));
      await tapId(driver, 'home.filterTag');
      await waitId(driver, 'home.thread.t-running');
    });

    it('18b_voiceInputTranscribesOnTheChosenComputer', 0, async () => {
      await ensureHome(driver);
      await tapTab(driver, '设置');
      await (await scrollToId(driver, 'settings.scroll', 'settings.voice')).click();
      // Every computer that can transcribe: with its own model, or a cloud service it holds a key for.
      await waitId(driver, 'voice.dest.off');
      await waitId(driver, 'voice.dest.mock-env.local');
      await waitId(driver, 'voice.dest.mock-env.openai');
      await waitId(driver, 'voice.dest.mock-env.openrouter');
      expect(await driver.findComponent(ON.id('voice.dest.mock-env.xai'))).assertNull();
      expect(await driver.findComponent(ON.id('voice.dest.lab-env.local'))).assertNull();
      await tapId(driver, 'voice.dest.mock-env.local');

      // The models on that computer: switch to another, then download one (it becomes the one used).
      await tapId(driver, 'voice.model.mock/whisper-small', 10000);
      await waitForMock((s: MockState) => s.commands.some((c: MockCommand) => c.tag === 'voice.select' &&
        (c.payload['modelId'] as string) === 'mock/whisper-small'));
      await (await scrollToId(driver, 'voice.scroll', 'voice.more')).click();
      await (await scrollToId(driver, 'voice.scroll', 'voice.download.mock/qwen3-asr')).click();
      await waitTextOf(driver, 'dialog.title', 'Qwen3-ASR');
      await tapId(driver, 'dialog.confirm');
      await waitForMock((s: MockState) => s.commands.some((c: MockCommand) => c.tag === 'voice.select' &&
        (c.payload['modelId'] as string) === 'mock/qwen3-asr'), 15000);
      await waitId(driver, 'voice.model.mock/qwen3-asr');
      // The language list is the chosen model's.
      await (await scrollToId(driver, 'voice.scroll', 'voice.language')).click();
      await tapId(driver, 'voice.language.zh');
      await waitText(driver, '中文');
      await tapId(driver, 'page.back');
      await waitTextOf(driver, 'settings.voice.value', 'Mock 工作站 · 本机模型');
      await tapTab(driver, '对话');

      // Record in a conversation; the words land in the field.
      await startNewChat(driver, 'p-docs', 'docs-site');
      await tapId(driver, 'composer.mic');
      await allowMicrophone(driver);
      await waitId(driver, 'composer.voice.done', 8000);
      await driver.delayMs(1200);
      await waitTextOf(driver, 'composer.voice.time', '0:01');
      await tapId(driver, 'composer.voice.done');
      await waitTextOf(driver, 'composer.input', '把登录页的按钮改成蓝色', 10000);
      const local = await commandsWithTag('voice.transcribe');
      expect(local.length).assertEqual(1);
      expect(local[0].payload['destination'] as string).assertEqual('local');
      expect(local[0].payload['model'] as string).assertEqual('mock/qwen3-asr');
      expect(local[0].payload['jsonPaddedTo4'] as boolean).assertTrue();
      expect(local[0].payload['contentType'] as string).assertEqual('application/octet-stream');
      expect((local[0].payload['seconds'] as number) > 0.5).assertTrue();
      const options = local[0].payload['options'] as Record<string, Object>;
      expect(options['speechLanguage'] as string).assertEqual('zh');
      expect(options['speechRemoveFillerWords'] as boolean).assertTrue();
      // Cancelling sends nothing.
      await tapId(driver, 'composer.mic');
      await waitId(driver, 'composer.voice.done', 8000);
      await tapId(driver, 'composer.voice.cancel');
      await waitGone(driver, ON.id('composer.voice.done'));
      await driver.delayMs(500);
      expect((await commandsWithTag('voice.transcribe')).length).assertEqual(1);

      // A cloud service through the same computer, with an OpenRouter model and cleanup.
      await ensureHome(driver);
      await tapTab(driver, '设置');
      await (await scrollToId(driver, 'settings.scroll', 'settings.voice')).click();
      await tapId(driver, 'voice.dest.mock-env.openrouter');
      await tapId(driver, 'voice.cloudModel.google/gemini-2.5-flash', 10000);
      await (await scrollToId(driver, 'voice.scroll', 'voice.cleanup')).click();
      await tapId(driver, 'page.back');
      await waitTextOf(driver, 'settings.voice.value', 'OpenRouter');
      await tapTab(driver, '对话');
      await startNewChat(driver, 'p-docs', 'docs-site');
      await tapId(driver, 'composer.mic');
      await allowMicrophone(driver);
      await waitId(driver, 'composer.voice.done', 8000);
      await driver.delayMs(1000);
      await tapId(driver, 'composer.voice.done');
      await waitTextOf(driver, 'composer.input', '用云端转写的一句话。', 10000);
      const cloud = (await commandsWithTag('voice.transcribe'))[1];
      expect(cloud.payload['destination'] as string).assertEqual('openrouter');
      expect(cloud.payload['model'] as string).assertEqual('google/gemini-2.5-flash');
      const cleaned = await commandsWithTag('voice.postProcess');
      expect(cleaned[0].payload['transcript'] as string).assertEqual('用云端转写的一句话');

      // Off again: the mic leaves the composer.
      await ensureHome(driver);
      await tapTab(driver, '设置');
      await (await scrollToId(driver, 'settings.scroll', 'settings.voice')).click();
      await (await scrollToId(driver, 'voice.scroll', 'voice.cleanup')).click();
      await (await scrollToId(driver, 'voice.scroll', 'voice.dest.off')).click();
      await tapId(driver, 'page.back');
      await waitTextOf(driver, 'settings.voice.value', '关闭');
      await tapTab(driver, '对话');
    });

    it('19_eachComputerGetsItsOwnCommandsAndCanBeRemoved', 0, async () => {
      await ensureHome(driver);
      await waitId(driver, 'home.computer.lab-env', 10000);
      // A message in a thread from the second computer goes to that computer only.
      await openThreadFromHome(driver, 'l-inbox');
      await waitText(driver, '已清理 37 个镜像');
      await typeInto(driver, 'composer.input', 'clear cache');
      await tapId(driver, 'composer.send');
      await waitText(driver, '收到：clear cache', 12000);
      const onLab = await commandsOfType('message.dispatch', LAB_HOST);
      expect(onLab.some((c: MockCommand) => (c.payload['text'] as string) === 'clear cache')).assertTrue();
      const onMain = await commandsOfType('message.dispatch');
      expect(onMain.some((c: MockCommand) => (c.payload['text'] as string) === 'clear cache')).assertFalse();
      await backToHome(driver);

      // Removing it takes only its threads away.
      await tapTab(driver, '设置');
      await (await scrollToId(driver, 'settings.scroll', 'settings.computer.lab-env')).click();
      await tapId(driver, 'settings.computer.remove.lab-env');
      // Removing asks first, on a light-material dialog.
      await waitTextOf(driver, 'dialog.title', '实验室服务器');
      await tapId(driver, 'dialog.confirm');
      // Let the dialog finish closing before tapping the tab bar behind it.
      await waitGone(driver, ON.id('dialog.confirm'));
      await driver.delayMs(600);
      await tapTab(driver, '对话');
      await listToTop(driver);
      await waitConnected(driver);
      await waitGone(driver, ON.id('home.thread.l-running'));
      await waitId(driver, 'home.thread.t-running');
      // Its conversation that was open is closed too, not left talking to a computer that is gone.
      await waitGone(driver, ON.text('已清理 37 个镜像', MatchPattern.CONTAINS));
    });
  });
}
