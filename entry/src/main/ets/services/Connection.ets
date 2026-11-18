import { http } from '@kit.NetworkKit';
import { notifier } from './Notifier';
import { deviceInfo } from '@kit.BasicServicesKit';
import { appState, EnvironmentState } from '../model/AppState';
import { ThreadDetailState } from '../model/ThreadDetail';
import {
  AccessTokenResult,
  ChatAttachment,
  ExecutionEnvironmentDescriptor,
  ModelSelection,
  PromptSuggestion,
  SavedEnvironment,
  ServerConfig,
  ShellStreamItem,
  ThreadDetailSnapshot,
  ThreadStreamItem,
  WebSocketTicketResult,
} from '../model/Types';
import { authHeaders, describeHttpFailure, formEncode, httpRequest, HttpResult, ORCHESTRATION_PROTOCOL_VERSION } from '../net/HttpClient';
import { parsePairingInput, wsUrlFor } from '../net/Pairing';
import { RpcSocket } from '../net/RpcSocket';
import { DpopKey } from '../net/Dpop';
import { Log } from '../common/Log';
import { newId } from '../common/Format';
import { Prefs, PREF_ENVIRONMENT, PREF_ENVIRONMENTS } from '../common/Prefs';
import { closeMissingThreads } from '../common/Nav';

const TAG = 'Connection';
const APP_VERSION = '0.1.0';

interface SubscribeShellPayload {
  requestCompletionMarker: boolean;
}

interface SubscribeThreadPayload {
  threadId: string;
  requestCompletionMarker: boolean;
}

interface ThreadIdPayload {
  threadId: string;
}

interface EmptyPayload {
}

interface DispatchMode {
  type: string;
  targetRunId?: string;
}

interface ModelSelectionCommand {
  type: string;
  commandId: string;
  threadId: string;
  modelSelection: ModelSelection;
}

interface RuntimeModeCommand {
  type: string;
  commandId: string;
  threadId: string;
  runtimeMode: string;
}

interface InteractionModeCommand {
  type: string;
  commandId: string;
  threadId: string;
  interactionMode: string;
}

interface SnoozeCommand {
  type: string;
  commandId: string;
  threadId: string;
  snoozedUntil: string;
}

interface RenameCommand {
  type: string;
  commandId: string;
  threadId: string;
  title?: string;
  regenerateTitle?: boolean;
}

interface MessageDispatchCommand {
  type: string;
  commandId: string;
  createdBy: string;
  creationSource: string;
  threadId: string;
  messageId: string;
  text: string;
  attachments: Object[];
  deliveryIntent?: string;
  dispatchMode: DispatchMode;
}

interface RuntimeRespondCommand {
  type: string;
  commandId: string;
  threadId: string;
  requestId: string;
  decision?: string;
  answers?: Record<string, Object>;
  feedback?: string;
}

interface ThreadCommand {
  type: string;
  commandId: string;
  threadId: string;
  reason?: string;
}

interface VisitCommand {
  type: string;
  commandId: string;
  threadId: string;
  visitedAt: string;
  opened: boolean;
}

interface WorkspaceStrategy {
  type: string;
}

interface InitialMessage {
  messageId: string;
  text: string;
  attachments: Object[];
}

interface LaunchThreadInput {
  commandId: string;
  creationSource: string;
  threadId: string;
  projectId: string;
  title: string;
  generateTitle: boolean;
  modelSelection: ModelSelection;
  runtimeMode: string;
  interactionMode: string;
  workspaceStrategy: WorkspaceStrategy;
  initialMessage: InitialMessage;
}

interface LaunchThreadResult {
  threadId: string;
}

class ThreadSubscription {
  state: ThreadDetailState;
  requestId: string = '';
  /** The prompt-suggestion stream that runs beside the thread stream. */
  suggestionRequestId: string = '';
  refCount: number = 1;

  constructor(state: ThreadDetailState) {
    this.state = state;
  }
}

export class ConnectionError extends Error {
  constructor(message: string) {
    super(message);
  }
}

type TokenRenewer = (env: SavedEnvironment) => Promise<SavedEnvironment>;

/**
 * The live link to one computer: its RPC socket, reconnect schedule, shell stream and open
 * conversations. Every computer gets its own, so they connect, drop and recover independently.
 */
