import { http } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { abilityDelegatorRegistry, Component, Driver, MatchPattern, ON, On, UiWindow } from '@kit.TestKit';

/** The mock T3 server runs on the development machine; 10.0.2.2 is the host as seen from the emulator. */
export const MOCK_HOST: string = 'http://10.0.2.2:3790';
/** A second mock computer ("实验室服务器", `--profile lab`) for the multi-computer journey. */
export const LAB_HOST: string = 'http://10.0.2.2:3791';
export const BUNDLE: string = 'com.ewhen.t3code';

export interface MockCommand {
  tag: string;
  payload: Record<string, Object>;
}

export interface MockThreadState {
  id: string;
  status: string;
  archivedAt: string | null;
  pinnedAt: string | null;
  settledAt: string | null;
  snoozedUntil?: string | null;
  title?: string;
}

export interface MockState {
  commands: MockCommand[];
  threads: MockThreadState[];
}

async function request(method: http.RequestMethod, path: string, host: string = MOCK_HOST): Promise<string> {
  const client = http.createHttp();
  try {
    const res = await client.request(`${host}${path}`, {
      method: method,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 5000,
      readTimeout: 5000,
    });
    return res.result as string;
  } finally {
    client.destroy();
  }
}

export async function mockReset(): Promise<void> {
  await request(http.RequestMethod.POST, '/__test/reset');
}

export async function mockOutage(ms: number): Promise<void> {
  await request(http.RequestMethod.POST, `/__test/outage?ms=${ms}`);
}

export async function mockState(): Promise<MockState> {
  return JSON.parse(await request(http.RequestMethod.GET, '/__test/state')) as MockState;
}

/** Calls the mock recorded under an RPC tag (launchThread, attachment uploads...). */
export async function commandsWithTag(tag: string, host: string = MOCK_HOST): Promise<MockCommand[]> {
  const state = JSON.parse(await request(http.RequestMethod.GET, '/__test/state', host)) as MockState;
  return state.commands.filter((c: MockCommand) => c.tag === tag);
}

export async function commandsOfType(type: string, host: string = MOCK_HOST): Promise<MockCommand[]> {
  const state = JSON.parse(await request(http.RequestMethod.GET, '/__test/state', host)) as MockState;
  return state.commands.filter((c: MockCommand) => (c.payload['type'] as string) === type);
}

/** Requests the mock logged by RPC name (git, terminal, pull request actions). */
export async function callsOf(tag: string, host: string = MOCK_HOST): Promise<MockCommand[]> {
  const state = JSON.parse(await request(http.RequestMethod.GET, '/__test/state', host)) as MockState;
  return state.commands.filter((c: MockCommand) => c.tag === tag);
}

export async function labReset(): Promise<void> {
  await request(http.RequestMethod.POST, '/__test/reset', LAB_HOST);
}

/** Pairing link of the second mock computer. */
export function labPairLink(): string {
  return `${LAB_HOST}/pair#token=mock-pair`;
}

export interface MockConnectEntry {
  tag: string;
  payload: Record<string, Object>;
}

export interface MockConnectState {
  pending: number;
  approved: number;
  envTokens: number;
  log: MockConnectEntry[];
}

export async function mockConnectState(): Promise<MockConnectState> {
  return JSON.parse(await request(http.RequestMethod.GET, '/__test/connect/state')) as MockConnectState;
}

/** Plays the person at the computer pressing "Approve" for every waiting device. */
export async function mockConnectApprove(): Promise<void> {
  await request(http.RequestMethod.POST, '/__test/connect/approve');
}

/** Expires every T3 Connect environment token, as if the app had been away for a while. */
export async function mockConnectExpire(): Promise<void> {
  await request(http.RequestMethod.POST, '/__test/connect/expire');
}

export async function mockDrop(): Promise<void> {
  await request(http.RequestMethod.POST, '/__test/drop');
}

