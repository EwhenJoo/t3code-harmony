import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Log } from '../common/Log';

/**
 * Effect RPC client over a WebSocket using the JSON serialization the T3 server mounts at /ws.
 *
 * Client frames:  {_tag:"Request", id, tag, payload, headers:[]} | {_tag:"Ack", requestId}
 *                 {_tag:"Interrupt", requestId} | {_tag:"Ping"}
 * Server frames:  {_tag:"Chunk", requestId, values:[...]} | {_tag:"Exit", requestId, exit}
 *                 {_tag:"Pong"} | {_tag:"Defect", defect} | {_tag:"ClientProtocolError"}
 * Every Chunk must be acknowledged before the server sends the next one for that stream.
 */

const TAG = 'RpcSocket';
const PING_INTERVAL_MS = 5000;
const SILENCE_TIMEOUT_MS = 15000;

export type ChunkHandler = (values: Object[]) => void;
export type ExitHandler = (ok: boolean, value: Object | null, error: string) => void;
export type CloseHandler = (reason: string) => void;

interface RpcRequestFrame {
  _tag: string;
  id: string;
  tag: string;
  payload: Object;
  headers: string[][];
}

interface RpcAckFrame {
  _tag: string;
  requestId: string;
}

interface RpcPingFrame {
  _tag: string;
}

interface ExitCause {
  _tag: string;
  error?: Object;
  defect?: Object;
}

interface ExitEncoded {
  _tag: string;
  value?: Object;
  cause?: ExitCause[];
}

interface ServerFrame {
  _tag: string;
  requestId?: string | number;
  values?: Object[];
  exit?: ExitEncoded;
  defect?: Object;
  error?: Object;
}

class PendingCall {
  tag: string;
  onChunk?: ChunkHandler;
  onExit: ExitHandler;

  constructor(tag: string, onExit: ExitHandler, onChunk?: ChunkHandler) {
    this.tag = tag;
    this.onExit = onExit;
    this.onChunk = onChunk;
  }
}

export class RpcRemoteError extends Error {
  constructor(message: string) {
    super(message);
  }
}

function describeCause(exit: ExitEncoded | undefined): string {
  if (!exit || !exit.cause || exit.cause.length === 0) {
    return 'Request failed';
  }
  const first = exit.cause[0];
  const payload = first.error ?? first.defect;
  if (payload === undefined || payload === null) {
    return first._tag;
  }
  if (typeof payload === 'string') {
    return payload as string;
  }
  const record = payload as Record<string, Object>;
  const message = record['message'];
  const tag = record['_tag'];
  if (typeof message === 'string') {
    return (typeof tag === 'string' ? `${tag as string}: ` : '') + (message as string);
  }
  return JSON.stringify(payload).substring(0, 200);
}

export class RpcSocket {
  private ws: webSocket.WebSocket | null = null;
  private nextId: number = 1;
  private calls: Map<string, PendingCall> = new Map();
  private buffer: string = '';
  private pingTimer: number = -1;
  private lastFrameAt: number = 0;
  private closed: boolean = false;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  onClose?: CloseHandler;

