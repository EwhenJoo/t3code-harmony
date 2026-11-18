// `t3-push run`: one EnvironmentLink per computer, a ThreadWatcher over all of them, Push Kit for
// delivery, and a small HTTP endpoint the phone uses to hand over its push token.
import NodeCrypto from "node:crypto";
import NodeFS from "node:fs";
import NodeHttp from "node:http";
import NodeOS from "node:os";
import NodePath from "node:path";
import { configDir, configPath, loadConfig, saveConfig } from "./config.mjs";
import { DEAD_TOKEN_CODES, loadServiceAccount, makePushClient, notifyIdFor } from "./huawei.mjs";
import { EnvironmentLink } from "./t3.mjs";
import { describe, threadLink, ThreadWatcher } from "./watcher.mjs";

const RELOAD_INTERVAL_MS = 5_000;
/** Peers get the full device list again this often, in case one was down when a phone bound. */
const PEER_SYNC_INTERVAL_MS = 10 * 60_000;
const MAX_BODY = 16 * 1024;

function makeLogger() {
  const file = NodePath.join(configDir(), "t3-push.log");
  return (line) => {
    const text = `${new Date().toISOString()} ${line}`;
    console.log(text);
    try {
      NodeFS.mkdirSync(configDir(), { recursive: true });
      const size = NodeFS.existsSync(file) ? NodeFS.statSync(file).size : 0;
      if (size > 1024 * 1024) NodeFS.renameSync(file, `${file}.1`);
      NodeFS.appendFileSync(file, `${text}\n`);
    } catch {
      // logging must never take the helper down
    }
  };
}

function keyMatches(expected, given) {
  const a = Buffer.from(String(expected));
  const b = Buffer.from(String(given ?? ""));
  return a.length === b.length && NodeCrypto.timingSafeEqual(a, b);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error("too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {});
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function reply(res, status, value) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(value));
}

export class Daemon {
  constructor({ log = makeLogger() } = {}) {
    this.log = log;
    this.config = null;
    this.links = new Map();
    this.states = new Map();
    this.ledger = new Map();
    this.push = null;
    this.watcher = new ThreadWatcher((event) => this.onEvent(event));
    this.configStamp = "";
  }