export function connectEntries(state: MockConnectState, tag: string): MockConnectEntry[] {
  return state.log.filter((e: MockConnectEntry) => e.tag === tag);
}

/** Debug-only link that points T3 Connect (Clerk + relay) at the mock deployment. */
export function devConnectLink(): string {
  return `t3code://dev-connect?fapi=${encodeURIComponent(`${MOCK_HOST}/__clerk`)}&relay=${encodeURIComponent(`${MOCK_HOST}/__relay`)}`;
}

/**
 * The emulator's stock input method shows a privacy prompt the first times its keyboard opens.
 * Dismiss it without agreeing to anything, so typing reaches the app.
 */
export async function dismissImePrompt(driver: Driver): Promise<void> {
  for (let i = 0; i < 3; i++) {
    const exit = await driver.findComponent(ON.text('退出应用', MatchPattern.EQUALS));
    if (exit !== null && exit !== undefined) {
      await exit.click();
      await driver.delayMs(600);
      continue;
    }
    const prompt = await driver.findComponent(ON.text('小艺输入法', MatchPattern.EQUALS));
    const cancel = await driver.findComponent(ON.text('取消', MatchPattern.EQUALS));
    if (prompt === null || prompt === undefined || cancel === null || cancel === undefined) {
      return;
    }
    await cancel.click();
    await driver.delayMs(600);
  }
}

/**
 * Closes the soft keyboard if it is open. While the input method's window is up, UiTest only sees
 * that window, so the next lookup of an app control would miss. Back is only pressed when the
 * keyboard is really there, so it never navigates away by accident.
 */
async function keyboardShown(driver: Driver): Promise<boolean> {
  try {
    const ime: UiWindow | undefined = await driver.findWindow({ bundleName: 'com.huawei.hmos.inputmethod' });
    if (ime === null || ime === undefined) {
      return false;
    }
    const b = await ime.getBounds();
    const size = await driver.getDisplaySize();
    return b.bottom > b.top && b.top < size.y;
  } catch (e) {
    return false;
  }
}

/**
 * Puts the keyboard away with a single Back, then waits for it to leave. Never presses Back twice:
 * the IME window can linger while it animates out, and a second Back would close the app.
 */
export async function hideKeyboard(driver: Driver): Promise<void> {
  if (!(await keyboardShown(driver))) {
    return;
  }
  await driver.pressBack();
  for (let i = 0; i < 10; i++) {
    await driver.delayMs(200);
    if (!(await keyboardShown(driver))) {
      return;
    }
  }
}

/**
 * UiTest pastes, instead of typing, any text with Chinese or special characters or over 200 characters,
 * and the emulator shares its clipboard with the computer: that would overwrite whatever the person
 * running the tests has copied. Tests therefore only type plain ASCII.
 */
function assertTypedWithoutClipboard(text: string): void {
  if (text.length > 200 || !/^[\x20-\x7E]*$/.test(text)) {
    throw new Error(`Would go through the clipboard, use plain ASCII: ${text}`);
  }
}

/** Types into a field the way a person would, recovering if the keyboard's first-run prompt interrupts. */
export async function typeInto(driver: Driver, id: string, text: string, readBack: boolean = true): Promise<void> {
  assertTypedWithoutClipboard(text);
  for (let attempt = 0; attempt < 3; attempt++) {
    const field = await waitId(driver, id);
    await field.click();
    await driver.delayMs(500);
    await dismissImePrompt(driver);
    try {
      await field.clearText();
      await field.inputText(text);
    } catch (e) {
      // Unfolded emulator: the keyboard window reports portrait bounds covering the whole screen, so
      // UiTest treats the field as hidden. Put the keyboard away and type by position instead.
      await hideKeyboard(driver);
      const b = await (await waitId(driver, id)).getBounds();
      await driver.inputText({ x: Math.round((b.left + b.right) / 2), y: Math.round((b.top + b.bottom) / 2) }, text);
    }
    await driver.delayMs(300);
    await dismissImePrompt(driver);
    await hideKeyboard(driver);
    if (!readBack) {
      return;
    }
    const now = await (await waitId(driver, id)).getText();
    if (now === text) {
      return;
    }
  }
  throw new Error(`Could not type into ${id} (screenshot ${await failureShot(driver, `type-${id}`)})`);
}

