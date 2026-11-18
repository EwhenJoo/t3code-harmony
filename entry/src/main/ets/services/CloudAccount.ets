import { deviceInfo } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { appState } from '../model/AppState';
import { AccessTokenResult, CloudComputer, ExecutionEnvironmentDescriptor, SavedEnvironment } from '../model/Types';
import { ClerkClient, ClerkError, EmailCodeChallenge } from '../net/Clerk';
import { RelayClient, RelayConnectResult, RelayEnvironment } from '../net/Relay';
import { deviceVerificationCode, DpopKey } from '../net/Dpop';
import { describeHttpFailure, formEncode, httpRequest } from '../net/HttpClient';
import { Prefs, PREF_CLOUD_ACCOUNT } from '../common/Prefs';
import { Log } from '../common/Log';
import { connection } from './Connection';

const TAG = 'CloudAccount';

/** Public identifiers of the production T3 Connect deployment (same as T3 Code's .env.example). */
export class ConnectConfig {
  fapiUrl: string = 'https://clerk.t3.codes';
  relayUrl: string = 'https://relay.t3.codes';
  jwtTemplate: string = 't3-relay';
  clientId: string = 't3-mobile';
}

interface StoredAccount {
  fapi: string;
  email: string;
  sessionId: string;
}

interface EnvironmentErrorBody {
  code?: string;
  message?: string;
}

export class ApprovalPendingError extends Error {
  verificationCode: string;

