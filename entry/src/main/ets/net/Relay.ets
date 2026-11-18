import { http } from '@kit.NetworkKit';
import { formEncode, httpRequest, HttpResult } from './HttpClient';
import { DpopKey } from './Dpop';

/** T3 Connect relay (relay.t3.codes): lists linked computers and mints tunnel credentials. */

export interface RelayEndpoint {
  httpBaseUrl: string;
  wsBaseUrl: string;
  providerKind?: string;
}

export interface RelayEnvironment {
  environmentId: string;
  label: string;
  endpoint: RelayEndpoint;
  linkedAt: string;
}

interface RelayEnvironmentList {
  environments?: RelayEnvironment[];
}

interface RelayTokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope: string;
}

export interface RelayConnectResult {
  environmentId: string;
  endpoint: RelayEndpoint;
  credential: string;
  expiresAt: string;
}

export interface RelayStatusResult {
  environmentId: string;
  status: string;
  error?: string;
}

interface ConnectRequestBody {
  clientProofKeyThumbprint: string;
  deviceId?: string;
}

interface RelayErrorBody {
  code?: string;
  error?: string;
  message?: string;
  _tag?: string;
}

class CachedToken {
  token: string = '';
  expiresAt: number = 0;
  thumbprint: string = '';
}

export class RelayError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function relayFailure(result: HttpResult, action: string): RelayError {
  let code = '';
  try {
    const body = JSON.parse(result.body) as RelayErrorBody;
    code = body.code ?? body.error ?? body._tag ?? '';
  } catch (e) {
    code = '';
  }
  if (result.status === 401) {
    return new RelayError(401, code, 'T3 账号登录已过期，请重新登录。');
  }
  if (result.status === 404) {
    return new RelayError(404, code, '这台电脑已经不在你的 T3 Connect 里了。');
  }
  if (result.status === 409 || result.status === 503 || code.indexOf('offline') >= 0) {
    return new RelayError(result.status, code, '电脑目前不在线。确认电脑开着并且 T3 Code 在运行。');
  }
  return new RelayError(result.status, code, `${action}失败（HTTP ${result.status}${code.length > 0 ? ' · ' + code : ''}）`);
}

export type TokenProvider = () => Promise<string>;

export class RelayClient {
  readonly relayUrl: string;
  readonly clientId: string;
  private cache: Map<string, CachedToken> = new Map();

  constructor(relayUrl: string, clientId: string) {
    this.relayUrl = relayUrl.replace(/\/+$/, '');
    this.clientId = clientId;
  }

  resetTokens(): void {
    this.cache.clear();
  }

  async listEnvironments(clerkJwt: string): Promise<RelayEnvironment[]> {
    const result = await this.send(http.RequestMethod.GET, `${this.relayUrl}/v1/environments`, {
      'authorization': `Bearer ${clerkJwt}`,
      'accept': 'application/json',
    });
    if (result.status !== 200) {
      throw relayFailure(result, '读取电脑列表');
    }
    const list = JSON.parse(result.body) as RelayEnvironmentList;
    return list.environments ?? [];
  }

  /** Asks the relay for a short-lived credential to open this computer's tunnel. */
  async connect(environmentId: string, key: DpopKey, clerkToken: TokenProvider): Promise<RelayConnectResult> {
    const url = `${this.relayUrl}/v1/environments/${encodeURIComponent(environmentId)}/connect`;
    const body: ConnectRequestBody = { clientProofKeyThumbprint: key.thumbprint };
    const result = await this.withDpop('environment:connect', key, clerkToken, http.RequestMethod.POST, url, JSON.stringify(body));
    if (result.status !== 200) {
      throw relayFailure(result, '连接电脑');
    }
    return JSON.parse(result.body) as RelayConnectResult;
  }

  async status(environmentId: string, key: DpopKey, clerkToken: TokenProvider): Promise<RelayStatusResult> {
    const url = `${this.relayUrl}/v1/environments/${encodeURIComponent(environmentId)}/status`;
    const result = await this.withDpop('environment:status', key, clerkToken, http.RequestMethod.POST, url, undefined);
    if (result.status !== 200) {
      throw relayFailure(result, '查询电脑状态');
    }
    return JSON.parse(result.body) as RelayStatusResult;
  }

  /** Runs a DPoP-protected relay call, refreshing the bound access token once if it was rejected. */
  private async withDpop(scope: string, key: DpopKey, clerkToken: TokenProvider, method: http.RequestMethod,
    url: string, body: string | undefined): Promise<HttpResult> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await this.accessToken(scope, key, clerkToken, attempt > 0);
      const headers: Record<string, string> = {
        'authorization': `DPoP ${token}`,
        'dpop': await key.proof(method === http.RequestMethod.GET ? 'GET' : 'POST', url, token),
        'accept': 'application/json',
      };
      if (body !== undefined) {
        headers['content-type'] = 'application/json';
      }
      const result = await this.send(method, url, headers, body);
      if (result.status !== 401 || attempt > 0) {
        return result;
      }
    }
    throw new RelayError(401, '', 'T3 账号登录已过期，请重新登录。');
  }

  private async accessToken(scope: string, key: DpopKey, clerkToken: TokenProvider, force: boolean): Promise<string> {
    const cached = this.cache.get(scope);
    if (!force && cached !== undefined && cached.thumbprint === key.thumbprint && cached.expiresAt - Date.now() > 30000) {
      return cached.token;
    }
    const url = `${this.relayUrl}/v1/client/dpop-token`;
    const fields: Record<string, string> = {
      'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
      'subject_token': await clerkToken(),
      'subject_token_type': 'urn:ietf:params:oauth:token-type:jwt',
      'requested_token_type': 'urn:ietf:params:oauth:token-type:access_token',
      'resource': this.relayUrl,
      'scope': scope,
      'client_id': this.clientId,
    };
    const result = await this.send(http.RequestMethod.POST, url, {
      'content-type': 'application/x-www-form-urlencoded',
      'accept': 'application/json',
      'dpop': await key.proof('POST', url),
    }, formEncode(fields));
    if (result.status !== 200) {
      throw relayFailure(result, '换取 T3 Connect 令牌');
    }
    const token = JSON.parse(result.body) as RelayTokenResponse;
    const entry = new CachedToken();
    entry.token = token.access_token;
    entry.expiresAt = Date.now() + token.expires_in * 1000;
    entry.thumbprint = key.thumbprint;
    this.cache.set(scope, entry);
    return entry.token;
  }

  private async send(method: http.RequestMethod, url: string, headers: Record<string, string>, body?: string): Promise<HttpResult> {
    try {
      return await httpRequest(method, url, headers, body, 15000);
    } catch (e) {
      throw new RelayError(0, 'network', '连不上 T3 Connect 服务，请检查网络。');
    }
  }
}
