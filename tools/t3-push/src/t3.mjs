// A T3 Code client, as far as the helper needs one: pair with a computer (the same one-time code the
// phone uses), then keep `orchestration.subscribeShell` open over the Effect RPC WebSocket.
//
// Frames (JSON over /ws):
//   client  {_tag:"Request", id, tag, payload, headers:[]} | {_tag:"Ack", requestId} | {_tag:"Ping"}
//   server  {_tag:"Chunk", requestId, values:[...]} | {_tag:"Exit", requestId, exit} | {_tag:"Pong"}
// Every Chunk is acknowledged before the server sends the next one on that stream.
import NodeOS from "node:os";

export const ORCHESTRATION_PROTOCOL = "2";
const PING_INTERVAL_MS = 5_000;
// Generous: links relayed through Tailscale DERP can stall for several seconds.
const SILENCE_TIMEOUT_MS = 45_000;
const MAX_BACKOFF_MS = 60_000;
const UNAUTHORIZED_RETRY_MS = 5 * 60_000;

function readParam(query, name) {
  if (!query) return "";
  try {
    return new URLSearchParams(query).get(name) ?? "";
  } catch {
    return "";
  }
}

function originOf(value) {
  try {
    const url = new URL(value.includes("://") ? value : `http://${value}`);
    return url.origin;
  } catch {
    return "";
  }
}

/** Accepts `http://host:port/pair#token=…`, `?token=`, or the desktop QR's `t3code://pair?pairingUrl=…`. */
export function parsePairingInput(input) {
  let value = String(input ?? "").trim();
  const result = { baseUrl: "", token: "", label: "" };
  if (!value) return result;
  if (value.startsWith("t3code") && value.includes("://pair")) {
    const q = value.indexOf("?");
    const inner = q >= 0 ? readParam(value.slice(q + 1), "pairingUrl") : "";
    if (inner) value = inner;
  }
  const hashIdx = value.indexOf("#");
  const hash = hashIdx >= 0 ? value.slice(hashIdx + 1) : "";
  const beforeHash = hashIdx >= 0 ? value.slice(0, hashIdx) : value;
  const qIdx = beforeHash.indexOf("?");
  const query = qIdx >= 0 ? beforeHash.slice(qIdx + 1) : "";
  result.token = readParam(hash, "token") || readParam(query, "token");
  result.label = readParam(query, "label");
  const hostedHost = readParam(query, "host");
  result.baseUrl = hostedHost ? originOf(hostedHost) : originOf(beforeHash);
  return result;
}

function osName() {
  return { win32: "Windows", darwin: "macOS", linux: "Linux" }[process.platform] ?? process.platform;
}

export async function fetchDescriptor(baseUrl, fetcher = fetch) {
  let res;
  try {
    res = await fetcher(`${baseUrl}/.well-known/t3/environment`, { signal: AbortSignal.timeout(30_000) });
  } catch (error) {
    throw new Error(`无法连接 ${baseUrl}：${error.cause?.code ?? error.message}`);
  }
  if (!res.ok) throw new Error(`${baseUrl} 不是可用的 T3 服务（HTTP ${res.status}）`);
  return await res.json();
}

