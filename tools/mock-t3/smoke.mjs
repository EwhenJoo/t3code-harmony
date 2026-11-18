// Smoke test for the mock server: pairing, snapshot, streams, and one command round trip.
const BASE = process.argv[2] ?? "http://127.0.0.1:3790";
const assert = (cond, msg) => { if (!cond) { console.error("FAIL", msg); process.exit(1); } console.log("ok  ", msg); };

await fetch(`${BASE}/__test/reset`, { method: "POST" });
const bad = await fetch(`${BASE}/oauth/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "subject_token=bad" });
assert(bad.status === 400, "bad pairing code is rejected");
const tok = await (await fetch(`${BASE}/oauth/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "subject_token=mock-pair&client_label=smoke" })).json();
assert(tok.access_token, "pairing code exchanges for a token");
const auth = { authorization: `Bearer ${tok.access_token}` };
const ticket = await (await fetch(`${BASE}/api/auth/websocket-ticket/rpc`, { method: "POST", headers: auth })).json();
assert(ticket.ticket, "ticket issued");

const ws = new WebSocket(`${BASE.replace("http", "ws")}/ws?wsTicket=${ticket.ticket}&orchestrationProtocol=2`);
const frames = [];
const waitFor = (pred, ms = 6000) => new Promise((resolve, reject) => {
  const start = Date.now();
  const tick = () => { const f = frames.find(pred); if (f) return resolve(f); if (Date.now() - start > ms) return reject(new Error("timeout")); setTimeout(tick, 50); };
  tick();
});
ws.onmessage = (e) => { const m = JSON.parse(e.data); frames.push(m); if (m._tag === "Chunk") ws.send(JSON.stringify({ _tag: "Ack", requestId: m.requestId })); };
await new Promise((r) => (ws.onopen = r));
ws.send(JSON.stringify({ _tag: "Request", id: "1", tag: "orchestration.subscribeShell", payload: {}, headers: [] }));
const snap = await waitFor((f) => f.requestId === "1" && f.values?.[0]?.kind === "snapshot");
assert(snap.values[0].snapshot.threads.length === 36, "shell snapshot has 36 threads");
ws.send(JSON.stringify({ _tag: "Request", id: "2", tag: "orchestration.subscribeThread", payload: { threadId: "t-inbox" }, headers: [] }));
await waitFor((f) => f.requestId === "2" && f.values?.[0]?.kind === "snapshot");
assert(true, "thread snapshot streamed");
ws.send(JSON.stringify({ _tag: "Request", id: "3", tag: "orchestration.dispatchCommand", payload: { type: "message.dispatch", commandId: "c1", threadId: "t-inbox", messageId: "m1", text: "你好", attachments: [], createdBy: "user", creationSource: "mobile", dispatchMode: { type: "start_immediately" } }, headers: [] }));
await waitFor((f) => f._tag === "Exit" && f.requestId === "3" && f.exit._tag === "Success");
assert(true, "message.dispatch acknowledged");
await waitFor((f) => f.requestId === "2" && f.values?.some((v) => v.event?.payload?.text === "收到：你好" && v.event.payload.streaming === false), 8000);
assert(true, "assistant reply streamed to completion");
await waitFor((f) => f.requestId === "1" && f.values?.some((v) => v.kind === "thread.updated" && v.thread.id === "t-inbox" && v.thread.status === "completed"));
assert(true, "shell stream reports the thread completed");
const st = await (await fetch(`${BASE}/__test/state`)).json();
assert(st.commands.some((c) => c.payload.type === "message.dispatch"), "command log records the dispatch");
ws.close();
console.log("smoke passed");