  async start() {
    this.config = await loadConfig();
    await saveConfig(this.config);
    this.configStamp = this.stamp();
    await this.preparePush();
    this.syncLinks();
    this.server = NodeHttp.createServer((req, res) => {
      this.handle(req, res).catch((error) => {
        this.log(`HTTP 处理出错 ${error.message}`);
        if (!res.headersSent) reply(res, 400, { ok: false, error: "bad request" });
      });
    });
    const { host, port } = this.config.listen;
    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(port, host, resolve);
    });
    this.log(`推送小助手已启动：监听 ${host}:${port}，${this.config.computers.length} 台电脑，${this.config.devices.length} 台手机`);
    if (!this.push) this.log("还没有配置 Push Kit（运行 t3-push setup），只会记录事件，不会推送");
    this.reloadTimer = setInterval(() => this.reloadIfChanged(), RELOAD_INTERVAL_MS);
    this.peerTimer = setInterval(() => this.syncPeers(), PEER_SYNC_INTERVAL_MS);
    this.syncPeers();
  }

  /**
   * Other helpers (e.g. one on a Linux server watching its own T3) need the same phones. A phone
   * binds here once; its registration is forwarded to every peer over the tailnet.
   */
  async forwardToPeer(peer, method, path, body) {
    const res = await fetch(`${peer.url}${path}`, {
      method,
      headers: { "content-type": "application/json", "x-t3-push-key": peer.key },
      body: body ? JSON.stringify({ ...body, key: peer.key }) : undefined,
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  }

  async syncPeers(only = null) {
    for (const peer of this.config.peers ?? []) {
      const devices = only ? [only] : this.config.devices;
      let synced = 0;
      for (const device of devices) {
        try {
          await this.forwardToPeer(peer, "POST", "/v1/devices", { token: device.token, deviceId: device.id, label: device.label });
          synced += 1;
        } catch (error) {
          this.log(`同步手机到 ${peer.name || peer.url} 失败：${error.cause?.code ?? error.message}（稍后重试）`);
          break;
        }
      }
      if (synced > 0 && (only || this.peerSynced?.get(peer.url) !== synced)) {
        this.log(`已把 ${synced} 台手机同步给 ${peer.name || peer.url}`);
      }
      this.peerSynced = this.peerSynced ?? new Map();
      this.peerSynced.set(peer.url, synced);
    }
  }

  stop() {
    clearInterval(this.reloadTimer);
    clearInterval(this.peerTimer);
    for (const link of this.links.values()) link.stop();
    this.links.clear();
    this.server?.close();
  }

  stamp() {
    try {
      const s = NodeFS.statSync(configPath());
      return `${s.mtimeMs}:${s.size}`;
    } catch {
      return "";
    }
  }

  /** Picks up `t3-push add / remove / setup` made while the helper runs. */
  async reloadIfChanged() {
    const stamp = this.stamp();
    if (stamp === this.configStamp) return;
    this.configStamp = stamp;
    try {
      const peersBefore = JSON.stringify(this.config.peers ?? []);
      this.config = await loadConfig();
      await this.preparePush();
      this.syncLinks();
      if (JSON.stringify(this.config.peers) !== peersBefore) this.syncPeers();
    } catch (error) {
      this.log(`重新读取配置失败 ${error.message}`);
    }
  }

  async preparePush() {
    const push = this.config.push;
    if (!push?.projectId || !push?.serviceAccountFile) {
      this.push = null;
      return;
    }
    const account = await loadServiceAccount(push.serviceAccountFile);
    this.push = makePushClient({
      projectId: push.projectId,
      account,
      category: push.category ?? "WORK",
      testMessage: push.testMessage !== false,
    });
  }

  syncLinks() {
    const wanted = new Map(this.config.computers.map((c) => [c.id, c]));
    for (const [id, link] of this.links) {
      const next = wanted.get(id);
      if (!next || next.accessToken !== link.computer.accessToken || next.baseUrl !== link.computer.baseUrl) {
        link.stop();
        this.links.delete(id);
        this.states.delete(id);
      }
    }
    for (const computer of wanted.values()) {
      if (this.links.has(computer.id)) continue;
      const link = new EnvironmentLink(computer, {
        onItems: (items) => this.watcher.apply(computer.id, computer.label, items),
        onState: (state, detail) => {
          this.states.set(computer.id, { state, detail });
          this.log(`${computer.label}: ${state}${detail ? `（${detail}）` : ""}`);
        },
        log: this.log,
      });
      this.links.set(computer.id, link);
      link.start();
    }
  }

  async onEvent(event) {
    const message = describe(event);
    this.log(`${event.envLabel}: ${message.title} — ${message.body}`);
    if (!this.push) return;
    const key = `${event.envId}:${event.thread.id}`;
    const notifyId = notifyIdFor(key);
    const uri = threadLink(event.envId, event.thread.id);
    for (const device of this.config.devices) {
      const ledgerKey = `${device.id}:${key}`;
      if (this.ledger.get(ledgerKey) === event.identity) continue;
      this.ledger.set(ledgerKey, event.identity);
      // Already logged; one phone's failure must not hold back the others.
      await this.deliver(device, { ...message, uri, notifyId }).catch(() => {});
    }
  }

  async deliver(device, message) {
    try {
      await this.push.send(device.token, message);
      this.log(`已推送到 ${device.label}`);
    } catch (error) {
      this.log(`推送到 ${device.label} 失败：${error.message}`);
      if (DEAD_TOKEN_CODES.has(error.code)) {
        this.config.devices = this.config.devices.filter((d) => d.id !== device.id);
        await saveConfig(this.config);
        this.configStamp = this.stamp();
        this.log(`${device.label} 的推送令牌已失效，已移除；在手机上重新绑定即可`);
      }
      throw error;
    }
  }

  status() {
    return {
      ok: true,
      name: NodeOS.hostname(),
      push: Boolean(this.push),
      computers: this.config.computers.map((c) => ({
        id: c.id,
        label: c.label,
        state: this.states.get(c.id)?.state ?? "offline",
      })),
      devices: this.config.devices.map((d) => ({ id: d.id, label: d.label })),
    };
  }

  async handle(req, res) {
    const url = new URL(req.url, "http://helper");
    const key = req.headers["x-t3-push-key"];
    if (req.method === "GET" && url.pathname === "/v1/status") {
      if (!keyMatches(this.config.bindKey, key)) return reply(res, 403, { ok: false, error: "bad key" });
      return reply(res, 200, this.status());
    }
    if (req.method === "POST" && url.pathname === "/v1/devices") {
      const body = await readJson(req);
      if (!keyMatches(this.config.bindKey, body.key ?? key)) return reply(res, 403, { ok: false, error: "bad key" });
      const token = String(body.token ?? "").trim();
      const id = String(body.deviceId ?? "").trim();
      if (!token || token.length > 4096 || !id || id.length > 128) {
        return reply(res, 400, { ok: false, error: "missing token or deviceId" });
      }
      const label = String(body.label ?? "手机").slice(0, 64);
      const others = this.config.devices.filter((d) => d.id !== id && d.token !== token);
      this.config.devices = [...others, { id, token, label, updatedAt: new Date().toISOString() }];
      await saveConfig(this.config);
      this.configStamp = this.stamp();
      this.log(`已绑定手机：${label}`);
      this.syncPeers({ id, token, label });
      return reply(res, 200, this.status());
    }
    if (req.method === "DELETE" && url.pathname.startsWith("/v1/devices/")) {
      if (!keyMatches(this.config.bindKey, key)) return reply(res, 403, { ok: false, error: "bad key" });
      const id = decodeURIComponent(url.pathname.slice("/v1/devices/".length));
      this.config.devices = this.config.devices.filter((d) => d.id !== id);
      await saveConfig(this.config);
      this.configStamp = this.stamp();
      this.log(`已解绑手机 ${id}`);
      for (const peer of this.config.peers ?? []) {
        this.forwardToPeer(peer, "DELETE", `/v1/devices/${encodeURIComponent(id)}`)
          .catch((error) => this.log(`通知 ${peer.name || peer.url} 解绑失败：${error.message}`));
      }
      return reply(res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/v1/test") {
      const body = await readJson(req);
      if (!keyMatches(this.config.bindKey, body.key ?? key)) return reply(res, 403, { ok: false, error: "bad key" });
      if (!this.push) return reply(res, 409, { ok: false, error: "push not configured" });
      const device = this.config.devices.find((d) => d.id === body.deviceId);
      if (!device) return reply(res, 404, { ok: false, error: "device not bound" });
      try {
        await this.deliver(device, { title: "T3 推送小助手", body: `来自 ${NodeOS.hostname()} 的测试通知`, notifyId: 1 });
        return reply(res, 200, { ok: true });
      } catch (error) {
        return reply(res, 502, { ok: false, error: error.message });
      }
    }
    return reply(res, 404, { ok: false, error: "not found" });
  }
}