class EnvironmentConnection {
  readonly state: EnvironmentState;
  private owner: ConnectionService;
  private socket: RpcSocket | null = null;
  private reconnectTimer: number = -1;
  private reconnectAttempt: number = 0;
  private connecting: boolean = false;
  private connectingTo: string = '';
  private attemptGeneration: number = 0;
  private subscriptions: Map<string, ThreadSubscription> = new Map();
  private closed: boolean = false;

  constructor(state: EnvironmentState, owner: ConnectionService) {
    this.state = state;
    this.owner = owner;
  }

  get isOpen(): boolean {
    return this.socket !== null && this.socket.isOpen;
  }

  /**
   * Opens the socket. Each call starts a new attempt generation; an older attempt that finishes
   * later (e.g. still timing out against an old route) is discarded instead of overwriting it.
   */
  async connect(): Promise<void> {
    if (this.closed) {
      return;
    }
    let env = this.state.env;
    if (this.connecting && this.connectingTo === env.baseUrl + env.accessToken) {
      return;
    }
    const attempt = ++this.attemptGeneration;
    this.connecting = true;
    this.connectingTo = env.baseUrl + env.accessToken;
    this.state.phase = this.state.shellLoaded ? 'reconnecting' : 'connecting';
    this.state.phaseDetail = '';
    try {
      const isConnect = env.kind === 'connect';
      if (isConnect && (env.tokenExpiresAt ?? 0) > 0 && (env.tokenExpiresAt ?? 0) - Date.now() < 60000) {
        env = await this.renewToken(env);
        if (attempt !== this.attemptGeneration) {
          return;
        }
      }
      const ticketUrl = `${env.baseUrl}/api/auth/websocket-ticket/rpc`;
      let ticketRes: HttpResult = await httpRequest(http.RequestMethod.POST, ticketUrl, await authorized(env, 'POST', ticketUrl), '');
      if (attempt !== this.attemptGeneration) {
        return;
      }
      if (isConnect && (ticketRes.status === 401 || ticketRes.status === 403)) {
        // T3 Connect tokens are short-lived; mint a new one through the relay and try once more.
        env = await this.renewToken(env);
        if (attempt !== this.attemptGeneration) {
          return;
        }
        ticketRes = await httpRequest(http.RequestMethod.POST, ticketUrl, await authorized(env, 'POST', ticketUrl), '');
        if (attempt !== this.attemptGeneration) {
          return;
        }
      }
      if (ticketRes.status === 401 || ticketRes.status === 403) {
        this.connecting = false;
        this.state.phase = 'offline';
        this.state.phaseDetail = isConnect ? 'T3 Connect 授权已失效，请在设置里重新连接这台电脑' : '授权已失效，请在电脑上重新生成配对码';
        return;
      }
      if (ticketRes.status !== 200) {
        throw new ConnectionError(describeHttpFailure(ticketRes));
      }
      const ticket = JSON.parse(ticketRes.body) as WebSocketTicketResult;
      const socketUrl = socketUrlFor(env);
      const params: string[] = [
        `wsTicket=${encodeURIComponent(ticket.ticket)}`,
        `orchestrationProtocol=${ORCHESTRATION_PROTOCOL_VERSION}`,
        'clientSurface=mobile',
        'clientDeviceType=phone',
        `clientAppVersion=${APP_VERSION}`,
        `connectionMethod=${isConnect ? 'relay' : 'direct'}`,
      ];
      if (env.tokenType === 'DPoP') {
        // A browser-style WebSocket cannot send headers, so the upgrade's proof rides in the query
        // and names the socket as the HTTP request the server sees, bound to the ticket.
        const key = await DpopKey.load();
        const httpForm = socketUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');
        params.push(`dpop=${encodeURIComponent(await key.proof('GET', httpForm, ticket.ticket))}`);
      }
      const socket = new RpcSocket();
      socket.onClose = (reason: string) => this.onSocketClosed(socket, reason);
      await socket.connect(`${socketUrl}?${params.join('&')}`);
      if (attempt !== this.attemptGeneration || this.closed) {
        socket.onClose = undefined;
        socket.close();
        return;
      }
      this.socket = socket;
      this.connecting = false;
      this.reconnectAttempt = 0;
      this.state.phase = 'connected';
      this.subscribeShell(socket);
      this.loadConfig(socket);
      this.subscriptions.forEach((sub: ThreadSubscription) => this.subscribeThread(socket, sub));
    } catch (e) {
      if (attempt !== this.attemptGeneration) {
        return;
      }
      this.connecting = false;
      const message = (e as Error)?.message ?? JSON.stringify(e);
      Log.w(TAG, `${this.state.label}: connect failed: ${message}`);
      this.state.phase = 'offline';
      this.state.phaseDetail = message;
      this.scheduleReconnect();
    }
  }