  constructor(verificationCode: string) {
    super('需要在电脑上批准这台设备');
    this.verificationCode = verificationCode;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function trimSlash(url: string): string {
  return url.replace(/\/+$/, '');
}

function messageOf(e: Object): string {
  const err = e as Error;
  return err?.message ?? JSON.stringify(e);
}

/**
 * T3 Connect sign-in and connection: a Clerk email-code session, a DPoP key on this device,
 * relay tokens bound to that key, and per-computer access tokens minted through the tunnel.
 */
class CloudAccountService {
  private config: ConnectConfig = new ConnectConfig();
  private clerk: ClerkClient = new ClerkClient(this.config.fapiUrl);
  private relay: RelayClient = new RelayClient(this.config.relayUrl, this.config.clientId);
  private sessionId: string = '';
  private challenge: EmailCodeChallenge | null = null;
  private approvalCancelled: boolean = false;

  /** Restores the saved account. `override` lets debug builds point at a mock deployment. */
  start(override?: ConnectConfig): void {
    if (override !== undefined) {
      this.config = override;
    }
    this.clerk = new ClerkClient(this.config.fapiUrl);
    this.relay = new RelayClient(this.config.relayUrl, this.config.clientId);
    try {
      const stored = JSON.parse(Prefs.getString(PREF_CLOUD_ACCOUNT, '{}')) as StoredAccount;
      if (stored.fapi === this.config.fapiUrl && stored.sessionId && this.clerk.hasClient) {
        this.sessionId = stored.sessionId;
        appState.cloudEmail = stored.email ?? '';
      }
    } catch (e) {
      this.sessionId = '';
    }
    appState.cloudStep = this.signedIn ? 'computers' : 'email';
    connection.tokenRenewer = (env: SavedEnvironment) => this.renewEnvironmentToken(env);
  }

  get signedIn(): boolean {
    return this.sessionId.length > 0;
  }

  // ---- Sign-in -------------------------------------------------------------------------------

  async sendCode(email: string): Promise<boolean> {
    if (appState.cloudBusy) {
      return false;
    }
    appState.cloudBusy = true;
    appState.cloudError = '';
    try {
      this.challenge = await this.clerk.startEmailCode(email);
      appState.cloudCodeSentTo = this.challenge.sentTo;
      appState.cloudStep = 'code';
      return true;
    } catch (e) {
      appState.cloudError = messageOf(e);
      return false;
    } finally {
      appState.cloudBusy = false;
    }
  }

  async resendCode(): Promise<void> {
    if (this.challenge === null || appState.cloudBusy) {
      return;
    }
    appState.cloudBusy = true;
    appState.cloudError = '';
    try {
      await this.clerk.resendEmailCode(this.challenge);
    } catch (e) {
      appState.cloudError = messageOf(e);
    } finally {
      appState.cloudBusy = false;
    }
  }

  async verifyCode(code: string): Promise<boolean> {
    if (this.challenge === null || appState.cloudBusy) {
      return false;
    }
    appState.cloudBusy = true;
    appState.cloudError = '';
    try {
      const account = await this.clerk.verifyEmailCode(this.challenge, code);
      this.sessionId = account.sessionId;
      let email = account.email;
      if (email.length === 0) {
        email = (await this.clerk.currentAccount())?.email ?? appState.cloudCodeSentTo;
      }
      const stored: StoredAccount = { fapi: this.config.fapiUrl, email: email, sessionId: account.sessionId };
      Prefs.put(PREF_CLOUD_ACCOUNT, JSON.stringify(stored));
      appState.cloudEmail = email;
      appState.cloudStep = 'computers';
      this.challenge = null;
    } catch (e) {
      appState.cloudError = messageOf(e);
      return false;
    } finally {
      appState.cloudBusy = false;
    }
    await this.refreshComputers();
    return true;
  }

  changeEmail(): void {
    this.challenge = null;
    appState.cloudError = '';
    appState.cloudStep = 'email';
  }

  async signOut(): Promise<void> {
    const sessionId = this.sessionId;
    this.sessionId = '';
    this.relay.resetTokens();
    Prefs.remove(PREF_CLOUD_ACCOUNT);
    appState.cloudEmail = '';
    appState.cloudComputers = [];
    appState.cloudComputersLoaded = false;
    appState.cloudStep = 'email';
    // Computers paired directly (LAN / Tailscale) stay; only the relay-reached ones need the account.
    connection.forgetConnectComputers();
    try {
      await this.clerk.signOut(sessionId);
    } catch (e) {
      Log.w(TAG, `remote sign-out failed: ${messageOf(e)}`);
    }
  }

  // ---- Computers -----------------------------------------------------------------------------

  async refreshComputers(): Promise<void> {
    if (!this.signedIn) {
      return;
    }
    appState.cloudBusy = true;
    appState.cloudError = '';
    try {
      const environments = await this.relay.listEnvironments(await this.clerkToken());
      appState.cloudComputers = environments.map((env: RelayEnvironment) => {
        const computer = new CloudComputer();
        computer.environmentId = env.environmentId;
        computer.label = env.label;
        computer.httpBaseUrl = env.endpoint.httpBaseUrl;
        computer.wsBaseUrl = env.endpoint.wsBaseUrl;
        computer.linkedAt = env.linkedAt;
        return computer;
      });
      appState.cloudComputersLoaded = true;
    } catch (e) {
      appState.cloudError = messageOf(e);
    } finally {
      appState.cloudBusy = false;
    }
  }

  /** Connects to a linked computer, waiting (with a visible code) while its owner approves this device. */
  async connectTo(computer: CloudComputer): Promise<boolean> {
    if (appState.cloudConnectingId.length > 0) {
      return false;
    }
    appState.cloudConnectingId = computer.environmentId;
    appState.cloudError = '';
    this.approvalCancelled = false;
    try {
      const env = await this.bootstrap(computer.environmentId, computer.label, true);
      env.pairedAt = new Date().toISOString();
      await connection.useEnvironment(env);
      return true;
    } catch (e) {
      if (!this.approvalCancelled) {
        appState.cloudError = messageOf(e);
      }
      return false;
    } finally {
      appState.cloudConnectingId = '';
      appState.cloudApprovalCode = '';
      appState.cloudApprovalHost = '';
    }
  }

  cancelApproval(): void {
    this.approvalCancelled = true;
  }

  /** Called by the connection when a T3 Connect token is about to expire or was rejected. */
  async renewEnvironmentToken(env: SavedEnvironment): Promise<SavedEnvironment> {
    if (!this.signedIn) {
      throw new Error('T3 账号已退出，请重新登录。');
    }
    const renewed = await this.bootstrap(env.id, env.label, false);
    renewed.pairedAt = env.pairedAt;
    return renewed;
  }

  /**
   * Relay `connect` (credential bound to our key) → the computer's `/oauth/token` (DPoP), which
   * answers 403 `connect_approval_pending` until someone at the computer approves this device.
   */
  private async bootstrap(environmentId: string, label: string, waitForApproval: boolean): Promise<SavedEnvironment> {
    const key = await DpopKey.load();
    const deadline = Date.now() + 5 * 60 * 1000;
    while (true) {
      const connected: RelayConnectResult = await this.relay.connect(environmentId, key, () => this.clerkToken());
      const base = trimSlash(connected.endpoint.httpBaseUrl);
      const tokenUrl = `${base}/oauth/token`;
      const fields: Record<string, string> = {
        'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
        'subject_token': connected.credential,
        'subject_token_type': 'urn:t3:params:oauth:token-type:environment-bootstrap',
        'requested_token_type': 'urn:ietf:params:oauth:token-type:access_token',
        'client_label': `${deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS'} (鸿蒙)`,
        'client_device_type': 'mobile',
        'client_os': 'HarmonyOS',
      };
      const res = await httpRequest(http.RequestMethod.POST, tokenUrl, {
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
        'dpop': await key.proof('POST', tokenUrl),
      }, formEncode(fields), 20000).catch((e: Object) => {
        throw new Error(`连不上电脑的 T3 Connect 通道：${messageOf(e)}`);
      });
      if (res.status === 200) {
        const token = JSON.parse(res.body) as AccessTokenResult;
        const env = new SavedEnvironment();
        env.id = connected.environmentId;
        env.label = label;
        env.kind = 'connect';
        env.baseUrl = base;
        env.wsBaseUrl = trimSlash(connected.endpoint.wsBaseUrl);
        env.accessToken = token.access_token;
        env.tokenType = token.token_type === 'Bearer' ? 'Bearer' : 'DPoP';
        env.tokenExpiresAt = token.expires_in > 0 ? Date.now() + token.expires_in * 1000 : 0;
        await this.describe(env);
        return env;
      }
      let body: EnvironmentErrorBody = {};
      try {
        body = JSON.parse(res.body) as EnvironmentErrorBody;
      } catch (e) {
        body = {};
      }
      if (res.status === 403 && body.code === 'connect_approval_pending') {
        const code = deviceVerificationCode(key.thumbprint);
        if (!waitForApproval) {
          throw new ApprovalPendingError(code);
        }
        appState.cloudApprovalCode = code;
        appState.cloudApprovalHost = label;
        await sleep(3000);
        if (this.approvalCancelled) {
          throw new Error('已取消');
        }
        if (Date.now() > deadline) {
          throw new Error('等待批准超时了，请在电脑上批准后再试一次。');
        }
        continue;
      }
      throw new Error(`电脑拒绝了这次连接（${describeHttpFailure(res)}）`);
    }
  }

  /** Best-effort version and OS for Settings; the public descriptor needs no token. */
  private async describe(env: SavedEnvironment): Promise<void> {
    try {
      const res = await httpRequest(http.RequestMethod.GET, `${env.baseUrl}/.well-known/t3/environment`, { 'accept': 'application/json' }, undefined, 8000);
      if (res.status === 200) {
        const descriptor = JSON.parse(res.body) as ExecutionEnvironmentDescriptor;
        env.serverVersion = descriptor.serverVersion ?? '';
        env.os = descriptor.platform?.os ?? '';
        if (descriptor.label && descriptor.label.length > 0) {
          env.label = descriptor.label;
        }
      }
    } catch (e) {
      Log.d(TAG, 'descriptor unavailable');
    }
  }

  private async clerkToken(): Promise<string> {
    try {
      return await this.clerk.sessionToken(this.sessionId, this.config.jwtTemplate);
    } catch (e) {
      const err = e as ClerkError;
      if (err.status === 401 || err.status === 404 || err.code === 'authentication_invalid') {
        this.sessionId = '';
        Prefs.remove(PREF_CLOUD_ACCOUNT);
        appState.cloudEmail = '';
        appState.cloudStep = 'email';
      }
      throw err;
    }
  }
}

export const cloudAccount: CloudAccountService = new CloudAccountService();
