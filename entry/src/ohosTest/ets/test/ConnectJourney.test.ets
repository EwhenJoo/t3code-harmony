import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver, MatchPattern, ON } from '@kit.TestKit';
import {
  backToHome,
  connectEntries,
  mockReset,
  openThreadFromHome,
  devConnectLink,
  ensureHome,
  mockConnectApprove,
  mockConnectExpire,
  mockConnectState,
  mockDrop,
  scrollToId,
  startApp,
  tapId,
  tapTab,
  typeInto,
  waitFor,
  waitId,
  waitText,
  waitTextOf,
  waitConnected,
} from './Support';

/**
 * T3 Connect from the user's side, against the mock Clerk + relay + tunnel in tools/mock-t3:
 * sign in with an emailed code, pick a computer, wait for the computer to approve this phone,
 * then keep working while short-lived tokens are renewed in the background.
 * The mock verifies every DPoP proof the app sends (ES256 signature, method, URL, token hash).
 */
export default function connectJourneyTest() {
  describe('ConnectJourney', () => {
    const driver: Driver = Driver.create();

    beforeAll(async () => {
      await mockReset();
    });

    it('20_signInWithT3AccountAndConnectThroughTheRelay', 0, async () => {
      await startApp(devConnectLink());
      await driver.delayMs(1000);
      const fromStart = await driver.findComponent(ON.id('pair.connectSignIn'));
      if (fromStart !== null && fromStart !== undefined) {
        // Fresh install: T3 Connect is the first thing on the start screen.
        await fromStart.click();
      } else {
        // Already paired over the LAN: sign in from Settings.
        await ensureHome(driver);
        await tapTab(driver, '设置');
        await (await scrollToId(driver, 'settings.scroll', 'settings.cloudSignIn')).click();
      }

      // An address without an account gets a clear explanation, not a dead end.
      await typeInto(driver, 'connect.email', 'nobody@t3.example');
      await tapId(driver, 'connect.sendCode');
      const unknown = await waitTextOf(driver, 'connect.error', 'T3 账号', 8000);
      expect(unknown.indexOf('还没有') >= 0).assertTrue();

      await typeInto(driver, 'connect.email', 'dev@t3.example');
      await tapId(driver, 'connect.sendCode');
      await waitId(driver, 'connect.code', 8000);
      await waitText(driver, 'd**@t3.example');

      // A mistyped code says so and lets the person try again.
      // The code submits itself at six digits, so the field is not read back afterwards.
      await typeInto(driver, 'connect.code', '111111', false);
      await waitTextOf(driver, 'connect.error', '验证码不对', 8000);
      await typeInto(driver, 'connect.code', '424242', false);

      // Signed in: the account's computers, including one that is switched off.
      await waitId(driver, 'connect.env.mock-env', 10000);
      await waitId(driver, 'connect.env.env-offline');
      await tapId(driver, 'connect.env.env-offline');
      await waitTextOf(driver, 'connect.error', '不在线', 10000);

      // First connection from this phone waits for approval and shows the code to compare.
      await tapId(driver, 'connect.env.mock-env');
      const code = await (await waitId(driver, 'connect.approvalCode', 10000)).getText();
      expect(/^[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$/.test(code)).assertTrue();
      await waitText(driver, 'Mock 工作站');
      await mockConnectApprove();

      await waitConnected(driver, 20000);
      await waitId(driver, 'home.thread.t-inbox');
      const state = await mockConnectState();
      expect(connectEntries(state, 'connect.token').length).assertEqual(1);
      const sockets = connectEntries(state, 'connect.ws');
      expect(sockets.length >= 1).assertTrue();
      expect(sockets[sockets.length - 1].payload['connectionMethod'] as string).assertEqual('relay');
      expect(connectEntries(state, 'connect.rejected').length).assertEqual(0);

      await tapTab(driver, '设置');
      // Settings keeps its scroll position from signing in further down the page.
      await scrollToId(driver, 'settings.scroll', 'settings.computerRoute');
      await waitTextOf(driver, 'settings.computerRoute', 'T3 Connect');
      await scrollToId(driver, 'settings.scroll', 'settings.cloudEmail');
      await waitText(driver, 'dev@t3.example');
    });

    it('21_expiredTokensAreRenewedWithoutBotheringTheUser', 0, async () => {
      await ensureHome(driver);
      const before = connectEntries(await mockConnectState(), 'connect.token').length;
      await mockConnectExpire();
      await mockDrop();
      // The socket comes back on its own: a fresh token is minted through the relay, no approval needed.
      await waitConnected(driver, 20000);
      const deadline = Date.now() + 10000;
      let after = before;
      while (Date.now() < deadline && after <= before) {
        await driver.delayMs(300);
        after = connectEntries(await mockConnectState(), 'connect.token').length;
      }
      expect(after > before).assertTrue();
      const state = await mockConnectState();
      expect(state.pending).assertEqual(0);
      // Opening a thread loads its snapshot over HTTP with a DPoP proof.
      await openThreadFromHome(driver, 't-inbox');
      await waitText(driver, '登录页的样式问题已经修好了', 10000);
      expect(connectEntries(await mockConnectState(), 'connect.rejected').length).assertEqual(0);
      await backToHome(driver);
    });

    it('22_signingOutReturnsToTheStartScreen', 0, async () => {
      await ensureHome(driver);
      await tapTab(driver, '设置');
      await scrollToId(driver, 'settings.scroll', 'settings.cloudEmail');
      const button = await waitFor(driver, ON.text('退出 T3 账号', MatchPattern.EQUALS), 8000, 'sign out');
      await button.click();
      // The computer was reached through T3 Connect, so signing out also forgets it.
      await waitId(driver, 'pair.title', 10000);
      await waitId(driver, 'pair.connectSignIn');
      expect(connectEntries(await mockConnectState(), 'clerk.signedOut').length).assertEqual(1);
    });
  });
}