  /** Reconnects right away if the socket is down, e.g. when the app returns to the foreground. */
  wake(): void {
    if (!this.isOpen) {
      this.clearReconnect();
      this.connect();
    }
  }

  async refresh(): Promise<void> {
    this.disconnect();
    this.reconnectAttempt = 0;
    await this.connect();
  }

  disconnect(): void {
    this.clearReconnect();
    // Discard any attempt still in flight; its late result must not resurrect this connection.
    this.attemptGeneration++;
    this.connecting = false;
    const socket = this.socket;
    this.socket = null;
    if (socket !== null) {
      socket.onClose = undefined;
      socket.close();
    }
  }

  /** Permanently stops this connection (the computer was removed). */
  close(): void {
    this.closed = true;
    this.disconnect();
    this.subscriptions.clear();
  }

  /** Swaps credentials or route (e.g. LAN pairing replaced by T3 Connect) and reconnects. */
  async replaceEnvironment(env: SavedEnvironment): Promise<void> {
    this.disconnect();
    this.state.env = env;
    this.reconnectAttempt = 0;
    await this.connect();
  }

  // ---- Threads -------------------------------------------------------------------------------

  openThread(threadId: string): ThreadDetailState {
    const existing = this.subscriptions.get(threadId);
    if (existing) {
      existing.refCount++;
      return existing.state;
    }
    const sub = new ThreadSubscription(new ThreadDetailState(threadId));
    this.subscriptions.set(threadId, sub);
    this.loadThreadSnapshot(sub);
    if (this.socket !== null && this.socket.isOpen) {
      this.subscribeThread(this.socket, sub);
    }
    return sub.state;
  }

  closeThread(threadId: string): void {
    const sub = this.subscriptions.get(threadId);
    if (!sub) {
      return;
    }
    sub.refCount--;
    if (sub.refCount > 0) {
      return;
    }
    this.subscriptions.delete(threadId);
    if (this.socket !== null && sub.requestId.length > 0) {
      this.socket.interrupt(sub.requestId);
    }
    if (this.socket !== null && sub.suggestionRequestId.length > 0) {
      this.socket.interrupt(sub.suggestionRequestId);
    }
  }

  async dispatch(command: Object): Promise<void> {
    await this.requireSocket().request('orchestration.dispatchCommand', command);
  }

  dispatchQuietly(command: Object): void {
    if (!this.isOpen || this.socket === null) {
      return;
    }
    this.socket.request('orchestration.dispatchCommand', command).catch((e: Error) => {
      Log.d(TAG, `${this.state.label}: command failed ${e.message}`);
    });
  }

  async launch(input: LaunchThreadInput): Promise<string> {
    const result = await this.requireSocket().request('orchestration.launchThread', input) as LaunchThreadResult;
    return result.threadId;
  }

  /** Any other RPC on this computer (git, terminal, files, usage, pull requests). */
  async request(tag: string, payload: Object): Promise<Object | null> {
    return await this.requireSocket().request(tag, payload);
  }

  /** A streaming RPC; returns the request id to interrupt it with, or '' when not connected. */
  stream(tag: string, payload: Object, onChunk: (values: Object[]) => void,
    onExit: (ok: boolean, value: Object | null, error: string) => void): string {
    if (this.socket === null || !this.socket.isOpen) {
      onExit(false, null, `尚未连接到 ${this.state.label}`);
      return '';
    }
    return this.socket.stream(tag, payload, onChunk, onExit);
  }

  interrupt(requestId: string): void {
    if (this.socket !== null && requestId.length > 0) {
      this.socket.interrupt(requestId);
    }
  }