export function pairLink(code: string): string {
  return `t3code://pair?pairingUrl=${encodeURIComponent(`${MOCK_HOST}/pair#token=${code}`)}`;
}

/** Launches (or brings forward) the app, optionally with a deep link, like tapping a QR result. */
export async function startApp(uri: string): Promise<void> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const want: Want = { bundleName: BUNDLE, abilityName: 'EntryAbility' };
  if (uri.length > 0) {
    want.uri = uri;
  }
  await delegator.startAbility(want);
}

let shotIndex = 0;

/** Saves a screenshot into the app sandbox so a failing step can be inspected from the host. */
export async function failureShot(driver: Driver, label: string): Promise<string> {
  try {
    const dir = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().filesDir;
    const path = `${dir}/fail-${++shotIndex}-${label.replace(/[^A-Za-z0-9._-]/g, '_').substring(0, 40)}.png`;
    await driver.screenCap(path);
    return path;
  } catch (e) {
    return '(no screenshot)';
  }
}

export async function waitFor(driver: Driver, on: On, timeoutMs: number = 8000, label: string = 'component'): Promise<Component> {
  const found = await driver.waitForComponent(on, timeoutMs);
  if (found === null || found === undefined) {
    const shot = await failureShot(driver, label);
    throw new Error(`Timed out waiting for ${label} (screenshot ${shot})`);
  }
  return found;
}

export async function waitId(driver: Driver, id: string, timeoutMs: number = 8000): Promise<Component> {
  return waitFor(driver, ON.id(id), timeoutMs, `id:${id}`);
}

/**
 * The home header shows one dot per computer; its id carries the phase ("…mock-env.connected").
 * Adding the first computer asks for notification permission, and that system prompt hides the app
 * from UiTest, so it is answered while waiting.
 */
export async function waitConnected(driver: Driver, timeoutMs: number = 8000): Promise<Component> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await allowNotifications(driver);
    const dot = await driver.findComponent(ON.id('.connected', MatchPattern.ENDS_WITH));
    if (dot !== null && dot !== undefined) {
      return dot;
    }
    await driver.delayMs(400);
  }
  return waitFor(driver, ON.id('.connected', MatchPattern.ENDS_WITH), 1000, 'computer connected');
}

export async function waitText(driver: Driver, text: string, timeoutMs: number = 8000): Promise<Component> {
  return waitFor(driver, ON.text(text, MatchPattern.CONTAINS), timeoutMs, `text:${text}`);
}

export async function tapId(driver: Driver, id: string, timeoutMs: number = 8000): Promise<void> {
  const component = await waitId(driver, id, timeoutMs);
  try {
    await component.click();
  } catch (e) {
    // Replaced between finding and tapping (a page swapped in the pane): tap the new one.
    await driver.delayMs(300);
    await (await waitId(driver, id, timeoutMs)).click();
  }
}

/**
 * Picks a file in the system file picker: straight from 最近 when it is listed there, else through
 * 浏览 › 我的手机 › Download (where test-e2e.ps1 puts the fixtures).
 */
export async function pickInFilePicker(driver: Driver, fileName: string): Promise<void> {
  await waitText(driver, '浏览', 10000);
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline) {
    const recent = await driver.findComponent(ON.text(fileName, MatchPattern.EQUALS));
    if (recent !== null && recent !== undefined) {
      await recent.click();
      return;
    }
    await driver.delayMs(250);
  }
  await (await waitText(driver, '浏览')).click();
  await (await waitText(driver, '我的手机')).click();
  await (await waitText(driver, 'Download')).click();
  await (await waitText(driver, fileName)).click();
}