/** Exchanges a one-time pairing code for a long-lived access token. */
export async function pairComputer(input, { label = "" } = {}, fetcher = fetch) {
  const target = parsePairingInput(input);
  if (!target.baseUrl || !target.token) {
    throw new Error("配对链接里没有找到服务器地址或配对码（应形如 http://主机:端口/pair#token=…）");
  }
  const descriptor = await fetchDescriptor(target.baseUrl, fetcher);
  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: target.token,
    subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    client_label: `T3 推送小助手 (${NodeOS.hostname()})`,
    client_device_type: "bot",
    client_os: osName(),
  });
  const res = await fetcher(`${target.baseUrl}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) throw new Error(`配对失败（HTTP ${res.status}），配对码可能已用过或已过期`);
  const token = await res.json();
  if (!token.access_token) throw new Error("服务器没有返回访问令牌");
  return {
    id: descriptor.environmentId,
    label: label || target.label || descriptor.label || target.baseUrl,
    baseUrl: target.baseUrl,
    accessToken: token.access_token,
    serverVersion: descriptor.serverVersion ?? "",
    addedAt: new Date().toISOString(),
  };
}

function socketUrl(baseUrl) {
  const ws = baseUrl.replace(/^https:/, "wss:").replace(/^http:/, "ws:");
  const match = /^(wss?:\/\/[^/?#]+)([^?#]*)/.exec(ws);
  if (!match) return `${ws}/ws`;
  const path = match[2] ?? "";
  return `${match[1]}${!path || path === "/" ? "/ws" : path}`;
}

/**
 * One computer's live connection. Calls `onItems(values)` with shell stream items and
 * `onState(state, detail)` with 'connecting' | 'connected' | 'offline' | 'unauthorized'.
 */
export class EnvironmentLink {
  constructor(computer, { onItems, onState = () => {}, log = () => {}, WebSocketImpl = globalThis.WebSocket, fetcher = fetch } = {}) {
    this.computer = computer;
    this.onItems = onItems;
    this.onState = onState;
    this.log = log;
    this.WebSocketImpl = WebSocketImpl;
    this.fetcher = fetcher;
    this.ws = null;
    this.stopped = false;
    this.attempt = 0;
    this.timer = null;
    this.pingTimer = null;
    this.lastFrameAt = 0;
    this.nextId = 1;
    this.calls = new Map();
    this.state = "offline";
  }

  start() {
    this.stopped = false;
    this.connect();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.closeSocket();
  }

  setState(state, detail = "") {
    if (this.state === state && !detail) return;
    this.state = state;
    this.onState(state, detail);
  }

  async connect() {
    if (this.stopped) return;
    this.setState("connecting");
    const { baseUrl, accessToken } = this.computer;
    try {
      const ticketRes = await this.fetcher(`${baseUrl}/api/auth/websocket-ticket/rpc`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "x-t3-orchestration-protocol": ORCHESTRATION_PROTOCOL,
          accept: "application/json",
        },
        signal: AbortSignal.timeout(30_000),
      });
      if (ticketRes.status === 401 || ticketRes.status === 403) {
        this.setState("unauthorized", "访问令牌已失效，请用 t3-push add 重新配对这台电脑");
        this.schedule(UNAUTHORIZED_RETRY_MS);
        return;
      }
      if (!ticketRes.ok) throw new Error(`HTTP ${ticketRes.status}`);
      const { ticket } = await ticketRes.json();
      const params = new URLSearchParams({
        wsTicket: ticket,
        orchestrationProtocol: ORCHESTRATION_PROTOCOL,
        clientDeviceType: "bot",
        connectionMethod: "direct",
      });
      await this.openSocket(`${socketUrl(baseUrl)}?${params}`);
    } catch (error) {
      if (this.stopped) return;
      this.setState("offline", error.cause?.code ?? error.message);
      this.attempt += 1;
      this.schedule(Math.min(MAX_BACKOFF_MS, 1_000 * 2 ** Math.min(this.attempt, 6)));
    }
  }

  schedule(ms) {
    clearTimeout(this.timer);
    if (!this.stopped) this.timer = setTimeout(() => this.connect(), ms);
  }

  openSocket(url) {
    return new Promise((resolve, reject) => {
      const ws = new this.WebSocketImpl(url);
      let opened = false;
      ws.onopen = () => {
        opened = true;
        this.ws = ws;
        this.attempt = 0;
        this.lastFrameAt = Date.now();
        this.setState("connected");
        this.startPing();
        this.subscribeShell();
        resolve();
      };
      ws.onmessage = (event) => this.onText(typeof event.data === "string" ? event.data : String(event.data));
      ws.onerror = () => {
        if (!opened) reject(new Error("WebSocket 连接失败"));
      };
      ws.onclose = () => {
        if (!opened) {
          reject(new Error("WebSocket 被关闭"));
          return;
        }
        if (this.ws === ws) this.onSocketLost("连接断开");
      };
    });
  }

  onSocketLost(reason) {
    this.closeSocket();
    if (this.stopped) return;
    this.setState("offline", reason);
    this.attempt += 1;
    this.schedule(Math.min(MAX_BACKOFF_MS, 1_000 * 2 ** Math.min(this.attempt, 6)));
  }

  closeSocket() {
    clearInterval(this.pingTimer);
    this.pingTimer = null;
    const ws = this.ws;
    this.ws = null;
    for (const call of this.calls.values()) call.onExit?.(false, null, "closed");
    this.calls.clear();
    if (ws) {
      ws.onclose = null;
      try {
        ws.close();
      } catch {
        // already closed
      }
    }
  }

  startPing() {
    clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => {
      if (Date.now() - this.lastFrameAt > SILENCE_TIMEOUT_MS) {
        this.onSocketLost("服务器无响应");
        return;
      }
      this.write({ _tag: "Ping" });
    }, PING_INTERVAL_MS);
  }

  write(frame) {
    if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(frame));
  }

  /** Streaming call; returns the request id. */
  stream(tag, payload, onChunk, onExit) {
    const id = String(this.nextId++);
    this.calls.set(id, { tag, onChunk, onExit });
    this.write({ _tag: "Request", id, tag, payload, headers: [] });
    return id;
  }

  subscribeShell() {
    this.stream(
      "orchestration.subscribeShell",
      { requestCompletionMarker: true },
      (values) => this.onItems(values),
      (ok, _value, error) => {
        // The shell stream never ends on its own; if it does, start over with a fresh snapshot.
        if (!this.stopped && this.ws) this.onSocketLost(ok ? "订阅结束" : `订阅失败：${error}`);
      },
    );
  }

  onText(text) {
    this.lastFrameAt = Date.now();
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      this.log(`${this.computer.label}: 无法解析的帧`);
      return;
    }
    for (const frame of Array.isArray(parsed) ? parsed : [parsed]) this.onFrame(frame);
  }

  onFrame(frame) {
    switch (frame?._tag) {
      case "Chunk": {
        this.write({ _tag: "Ack", requestId: frame.requestId });
        const call = this.calls.get(frame.requestId);
        if (call?.onChunk && Array.isArray(frame.values)) {
          try {
            call.onChunk(frame.values);
          } catch (error) {
            this.log(`${this.computer.label}: 处理事件出错 ${error.stack ?? error}`);
          }
        }
        break;
      }
      case "Exit": {
        const call = this.calls.get(frame.requestId);
        this.calls.delete(frame.requestId);
        const ok = frame.exit?._tag === "Success";
        call?.onExit?.(ok, ok ? frame.exit?.value ?? null : null, ok ? "" : JSON.stringify(frame.exit?.cause ?? frame.exit));
        break;
      }
      case "Defect":
      case "ClientProtocolError":
        this.log(`${this.computer.label}: 服务器报告 ${frame._tag}`);
        break;
      default:
        break;
    }
  }
}