  /** Re-reads the server config (providers, usage limits). */
  async reloadConfig(): Promise<void> {
    const payload: EmptyPayload = {};
    const value = await this.requireSocket().request('server.getConfig', payload);
    if (value !== null && !this.closed) {
      this.state.config = value as ServerConfig;
    }
  }

  // ---- Internals -----------------------------------------------------------------------------

  private async renewToken(env: SavedEnvironment): Promise<SavedEnvironment> {
    const renewer = this.owner.tokenRenewer;
    if (renewer === null) {
      throw new ConnectionError('T3 Connect 尚未就绪');
    }
    const renewed = await renewer(env);
    if (!this.closed) {
      this.state.env = renewed;
      this.owner.persist();
    }
    return renewed;
  }

  private requireSocket(): RpcSocket {
    if (this.socket === null || !this.socket.isOpen) {
      throw new ConnectionError(`尚未连接到 ${this.state.label}`);
    }
    return this.socket;
  }

  private subscribeShell(socket: RpcSocket): void {
    const payload: SubscribeShellPayload = { requestCompletionMarker: true };
    socket.stream('orchestration.subscribeShell', payload, (values: Object[]) => {
      if (this.closed) {
        return;
      }
      values.forEach((value: Object) => appState.applyShellItem(this.state, value as ShellStreamItem));
      notifier.onThreadsChanged();
    }, (ok: boolean, value: Object | null, error: string) => {
      if (!ok && socket === this.socket) {
        Log.w(TAG, `${this.state.label}: shell stream ended: ${error}`);
      }
    });
  }

  private loadConfig(socket: RpcSocket): void {
    const payload: EmptyPayload = {};
    socket.request('server.getConfig', payload).then((value: Object | null) => {
      if (value !== null && !this.closed) {
        this.state.config = value as ServerConfig;
      }
    }).catch((e: Error) => {
      Log.w(TAG, `${this.state.label}: getConfig failed ${e.message}`);
    });
  }

  private subscribeThread(socket: RpcSocket, sub: ThreadSubscription): void {
    const payload: SubscribeThreadPayload = { threadId: sub.state.threadId, requestCompletionMarker: true };
    sub.requestId = socket.stream('orchestration.subscribeThread', payload, (values: Object[]) => {
      values.forEach((value: Object) => sub.state.applyStreamItem(value as ThreadStreamItem));
    }, (ok: boolean, value: Object | null, error: string) => {
      if (!ok && this.subscriptions.get(sub.state.threadId) === sub && socket === this.socket) {
        sub.state.error = error;
      }
    });
    // What to say next, as the desktop offers it (only produced when its Labs switch is on). Servers
    // without the method simply end the stream; nothing is shown then.
    const input: ThreadIdPayload = { threadId: sub.state.threadId };
    sub.suggestionRequestId = socket.stream('orchestration.subscribePromptSuggestion', input, (values: Object[]) => {
      values.forEach((value: Object) => {
        sub.state.promptSuggestion = value === null || value === undefined ? null : value as PromptSuggestion;
      });
    }, (ok: boolean, value: Object | null, error: string) => {
      if (!ok) {
        Log.d(TAG, `${this.state.label}: no prompt suggestions (${error})`);
      }
    });
  }

  private async loadThreadSnapshot(sub: ThreadSubscription): Promise<void> {
    const env = this.state.env;
    try {
      const url = `${env.baseUrl}/api/orchestration/threads/${encodeURIComponent(sub.state.threadId)}`;
      const res = await httpRequest(http.RequestMethod.GET, url, await authorized(env, 'GET', url));
      if (res.status !== 200) {
        if (sub.state.loading) {
          sub.state.error = describeHttpFailure(res);
        }
        return;
      }
      const snapshot = JSON.parse(res.body) as ThreadDetailSnapshot;
      // The socket snapshot may already be newer; only apply when it is not.
      if (snapshot.snapshotSequence >= sub.state.sequence) {
        sub.state.applyProjection(snapshot.projection, snapshot.snapshotSequence, snapshot.hasMoreHistory ?? false);
      }
    } catch (e) {
      if (sub.state.loading) {
        sub.state.error = (e as Error)?.message ?? '加载失败';
      }
    }
  }