/** Polls until the matcher no longer finds anything. */
export async function waitGone(driver: Driver, on: On, timeoutMs: number = 8000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await driver.findComponent(on);
    if (found === null || found === undefined) {
      return;
    }
    await driver.delayMs(250);
  }
  throw new Error(`Still present after ${timeoutMs}ms: ${JSON.stringify(on)}`);
}

/** Polls a component's text until it contains the expected fragment. */
export async function waitTextOf(driver: Driver, id: string, fragment: string, timeoutMs: number = 10000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    const found = await driver.findComponent(ON.id(id));
    if (found !== null && found !== undefined) {
      try {
        last = await found.getText();
      } catch (e) {
        last = ''; // replaced while reading (a page swapped in the pane): look again
      }
      if (last.indexOf(fragment) >= 0) {
        return last;
      }
    }
    await driver.delayMs(250);
  }
  throw new Error(`"${id}" never contained "${fragment}" (last: "${last}", screenshot ${await failureShot(driver, `textOf-${id}`)})`);
}

/** Polls the mock until a predicate over its state holds. */
export async function waitForMock(predicate: (state: MockState) => boolean, timeoutMs: number = 6000): Promise<MockState> {
  const deadline = Date.now() + timeoutMs;
  let state = await mockState();
  while (Date.now() < deadline) {
    if (predicate(state)) {
      return state;
    }
    await new Promise<void>((resolve: () => void) => setTimeout(resolve, 250));
    state = await mockState();
  }
  throw new Error(`Mock never reached the expected state: ${JSON.stringify(state.commands.slice(-3))}`);
}

export async function openThreadFromHome(driver: Driver, threadId: string): Promise<void> {
  await waitId(driver, 'home.list');
  // Rows can exist in the tree while sitting below the fold or under the floating tab bar.
  const row = await bringRowToMiddle(driver, `home.thread.${threadId}`);
  await row.click();
  await waitId(driver, 'thread.title', 8000);
}

/** Back to the list. In the two-column layout the list never left the screen, so there is nothing to tap. */
export async function backToHome(driver: Driver): Promise<void> {
  const back = await driver.findComponent(ON.id('thread.back'));
  if (back !== null && back !== undefined) {
    await back.click();
  }
  await waitId(driver, 'home.list');
}

/** True when the app shows list and conversation side by side (unfolded foldable, tablet). */
export async function isTwoColumn(driver: Driver): Promise<boolean> {
  const placeholder = await driver.findComponent(ON.id('detail.placeholder'));
  if (placeholder !== null && placeholder !== undefined) {
    return true;
  }
  const list = await driver.findComponent(ON.id('home.list'));
  const title = await driver.findComponent(ON.id('thread.title'));
  return list !== null && list !== undefined && title !== null && title !== undefined;
}

/** Accepts the system "allow notifications" prompt the app shows after the first computer connects. */
export async function allowNotifications(driver: Driver): Promise<void> {
  const prompt = await driver.findComponent(ON.text('发送通知', MatchPattern.CONTAINS));
  if (prompt === null || prompt === undefined) {
    return;
  }
  const allow = await driver.findComponent(ON.text('允许', MatchPattern.EQUALS));
  if (allow !== null && allow !== undefined) {
    await allow.click();
    await driver.delayMs(600);
  }
}

/** Accepts the system microphone prompt if it shows (the first recording after a fresh install). */
export async function allowMicrophone(driver: Driver): Promise<void> {
  for (let i = 0; i < 16; i++) {
    const recording = await driver.findComponent(ON.id('composer.voice.done'));
    if (recording !== null && recording !== undefined) {
      return;
    }
    for (const label of ['仅使用期间允许', '本次使用允许', '允许']) {
      const button = await driver.findComponent(ON.text(label, MatchPattern.EQUALS));
      if (button !== null && button !== undefined) {
        await button.click();
        await driver.delayMs(600);
        return;
      }
    }
    await driver.delayMs(300);
  }
}

