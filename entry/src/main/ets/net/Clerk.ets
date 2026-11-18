import { http } from '@kit.NetworkKit';
import { formEncode, httpRequest, HttpResult } from './HttpClient';
import { Prefs, PREF_CLERK_CLIENT } from '../common/Prefs';

/**
 * Minimal client for Clerk's Frontend API in native mode (`_is_native=1`), which is how the
 * official T3 Code mobile apps sign in. Native mode keeps the Clerk client in a JWT that the
 * server returns in the `authorization` response header and expects back on every request,
 * so no cookies or browser redirects are involved.
 */

interface ClerkErrorItem {
  code?: string;
  message?: string;
  long_message?: string;
}

interface ClerkFactor {
  strategy: string;
  email_address_id?: string;
  safe_identifier?: string;
}

interface ClerkSignIn {
  id: string;
  status: string;
  supported_first_factors?: ClerkFactor[];
  created_session_id?: string | null;
}

interface ClerkEmailAddress {
  id: string;
  email_address: string;
}

interface ClerkUser {
  id: string;
  primary_email_address_id?: string | null;
  email_addresses?: ClerkEmailAddress[];
}

interface ClerkSessionObject {
  id: string;
  status: string;
  user?: ClerkUser;
}

interface ClerkClientObject {
  id: string;
  sessions?: ClerkSessionObject[];
  last_active_session_id?: string | null;
}

interface ClerkEnvelope {
  response?: Object;
  client?: ClerkClientObject;
  errors?: ClerkErrorItem[];
  jwt?: string;
}

interface ClerkTokenObject {
  jwt?: string;
}

interface StoredClient {
  fapi: string;
  jwt: string;
}

export class ClerkError extends Error {
  code: string;
  status: number;

  constructor(code: string, status: number, message: string) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export class ClerkAccount {
  sessionId: string = '';
  userId: string = '';
  email: string = '';
}

export class EmailCodeChallenge {
  signInId: string = '';
  emailAddressId: string = '';
  sentTo: string = '';
}

/** Turns Clerk's error codes into something a person can act on. */
function friendlyMessage(code: string, status: number, fallback: string): string {
  switch (code) {
    case 'form_identifier_not_found':
      return '这个邮箱还没有 T3 账号。请先在电脑的 T3 Code 里登录并开启 T3 Connect。';
    case 'form_param_format_invalid':
      return '邮箱格式不对，请检查一下。';
    case 'form_code_incorrect':
      return '验证码不对，请再看一下邮件。';
    case 'verification_expired':
    case 'verification_failed':
      return '验证码已失效，请重新发送。';
    case 'too_many_requests':
    case 'rate_limit_exceeded':
      return '操作太频繁了，请稍等一分钟再试。';
    case 'strategy_for_user_invalid':
    case 'no_email_code':
      return '这个账号不支持邮箱验证码登录。';
    case 'needs_second_factor':
      return '这个账号开启了两步验证，暂时只能在电脑或官方 App 上登录。';
    case 'session_exists':
      return '已经登录了。';
    case 'authentication_invalid':
    case 'session_not_found':
    case 'signed_out':
      return '登录已过期，请重新登录 T3 账号。';
    default:
      if (status === 429) {
        return '操作太频繁了，请稍等一分钟再试。';
      }
      return fallback.length > 0 ? fallback : `T3 账号服务出错（HTTP ${status}）`;
  }
}

export class ClerkClient {
  readonly fapiUrl: string;
  private clientJwt: string = '';

  constructor(fapiUrl: string) {
    this.fapiUrl = fapiUrl.replace(/\/+$/, '');
    try {
      const stored = JSON.parse(Prefs.getString(PREF_CLERK_CLIENT, '{}')) as StoredClient;
      if (stored.fapi === this.fapiUrl && typeof stored.jwt === 'string') {
        this.clientJwt = stored.jwt;
      }
    } catch (e) {
      this.clientJwt = '';
    }
  }

  get hasClient(): boolean {
    return this.clientJwt.length > 0;
  }

  /** Starts an email-code sign-in and asks Clerk to send the code. */
  async startEmailCode(email: string): Promise<EmailCodeChallenge> {
    await this.ensureClient();
    const created = await this.call(http.RequestMethod.POST, '/v1/client/sign_ins', { 'identifier': email.trim() });
    const signIn = created.response as ClerkSignIn;
    const factors = signIn.supported_first_factors ?? [];
    let factor: ClerkFactor | null = null;
    for (const candidate of factors) {
      if (candidate.strategy === 'email_code' && candidate.email_address_id) {
        factor = candidate;
        break;
      }
    }
    if (factor === null) {
      throw new ClerkError('no_email_code', 422, friendlyMessage('no_email_code', 422, ''));
    }
    await this.call(http.RequestMethod.POST, `/v1/client/sign_ins/${signIn.id}/prepare_first_factor`, {
      'strategy': 'email_code',
      'email_address_id': factor.email_address_id as string,
    });
    const challenge = new EmailCodeChallenge();
    challenge.signInId = signIn.id;
    challenge.emailAddressId = factor.email_address_id as string;
    challenge.sentTo = factor.safe_identifier ?? email.trim();
    return challenge;
  }

  async resendEmailCode(challenge: EmailCodeChallenge): Promise<void> {
    await this.call(http.RequestMethod.POST, `/v1/client/sign_ins/${challenge.signInId}/prepare_first_factor`, {
      'strategy': 'email_code',
      'email_address_id': challenge.emailAddressId,
    });
  }