  private onSocketClosed(socket: RpcSocket, reason: string): void {
    if (socket !== this.socket) {
      return;
    }
    Log.w(TAG, `${this.state.label}: socket closed: ${reason}`);
    this.socket = null;
    this.state.phase = 'reconnecting';
    this.state.phaseDetail = reason;
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer >= 0) {
      return;
    }
    const delays: number[] = [1000, 2000, 4000, 8000, 15000, 30000];
    const delay = delays[Math.min(this.reconnectAttempt, delays.length - 1)];
    this.reconnectAttempt++;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connect();
    }, delay);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }
}

/** Bearer for paired computers; DPoP (a fresh proof per request) for T3 Connect tokens. */
async function authorized(env: SavedEnvironment, method: string, url: string): Promise<Record<string, string>> {
  if (env.tokenType !== 'DPoP') {
    return authHeaders(env.accessToken);
  }
  const key = await DpopKey.load();
  const headers: Record<string, string> = {
    'authorization': 'DPoP ' + env.accessToken,
    'dpop': await key.proof(method, url, env.accessToken),
    'x-t3-orchestration-protocol': ORCHESTRATION_PROTOCOL_VERSION,
    'accept': 'application/json',
  };
  return headers;
}

/** The RPC socket URL: `/ws` on the computer, or the tunnel's own path when it has one. */
function socketUrlFor(env: SavedEnvironment): string {
  const base = env.kind === 'connect' && env.wsBaseUrl ? env.wsBaseUrl : wsUrlFor(env.baseUrl);
  const match = /^(wss?:\/\/[^/?#]+)([^?#]*)/.exec(base);
  if (match === null) {
    return `${base}/ws`;
  }
  const path = match[2] ?? '';
  return `${match[1]}${path.length === 0 || path === '/' ? '/ws' : path}`;
}

/**
 * All computers at once. Each saved computer has its own EnvironmentConnection; their threads
 * share one list in appState, and thread / project operations are routed to the computer that
 * owns them.
 */
class ConnectionService {
  private links: Map<string, EnvironmentConnection> = new Map();
  private clockTimer: number = -1;
  /** Mints a fresh T3 Connect token through the relay (installed by CloudAccount). */
  tokenRenewer: TokenRenewer | null = null;

  /** Restores every saved computer (migrating the single-computer v1 setting) and connects them. */
  start(): void {
    const saved: SavedEnvironment[] = [];
    const raw = Prefs.getString(PREF_ENVIRONMENTS, '');
    if (raw.length > 0) {
      try {
        (JSON.parse(raw) as SavedEnvironment[]).forEach((env: SavedEnvironment) => saved.push(env));
      } catch (e) {
        Log.w(TAG, 'saved computers unreadable');
      }
    } else {
      const legacy = Prefs.getString(PREF_ENVIRONMENT, '');
      if (legacy.length > 0) {
        try {
          saved.push(JSON.parse(legacy) as SavedEnvironment);
        } catch (e) {
          Log.w(TAG, 'saved environment unreadable');
        }
      }
    }
    if (this.clockTimer < 0) {
      this.clockTimer = setInterval(() => {
        appState.now = Date.now();
      }, 30000);
    }
    const states: EnvironmentState[] = [];
    saved.forEach((env: SavedEnvironment) => {
      if (env.id && !this.links.has(env.id)) {
        const state = new EnvironmentState(env);
        this.links.set(env.id, new EnvironmentConnection(state, this));
        states.push(state);
      }
    });
    appState.environments = states;
    this.persist();
    Prefs.remove(PREF_ENVIRONMENT);
    this.links.forEach((link: EnvironmentConnection) => link.connect());
  }

  /** Exchanges a one-time pairing link for a long-lived access token, then adds that computer. */
  async pair(input: string): Promise<void> {
    const target = parsePairingInput(input);
    if (target.baseUrl.length === 0 || target.token.length === 0) {
      throw new ConnectionError('配对链接里没有找到服务器地址或配对码');
    }
    const descriptorRes = await httpRequest(http.RequestMethod.GET, `${target.baseUrl}/.well-known/t3/environment`, {}, undefined, 8000)
      .catch((e: Error) => {
        throw new ConnectionError(`无法连接 ${target.baseUrl}：${e.message ?? JSON.stringify(e)}`);
      });
    if (descriptorRes.status !== 200) {
      throw new ConnectionError(`服务器不可用（${describeHttpFailure(descriptorRes)}）`);
    }
    const descriptor = JSON.parse(descriptorRes.body) as ExecutionEnvironmentDescriptor;
    const fields: Record<string, string> = {
      'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
      'subject_token': target.token,
      'subject_token_type': 'urn:t3:params:oauth:token-type:environment-bootstrap',
      'requested_token_type': 'urn:ietf:params:oauth:token-type:access_token',
      'client_label': `${deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS'} (鸿蒙)`,
      'client_device_type': 'mobile',
      'client_os': 'HarmonyOS',
    };
    const tokenRes = await httpRequest(http.RequestMethod.POST, `${target.baseUrl}/oauth/token`,
      { 'content-type': 'application/x-www-form-urlencoded' }, formEncode(fields));
    if (tokenRes.status !== 200) {
      throw new ConnectionError(`配对失败：${describeHttpFailure(tokenRes)}（配对码可能已使用或过期）`);
    }
    const token = JSON.parse(tokenRes.body) as AccessTokenResult;
    const env = new SavedEnvironment();
    env.id = descriptor.environmentId;
    env.label = target.label.length > 0 ? target.label : descriptor.label;
    env.baseUrl = target.baseUrl;
    env.accessToken = token.access_token;
    env.serverVersion = descriptor.serverVersion ?? '';
    env.os = descriptor.platform?.os ?? '';
    env.pairedAt = new Date().toISOString();
    env.kind = 'direct';
    env.tokenType = 'Bearer';
    await this.useEnvironment(env);
  }

  /**
   * Adds a computer next to the ones already connected. The same computer reached a new way
   * (paired again, or through T3 Connect instead of the LAN) replaces its old entry, so its
   * threads never appear twice.
   */
  async useEnvironment(env: SavedEnvironment): Promise<void> {
    const existing = this.links.get(env.id);
    if (existing !== undefined) {
      const reconnecting = existing.replaceEnvironment(env);
      // A new array tells observers the set of routes changed (e.g. LAN → T3 Connect).
      appState.environments = appState.environments.slice();
      this.persist();
      await reconnecting;
      return;
    }
    const state = new EnvironmentState(env);
    const link = new EnvironmentConnection(state, this);
    this.links.set(env.id, link);
    appState.environments = appState.environments.concat([state]);
    this.persist();
    await link.connect();
  }

  /** Pairs from a scanned, pasted or deep-linked URL and reports progress through appState. */
  async pairFromLink(link: string): Promise<boolean> {
    if (appState.pairingBusy) {
      return false;
    }
    appState.pairingBusy = true;
    appState.pairingError = '';
    try {
      await this.pair(link);
      return true;
    } catch (e) {
      appState.pairingError = (e as Error)?.message ?? '配对失败';
      return false;
    } finally {
      appState.pairingBusy = false;
    }
  }

  /** Pull-to-refresh: reconnects every computer, which resubscribes and reloads their shells. */
  async refresh(): Promise<void> {
    const all: Promise<void>[] = [];
    this.links.forEach((link: EnvironmentConnection) => all.push(link.refresh()));
    await Promise.all(all);
  }

  async reconnect(environmentId: string): Promise<void> {
    const link = this.links.get(environmentId);
    if (link !== undefined) {
      await link.refresh();
    }
  }

  /** Removes one computer: closes its connection and drops its threads from the list. */
  forget(environmentId: string): void {
    const link = this.links.get(environmentId);
    if (link === undefined) {
      return;
    }
    link.close();
    this.links.delete(environmentId);
    appState.environments = appState.environments.filter((e: EnvironmentState) => e.id !== environmentId);
    appState.clearEnvironmentData(environmentId);
    // Its conversations can't continue without it; don't leave one open in the detail pane.
    closeMissingThreads();
    this.persist();
  }

  /** Removes every computer reached through T3 Connect (signing out of the T3 account). */
  forgetConnectComputers(): void {
    const ids: string[] = [];
    this.links.forEach((link: EnvironmentConnection, id: string) => {
      if (link.state.isConnect) {
        ids.push(id);
      }
    });
    ids.forEach((id: string) => this.forget(id));
  }

  /** Reconnects every computer whose socket is down, e.g. when the app returns to the foreground. */
  wake(): void {
    this.links.forEach((link: EnvironmentConnection) => link.wake());
  }

  isConnected(environmentId: string): boolean {
    return this.links.get(environmentId)?.isOpen ?? false;
  }

  persist(): void {
    const envs = appState.environments.map((e: EnvironmentState) => e.env);
    if (envs.length === 0) {
      Prefs.remove(PREF_ENVIRONMENTS);
    } else {
      Prefs.put(PREF_ENVIRONMENTS, JSON.stringify(envs));
    }
  }

  // ---- Threads, routed to the computer that owns them ----------------------------------------

  openThread(threadId: string): ThreadDetailState {
    return this.linkForThread(threadId).openThread(threadId);
  }

  closeThread(threadId: string): void {
    this.links.forEach((link: EnvironmentConnection) => link.closeThread(threadId));
  }

  /**
   * Sends a message. While the agent runs, `followUp` decides: 'steer' guides the current turn,
   * 'queue' waits until it finishes (the iOS "while the agent is running" setting).
   */
  async sendMessage(threadId: string, text: string, running: boolean = false, followUp: string = 'steer',
    attachments: ChatAttachment[] = []): Promise<void> {
    const queue = running && followUp === 'queue';
    const command: MessageDispatchCommand = {
      type: 'message.dispatch',
      commandId: newId(),
      createdBy: 'user',
      creationSource: 'mobile',
      threadId: threadId,
      messageId: newId(),
      text: text,
      attachments: attachments,
      dispatchMode: { type: queue ? 'queue_after_active' : 'start_immediately' },
    };
    if (!queue) {
      command.deliveryIntent = running ? 'steer' : 'auto';
    }
    await this.linkForThread(threadId).dispatch(command);
  }

  async setThreadModel(threadId: string, selection: ModelSelection): Promise<void> {
    const command: ModelSelectionCommand = {
      type: 'thread.model-selection.set', commandId: newId(), threadId: threadId, modelSelection: selection,
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  async setThreadRuntimeMode(threadId: string, runtimeMode: string): Promise<void> {
    const command: RuntimeModeCommand = {
      type: 'thread.runtime-mode.set', commandId: newId(), threadId: threadId, runtimeMode: runtimeMode,
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  async setThreadInteractionMode(threadId: string, interactionMode: string): Promise<void> {
    const command: InteractionModeCommand = {
      type: 'thread.interaction-mode.set', commandId: newId(), threadId: threadId, interactionMode: interactionMode,
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  async snoozeThread(threadId: string, until: Date): Promise<void> {
    const command: SnoozeCommand = {
      type: 'thread.snooze', commandId: newId(), threadId: threadId, snoozedUntil: until.toISOString(),
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  async renameThread(threadId: string, title: string): Promise<void> {
    const command: RenameCommand = { type: 'thread.metadata.update', commandId: newId(), threadId: threadId };
    if (title.trim().length > 0) {
      command.title = title.trim();
    } else {
      command.regenerateTitle = true;
    }
    await this.linkForThread(threadId).dispatch(command);
  }

  async respondApproval(threadId: string, requestId: string, decision: string): Promise<void> {
    const command: RuntimeRespondCommand = {
      type: 'runtime-request.respond',
      commandId: newId(),
      threadId: threadId,
      requestId: requestId,
      decision: decision,
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  async answerQuestion(threadId: string, requestId: string, answers: Record<string, Object>): Promise<void> {
    const command: RuntimeRespondCommand = {
      type: 'runtime-request.respond',
      commandId: newId(),
      threadId: threadId,
      requestId: requestId,
      answers: answers,
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  async stopThread(threadId: string): Promise<void> {
    const command: ThreadCommand = {
      type: 'thread.stop',
      commandId: newId(),
      threadId: threadId,
      reason: 'Stopped from HarmonyOS',
    };
    await this.linkForThread(threadId).dispatch(command);
  }

  /** Moves the read watermark like the desktop and iOS apps do when a thread is opened. */
  visitThread(threadId: string, seenUpTo: number = 0): void {
    // Never behind what was on screen: the server's clock may run ahead of the phone's.
    const command: VisitCommand = {
      type: 'thread.visit',
      commandId: newId(),
      threadId: threadId,
      visitedAt: new Date(Math.max(Date.now(), seenUpTo)).toISOString(),
      opened: true,
    };
    this.linkForThread(threadId).dispatchQuietly(command);
  }

  async simpleThreadCommand(type: string, threadId: string): Promise<void> {
    const command: ThreadCommand = { type: type, commandId: newId(), threadId: threadId };
    await this.linkForThread(threadId).dispatch(command);
  }

  /** Starts a thread on the computer that owns the project. */
  async launchThread(projectId: string, environmentId: string, text: string, model: ModelSelection, runtimeMode: string,
    interactionMode: string = 'default', attachments: ChatAttachment[] = []): Promise<string> {
    const link = this.links.get(environmentId) ?? this.linkForProject(projectId);
    const firstLine = text.trim().split('\n')[0];
    const input: LaunchThreadInput = {
      commandId: newId(),
      creationSource: 'mobile',
      threadId: newId(),
      projectId: projectId,
      title: firstLine.length > 60 ? firstLine.substring(0, 60) : (firstLine.length > 0 ? firstLine : '新任务'),
      generateTitle: true,
      modelSelection: model,
      runtimeMode: runtimeMode,
      interactionMode: interactionMode,
      workspaceStrategy: { type: 'root' },
      initialMessage: { messageId: newId(), text: text, attachments: attachments },
    };
    return await link.launch(input);
  }

  // ---- Workspace, usage and pull requests: plain RPCs on one computer ------------------------

  async rpc(environmentId: string, tag: string, payload: Object): Promise<Object | null> {
    return await this.linkFor(environmentId).request(tag, payload);
  }

  /** A server-relative path (signed asset URLs) as an absolute URL on that computer. */
  httpUrl(environmentId: string, relative: string): string {
    if (/^https?:\/\//.test(relative)) {
      return relative;
    }
    const base = (appState.environmentFor(environmentId)?.env.baseUrl ?? '').replace(/\/+$/, '');
    return `${base}${relative.startsWith('/') ? '' : '/'}${relative}`;
  }

  /** Headers that authorize a plain HTTP request to that computer (bearer, or DPoP over T3 Connect). */
  async authHeadersFor(environmentId: string, method: string, url: string): Promise<Record<string, string>> {
    const env = appState.environmentFor(environmentId)?.env;
    return env === undefined ? {} : await authorized(env, method, url);
  }

  rpcStream(environmentId: string, tag: string, payload: Object, onChunk: (values: Object[]) => void,
    onExit: (ok: boolean, value: Object | null, error: string) => void): string {
    const link = this.links.get(environmentId);
    if (link === undefined) {
      onExit(false, null, '这台电脑已移除');
      return '';
    }
    return link.stream(tag, payload, onChunk, onExit);
  }

  rpcInterrupt(environmentId: string, requestId: string): void {
    this.links.get(environmentId)?.interrupt(requestId);
  }

  async reloadConfig(environmentId: string): Promise<void> {
    await this.linkFor(environmentId).reloadConfig();
  }

  private linkFor(environmentId: string): EnvironmentConnection {
    const link = this.links.get(environmentId);
    if (link === undefined) {
      throw new ConnectionError('这台电脑已移除');
    }
    return link;
  }

  private linkForThread(threadId: string): EnvironmentConnection {
    const env = appState.environmentOfThread(threadId);
    const link = env !== null ? this.links.get(env.id) : undefined;
    if (link === undefined) {
      throw new ConnectionError('还没有连接任何电脑');
    }
    return link;
  }

  private linkForProject(projectId: string): EnvironmentConnection {
    const project = appState.projectFor(projectId);
    const link = this.links.get(project?.environmentId ?? '') ??
      (appState.environments.length > 0 ? this.links.get(appState.environments[0].id) : undefined);
    if (link === undefined) {
      throw new ConnectionError('还没有连接任何电脑');
    }
    return link;
  }
}

export const connection: ConnectionService = new ConnectionService();