/** New conversation: the round button beside the floating tab bar, in every layout. */
export async function tapNewTask(driver: Driver): Promise<void> {
  await tapId(driver, 'home.newTask');
}

/** New conversation as on the desktop: the compose button, then the project; the empty conversation opens. */
export async function startNewChat(driver: Driver, projectId: string, projectTitle: string): Promise<void> {
  await tapNewTask(driver);
  await waitId(driver, 'newChat.list');
  await tapId(driver, `newChat.project.${projectId}`);
  await waitTextOf(driver, 'draft.project', projectTitle);
  await waitGone(driver, ON.id('newChat.list'));
}

/** Picks a project in the header's filter menu; '' picks 全部项目. */
export async function pickProjectFilter(driver: Driver, projectId: string): Promise<void> {
  await tapId(driver, 'home.filterMenu');
  await tapId(driver, projectId.length > 0 ? `home.filter.${projectId}` : 'home.filter.all');
  await driver.delayMs(400);
}

/** Returns to the thread list from wherever a previous step left the app (sheet, page, settings tab). */
export async function ensureHome(driver: Driver): Promise<void> {
  const present = async (id: string): Promise<boolean> => {
    const found = await driver.findComponent(ON.id(id));
    return found !== null && found !== undefined;
  };
  // A keyboard left open by a failed step hides the whole app from UiTest.
  await hideKeyboard(driver);
  await allowNotifications(driver);
  if (!(await present('home.list')) && !(await present('thread.back')) && !(await present('page.back'))) {
    await startApp('');
    await driver.delayMs(800);
  }
  for (let i = 0; i < 4; i++) {
    if (await present('newChat.list') || await present('runSettings.sheet')) {
      await driver.pressBack();
      await driver.delayMs(600);
      continue;
    }
    const backId = (await present('thread.back')) ? 'thread.back' : ((await present('page.back')) ? 'page.back' : '');
    if (backId.length === 0) {
      break;
    }
    await (await driver.findComponent(ON.id(backId))).click();
    await waitGone(driver, ON.id(backId), 4000);
  }
  await tapTab(driver, '对话');
  await waitId(driver, 'home.list', 8000);
  // A failed step may leave a search or project filter behind; every journey starts from the full list.
  if (await present('home.searchField')) {
    await tapId(driver, 'home.searchToggle');
    await waitGone(driver, ON.id('home.searchField'), 4000);
  }
  if (await present('home.filterTag')) {
    await tapId(driver, 'home.filterTag');
    await waitGone(driver, ON.id('home.filterTag'), 4000);
  }
  await listToTop(driver);
}

/**
 * Back to the top of the thread list with a few quick flicks on the list column.
 * (Component.scrollToTop() can hang and wedge UiTest for every later step.)
 */
export async function listToTop(driver: Driver): Promise<void> {
  const list = await (await waitId(driver, 'home.list', 8000)).getBounds();
  const x = Math.round(list.left + (list.right - list.left) * 0.45);
  const top = list.top + Math.round((list.bottom - list.top) * 0.25);
  const bottom = list.top + Math.round((list.bottom - list.top) * 0.8);
  for (let i = 0; i < 4; i++) {
    await driver.swipe(x, top, x, bottom, 8000);
  }
  await driver.delayMs(500);
}