  connect(url: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      let opened = false;
      ws.on('open', () => {
        opened = true;
        this.lastFrameAt = Date.now();
        this.startPing();
        resolve();
      });
      ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
        if (err) {
          return;
        }
        const text = typeof data === 'string' ? data as string : this.decoder.decodeToString(new Uint8Array(data as ArrayBuffer));
        this.onText(text);
      });
      ws.on('close', (err: BusinessError, result: webSocket.CloseResult) => {
        const reason = `closed ${result?.code ?? ''} ${result?.reason ?? ''}`.trim();
        if (!opened) {
          reject(new RpcRemoteError(reason));
        }
        this.teardown(reason);
      });
      ws.on('error', (err: BusinessError) => {
        const reason = `socket error ${err?.code ?? ''} ${err?.message ?? ''}`.trim();
        Log.w(TAG, reason);
        if (!opened) {
          reject(new RpcRemoteError(reason));
        }
        this.teardown(reason);
      });
      ws.connect(url, (err: BusinessError) => {
        if (err) {
          reject(new RpcRemoteError(`connect failed ${err.code} ${err.message}`));
        }
      });
    });
  }

  get isOpen(): boolean {
    return this.ws !== null && !this.closed;
  }

  /** Unary call: resolves with the Exit success value. */
  request(tag: string, payload: Object): Promise<Object | null> {
    return new Promise<Object | null>((resolve, reject) => {
      this.send(tag, payload, (ok: boolean, value: Object | null, error: string) => {
        if (ok) {
          resolve(value);
        } else {
          reject(new RpcRemoteError(error));
        }
      });
    });
  }

  /** Streaming call: chunks arrive through onChunk until onExit. Returns the request id. */
  stream(tag: string, payload: Object, onChunk: ChunkHandler, onExit: ExitHandler): string {
    return this.send(tag, payload, onExit, onChunk);
  }

  interrupt(requestId: string): void {
    if (!this.calls.has(requestId)) {
      return;
    }
    this.calls.delete(requestId);
    const frame: RpcAckFrame = { _tag: 'Interrupt', requestId: requestId };
    this.write(JSON.stringify(frame));
  }

  close(): void {
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (e) {
        Log.w(TAG, `close failed ${JSON.stringify(e)}`);
      }
    }
    this.teardown('client closed');
  }

  private send(tag: string, payload: Object, onExit: ExitHandler, onChunk?: ChunkHandler): string {
    const id = String(this.nextId++);
    if (!this.isOpen) {
      onExit(false, null, 'Not connected');
      return id;
    }
    this.calls.set(id, new PendingCall(tag, onExit, onChunk));
    const frame: RpcRequestFrame = { _tag: 'Request', id: id, tag: tag, payload: payload, headers: [] };
    this.write(JSON.stringify(frame));
    return id;
  }

  private write(text: string): void {
    if (this.ws === null || this.closed) {
      return;
    }
    this.ws.send(text).catch((e: BusinessError) => {
      Log.w(TAG, `send failed ${e.code} ${e.message}`);
    });
  }

  private onText(text: string): void {
    this.lastFrameAt = Date.now();
    // Large frames can arrive split across several message events; buffer until valid JSON.
    this.buffer = this.buffer.length > 0 ? this.buffer + text : text;
    const trimmed = this.buffer.trimEnd();
    const last = trimmed.length > 0 ? trimmed.charAt(trimmed.length - 1) : '';
    if (last !== '}' && last !== ']') {
      return;
    }
    let parsed: ServerFrame | ServerFrame[];
    try {
      parsed = JSON.parse(trimmed) as ServerFrame | ServerFrame[];
    } catch (e) {
      if (this.buffer.length > 64 * 1024 * 1024) {
        Log.e(TAG, 'dropping oversized unparsable buffer');
        this.buffer = '';
      }
      return;
    }
    this.buffer = '';
    if (Array.isArray(parsed)) {
      (parsed as ServerFrame[]).forEach((frame: ServerFrame) => this.onFrame(frame));
    } else {
      this.onFrame(parsed as ServerFrame);
    }
  }

  private onFrame(frame: ServerFrame): void {
    switch (frame._tag) {
      case 'Chunk': {
        const id = String(frame.requestId);
        const ack: RpcAckFrame = { _tag: 'Ack', requestId: id };
        this.write(JSON.stringify(ack));
        const call = this.calls.get(id);
        if (call && call.onChunk && frame.values) {
          try {
            call.onChunk(frame.values);
          } catch (e) {
            Log.e(TAG, `chunk handler failed for ${call.tag}: ${JSON.stringify(e)} ${(e as Error)?.stack ?? ''}`);
          }
        }
        break;
      }
      case 'Exit': {
        const id = String(frame.requestId);
        const call = this.calls.get(id);
        this.calls.delete(id);
        if (call) {
          const ok = frame.exit?._tag === 'Success';
          call.onExit(ok, ok ? (frame.exit?.value ?? null) : null, ok ? '' : describeCause(frame.exit));
        }
        break;
      }
      case 'Pong':
        break;
      case 'Defect':
      case 'ClientProtocolError': {
        Log.e(TAG, `${frame._tag}: ${JSON.stringify(frame.defect ?? frame.error ?? '').substring(0, 300)}`);
        break;
      }
      default:
        break;
    }
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (Date.now() - this.lastFrameAt > SILENCE_TIMEOUT_MS) {
        Log.w(TAG, 'socket silent, dropping');
        this.close();
        return;
      }
      const ping: RpcPingFrame = { _tag: 'Ping' };
      this.write(JSON.stringify(ping));
    }, PING_INTERVAL_MS);
  }

  private stopPing(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  private teardown(reason: string): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.stopPing();
    const pending = Array.from(this.calls.values());
    this.calls.clear();
    pending.forEach((call: PendingCall) => {
      try {
        call.onExit(false, null, `Connection lost (${reason})`);
      } catch (e) {
        Log.w(TAG, 'exit handler failed during teardown');
      }
    });
    if (this.ws !== null) {
      this.ws.off('open');
      this.ws.off('message');
      this.ws.off('close');
      this.ws.off('error');
    }
    this.ws = null;
    if (this.onClose) {
      this.onClose(reason);
    }
  }
}