  async verifyEmailCode(challenge: EmailCodeChallenge, code: string): Promise<ClerkAccount> {
    const attempted = await this.call(http.RequestMethod.POST, `/v1/client/sign_ins/${challenge.signInId}/attempt_first_factor`, {
      'strategy': 'email_code',
      'code': code.trim(),
    });
    const signIn = attempted.response as ClerkSignIn;
    if (signIn.status === 'needs_second_factor') {
      throw new ClerkError('needs_second_factor', 422, friendlyMessage('needs_second_factor', 422, ''));
    }
    const sessionId = signIn.created_session_id ?? '';
    if (signIn.status !== 'complete' || sessionId.length === 0) {
      throw new ClerkError('incomplete', 422, '登录没有完成，请重新发送验证码。');
    }
    const account = ClerkClient.accountFrom(attempted.client, sessionId);
    if (account === null) {
      const fallback = new ClerkAccount();
      fallback.sessionId = sessionId;
      return fallback;
    }
    return account;
  }

  /** The signed-in account, or null when the client has no active session any more. */
  async currentAccount(): Promise<ClerkAccount | null> {
    if (!this.hasClient) {
      return null;
    }
    const envelope = await this.call(http.RequestMethod.GET, '/v1/client');
    const client = (envelope.response ?? envelope.client) as ClerkClientObject | undefined;
    if (client === undefined || client === null) {
      return null;
    }
    return ClerkClient.accountFrom(client, client.last_active_session_id ?? '');
  }

  /** A short-lived session JWT minted from `template` (T3 Connect uses `t3-relay`). */
  async sessionToken(sessionId: string, template: string): Promise<string> {
    const envelope = await this.call(http.RequestMethod.POST, `/v1/client/sessions/${sessionId}/tokens/${template}`);
    if (typeof envelope.jwt === 'string' && envelope.jwt.length > 0) {
      return envelope.jwt;
    }
    const token = envelope.response as ClerkTokenObject | undefined;
    if (token !== undefined && token !== null && typeof token.jwt === 'string') {
      return token.jwt;
    }
    throw new ClerkError('no_token', 500, '没有拿到 T3 账号令牌，请重新登录。');
  }

  async signOut(sessionId: string): Promise<void> {
    try {
      if (sessionId.length > 0 && this.hasClient) {
        await this.call(http.RequestMethod.POST, `/v1/client/sessions/${sessionId}/remove`);
      }
    } finally {
      this.clientJwt = '';
      Prefs.remove(PREF_CLERK_CLIENT);
    }
  }

  private async ensureClient(): Promise<void> {
    if (!this.hasClient) {
      await this.call(http.RequestMethod.POST, '/v1/client');
    }
  }

  private async call(method: http.RequestMethod, path: string, form?: Record<string, string>): Promise<ClerkEnvelope> {
    const url = `${this.fapiUrl}${path}${path.indexOf('?') >= 0 ? '&' : '?'}_is_native=1`;
    const headers: Record<string, string> = {
      'accept': 'application/json',
      'content-type': 'application/x-www-form-urlencoded',
    };
    if (this.clientJwt.length > 0) {
      headers['authorization'] = this.clientJwt;
    }
    let result: HttpResult;
    try {
      result = await httpRequest(method, url, headers, form !== undefined ? formEncode(form) : undefined, 15000);
    } catch (e) {
      throw new ClerkError('network', 0, '连不上 T3 账号服务，请检查网络。');
    }
    const rotated = result.headers.get('authorization') ?? '';
    if (rotated.length > 0 && rotated !== this.clientJwt) {
      this.clientJwt = rotated;
      const stored: StoredClient = { fapi: this.fapiUrl, jwt: rotated };
      Prefs.put(PREF_CLERK_CLIENT, JSON.stringify(stored));
    }
    let envelope: ClerkEnvelope = {};
    try {
      envelope = JSON.parse(result.body) as ClerkEnvelope;
    } catch (e) {
      envelope = {};
    }
    if (result.status >= 400 || (envelope.errors !== undefined && envelope.errors.length > 0)) {
      const first: ClerkErrorItem = envelope.errors !== undefined && envelope.errors.length > 0 ? envelope.errors[0] : {};
      const code = first.code ?? `http_${result.status}`;
      if (result.status === 401 || code === 'authentication_invalid') {
        // The client JWT is no longer valid; start fresh next time.
        this.clientJwt = '';
        Prefs.remove(PREF_CLERK_CLIENT);
      }
      throw new ClerkError(code, result.status, friendlyMessage(code, result.status, first.long_message ?? first.message ?? ''));
    }
    return envelope;
  }

  private static accountFrom(client: ClerkClientObject | undefined, sessionId: string): ClerkAccount | null {
    if (client === undefined || client === null) {
      return null;
    }
    for (const session of client.sessions ?? []) {
      if ((sessionId.length === 0 || session.id === sessionId) && session.status === 'active') {
        const account = new ClerkAccount();
        account.sessionId = session.id;
        account.userId = session.user?.id ?? '';
        const emails = session.user?.email_addresses ?? [];
        const primaryId = session.user?.primary_email_address_id ?? '';
        for (const email of emails) {
          if (email.id === primaryId || account.email.length === 0) {
            account.email = email.email_address;
          }
        }
        return account;
      }
    }
    return null;
  }
}