/** Scrolls a page in steps (from the top) until a control is on screen, like a user looking for it. */
export async function scrollToId(driver: Driver, scrollId: string, id: string): Promise<Component> {
  const scroll = await waitId(driver, scrollId);
  const size = await driver.getDisplaySize();
  const already = await driver.findComponent(ON.id(id));
  if (already !== null && already !== undefined && (await already.getBounds()).bottom < size.y * 0.8) {
    return already;
  }
  // Back to the top with a few flicks; Component.scrollToTop() can hang on a Scroll and wedge UiTest.
  const area0 = await scroll.getBounds();
  const x0 = Math.round((area0.left + area0.right) / 2);
  for (let i = 0; i < 4; i++) {
    await driver.swipe(x0, Math.round(size.y * 0.3), x0, Math.round(size.y * 0.75), 6000);
  }
  await driver.delayMs(400);
  // Swipe inside the scroll view itself: in the two-column layout the screen's middle is the other pane.
  const area = await scroll.getBounds();
  const x = Math.round((area.left + area.right) / 2);
  let lastTop = -1;
  for (let i = 0; i < 8; i++) {
    const found = await driver.findComponent(ON.id(id));
    if (found !== null && found !== undefined) {
      const b = await found.getBounds();
      // Comfortably on screen, or already as high as the page can scroll (the last control on a page).
      if (b.bottom < size.y * 0.8 || (b.top === lastTop && b.bottom <= area.bottom)) {
        return found;
      }
      lastTop = b.top;
    }
    await driver.swipe(x, Math.round(size.y * 0.7), x, Math.round(size.y * 0.35), 900);
    await driver.delayMs(400);
  }
  throw new Error(`Could not scroll to ${id} (screenshot ${await failureShot(driver, `scroll-${id}`)})`);
}

/** Polls a component's text until it contains any of the fragments. */
export async function waitTextOfAny(driver: Driver, id: string, fragments: string[], timeoutMs: number = 10000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    const found = await driver.findComponent(ON.id(id));
    if (found !== null && found !== undefined) {
      try {
        last = await found.getText();
      } catch (e) {
        last = '';
      }
      if (fragments.some((f: string) => last.indexOf(f) >= 0)) {
        return last;
      }
    }
    await driver.delayMs(150);
  }
  throw new Error(`"${id}" never showed any of ${fragments.join('/')} (last: "${last}")`);
}

const TAB_IDS: Record<string, string> = {
  '对话': 'tab.chats',
  'PR': 'tab.pulls',
  '用量': 'tab.usage',
  '设置': 'tab.settings',
};

/** Taps a bottom tab; the bar shows icons only, so tabs are found by id. */
export async function tapTab(driver: Driver, label: string): Promise<void> {
  const tab = await driver.findComponent(ON.id(TAB_IDS[label] ?? label));
  if (tab === null || tab === undefined) {
    throw new Error(`Tab "${label}" not found (screenshot ${await failureShot(driver, `tab-${label}`)})`);
  }
  await tab.click();
  await driver.delayMs(400);
}

/** Scrolls the home list until the row sits in the middle of the screen, clear of the floating tab bar. */
export async function bringRowToMiddle(driver: Driver, id: string): Promise<Component> {
  const size = await driver.getDisplaySize();
  // Swipe on the list column, not the screen centre (which is the conversation pane when unfolded).
  const list = await (await waitId(driver, 'home.list')).getBounds();
  const x = Math.round(list.left + (list.right - list.left) * 0.45);
  for (let i = 0; i < 10; i++) {
    const row = await driver.findComponent(ON.id(id));
    if (row !== null && row !== undefined) {
      const b = await row.getBounds();
      const mid = (b.top + b.bottom) / 2;
      if (mid > size.y * 0.3 && mid < size.y * 0.65) {
        return row;
      }
      const delta = Math.round(mid - size.y / 2);
      await driver.swipe(x, Math.round(size.y / 2 + delta / 2), x, Math.round(size.y / 2 - delta / 2), 800);
    } else if (i === 5) {
      // Not found going down: start over from the top (scrollSearch can hang on lazy lists).
      await listToTop(driver);
    } else {
      await driver.swipe(x, Math.round(size.y * 0.7), x, Math.round(size.y * 0.35), 900);
    }
    await driver.delayMs(500);
  }
  throw new Error(`Could not find row ${id} (screenshot ${await failureShot(driver, `row-${id}`)})`);
}
