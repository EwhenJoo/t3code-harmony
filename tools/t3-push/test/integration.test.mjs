// End to end against the mock T3 server (tools/mock-t3/server.mjs): pair with the one-time code,
// subscribe to the shell, and see a run that finishes turn into a "done" event.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import NodePath from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { EnvironmentLink, pairComputer } from "../src/t3.mjs";
import { ThreadWatcher } from "../src/watcher.mjs";

const here = NodePath.dirname(fileURLToPath(import.meta.url));
const MOCK = NodePath.resolve(here, "..", "..", "mock-t3", "server.mjs");
const PORT = 3899;

async function waitFor(predicate, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out waiting for ${what}`);
}

test("pairs with a computer and reports a finished run", { timeout: 30_000 }, async (t) => {
  const mock = spawn(process.execPath, [MOCK, "--port", String(PORT)], { stdio: "ignore" });
  t.after(() => mock.kill());
  await waitFor(async () => {
    try {
      return (await fetch(`http://127.0.0.1:${PORT}/.well-known/t3/environment`)).ok;
    } catch {
      return false;
    }
  }, 10_000, "mock server");

  await assert.rejects(pairComputer(`http://127.0.0.1:${PORT}/pair#token=wrong`), /配对失败/);
  const computer = await pairComputer(`http://127.0.0.1:${PORT}/pair#token=mock-pair`, { label: "测试机" });
  assert.equal(computer.label, "测试机");
  assert.ok(computer.accessToken);

  const events = [];
  const watcher = new ThreadWatcher((e) => events.push(e));
  const states = [];
  const link = new EnvironmentLink(computer, {
    onItems: (items) => watcher.apply(computer.id, computer.label, items),
    onState: (s) => states.push(s),
  });
  t.after(() => link.stop());
  link.start();
  await waitFor(() => watcher.envs.get(computer.id)?.primed, 10_000, "first snapshot");
  assert.ok(states.includes("connected"));

  // Opening the running thread makes the mock finish its run a few seconds later.
  link.stream("orchestration.subscribeThread", { threadId: "t-running", requestCompletionMarker: true }, () => {}, () => {});
  await waitFor(() => events.some((e) => e.thread.id === "t-running" && e.kind === "done"), 20_000, "done event");
  const done = events.find((e) => e.kind === "done");
  assert.equal(done.envId, computer.id);
  assert.equal(done.project?.title, "storefront-web");
});
