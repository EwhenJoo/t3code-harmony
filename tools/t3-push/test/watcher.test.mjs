import assert from "node:assert/strict";
import NodeCrypto from "node:crypto";
import { test } from "node:test";
import { notifyIdFor, signJwt } from "../src/huawei.mjs";
import { parsePairingInput } from "../src/t3.mjs";
import { describe, threadLink, ThreadWatcher } from "../src/watcher.mjs";

const thread = (id, fields = {}) => ({ id, title: `T ${id}`, projectId: "p1", status: "completed", ...fields });
const snapshot = (threads) => ({ kind: "snapshot", snapshot: { threads, projects: [{ id: "p1", title: "web" }] } });
const updated = (t) => ({ kind: "thread.updated", thread: t });

function watcher() {
  const events = [];
  return { events, w: new ThreadWatcher((e) => events.push(e)) };
}

test("the first snapshot is history", () => {
  const { events, w } = watcher();
  w.apply("e1", "PC", [snapshot([thread("a", { status: "running" }), thread("b", { pendingRuntimeRequest: { id: "r1", kind: "approval" } })])]);
  assert.equal(events.length, 0);
});

test("reports approvals, questions, completion and failure once each", () => {
  const { events, w } = watcher();
  w.apply("e1", "PC", [snapshot([thread("a", { status: "running" }), thread("b", { status: "running" }), thread("c", { status: "running" })])]);
  w.apply("e1", "PC", [updated(thread("a", { status: "running", pendingRuntimeRequest: { id: "r1", kind: "command" } }))]);
  w.apply("e1", "PC", [updated(thread("b", { status: "running", pendingRuntimeRequest: { id: "q1", kind: "user_input" } }))]);
  w.apply("e1", "PC", [updated(thread("a", { status: "completed" }))]);
  w.apply("e1", "PC", [updated(thread("c", { status: "failed" }))]);
  // Same state again: nothing new.
  w.apply("e1", "PC", [updated(thread("c", { status: "failed" }))]);
  assert.deepEqual(events.map((e) => `${e.thread.id}:${e.kind}`), ["a:approval", "b:input", "a:done", "c:failed"]);
  assert.equal(describe(events[0]).body, "需要你批准 · web · PC");
  assert.equal(describe(events[2]).title, "T a");
});

test("real T3 runs: queued with an active run, then completed (or stopped)", () => {
  const { events, w } = watcher();
  const queued = (id) => thread(id, { status: "queued", activeRunId: `run-${id}`, activityRunStatus: "running", latestRunId: `run-${id}` });
  w.apply("e1", "PC", [snapshot([queued("a"), queued("b"), thread("c", { status: "idle" })])]);
  w.apply("e1", "PC", [updated(thread("a", { status: "completed", activeRunId: null, latestRunId: "run-a" }))]);
  w.apply("e1", "PC", [updated(thread("b", { status: "interrupted", activeRunId: null, latestRunId: "run-b" }))]);
  // Same run reported again: no second notice.
  w.apply("e1", "PC", [updated(thread("a", { status: "completed", activeRunId: null, latestRunId: "run-a" }))]);
  assert.deepEqual(events.map((e) => `${e.thread.id}:${e.kind}`), ["a:done"]);
});

test("skips subagents, archived threads and snoozed completions", () => {
  const { events, w } = watcher();
  w.apply("e1", "PC", [snapshot([
    thread("s", { status: "running", lineage: { relationshipToParent: "subagent" } }),
    thread("z", { status: "running", snoozedUntil: new Date(Date.now() + 3_600_000).toISOString() }),
  ])]);
  w.apply("e1", "PC", [updated(thread("s", { status: "completed", lineage: { relationshipToParent: "subagent" } }))]);
  w.apply("e1", "PC", [updated(thread("z", { status: "completed", snoozedUntil: new Date(Date.now() + 3_600_000).toISOString() }))]);
  w.apply("e1", "PC", [{ kind: "thread.updated", location: "archive", thread: thread("z") }]);
  assert.equal(events.length, 0);
});

test("a thread that finished while disconnected is reported by the next snapshot", () => {
  const { events, w } = watcher();
  w.apply("e1", "PC", [snapshot([thread("a", { status: "running" })])]);
  w.apply("e1", "PC", [snapshot([thread("a", { status: "completed" })])]);
  assert.deepEqual(events.map((e) => e.kind), ["done"]);
});

test("pairing links in every shape", () => {
  assert.deepEqual(parsePairingInput("http://100.101.1.2:3773/pair#token=abc"), { baseUrl: "http://100.101.1.2:3773", token: "abc", label: "" });
  const app = `t3code://pair?pairingUrl=${encodeURIComponent("http://pc.tail.ts.net:3773/pair?label=Mac#token=xyz")}`;
  assert.deepEqual(parsePairingInput(app), { baseUrl: "http://pc.tail.ts.net:3773", token: "xyz", label: "Mac" });
  assert.equal(parsePairingInput("").token, "");
});

test("deep link and notify id", () => {
  assert.equal(threadLink("env 1", "t/2"), "t3code://thread?id=t%2F2&env=env%201");
  assert.equal(notifyIdFor("e:t"), notifyIdFor("e:t"));
  assert.ok(notifyIdFor("e:t") >= 0 && notifyIdFor("e:t") <= 0x7fffffff);
});

test("the Push Kit JWT is PS256 and verifies with the public key", () => {
  const { privateKey, publicKey } = NodeCrypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwt = signJwt({ keyId: "k1", subAccount: "sub", privateKey: privateKey.export({ type: "pkcs8", format: "pem" }) }, 1_000_000);
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "PS256", typ: "JWT", kid: "k1" });
  assert.equal(JSON.parse(Buffer.from(p, "base64url")).iss, "sub");
  const ok = NodeCrypto.verify("sha256", Buffer.from(`${h}.${p}`), {
    key: publicKey,
    padding: NodeCrypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: 32,
  }, Buffer.from(s, "base64url"));
  assert.ok(ok);
});
