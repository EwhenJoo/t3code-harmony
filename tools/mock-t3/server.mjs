// Mock T3 Code server for end-to-end UI tests of the HarmonyOS client.
// Speaks the same wire protocol as the real server (orchestration protocol 2, Effect RPC JSON
// over WebSocket) for the subset the client uses, with deterministic fixtures and scripted agent
// behaviour. Zero dependencies: includes a minimal RFC 6455 WebSocket server.
//
//   node tools/mock-t3/server.mjs [--port 3790]
//
// Test control endpoints:
//   POST /__test/reset   restore fixtures, clear the command log
//   GET  /__test/state   { commands: [...], threads: [...] }
//   POST /__test/drop    close every WebSocket (exercises reconnect)
//   POST /__test/outage?ms=3000  refuse new sockets for a while after dropping them

import http from "node:http";
import crypto from "node:crypto";
import { cs, dpopPrincipal, handleConnectRoutes, handleConnectTestRoutes, handleTunnelTokenExchange, resetConnect, verifyDpop } from "./connect.mjs";
import { createWorkspace } from "./workspace.mjs";

const PORT = Number(process.argv[process.argv.indexOf("--port") + 1]) || Number(process.env.MOCK_T3_PORT) || 3790;
// `--profile lab` plays a second computer (its own id, name, projects and threads), so two
// instances side by side exercise the client's multi-computer list.
const PROFILE = process.argv.includes("--profile") ? process.argv[process.argv.indexOf("--profile") + 1] : (process.env.MOCK_T3_PROFILE ?? "main");
const LAB = PROFILE === "lab";
const PAIRING_CODE = "mock-pair";
const ACCESS_TOKEN = "mock-access-token";

// ---------------------------------------------------------------------------------------------
// Fixtures

const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();
let seq = 1000;
const nextSeq = () => ++seq;

const DESCRIPTOR = {
  environmentId: LAB ? "lab-env" : "mock-env",
  label: LAB ? "实验室服务器" : "Mock 工作站",
  platform: { os: "windows", arch: "x64" },
  serverVersion: "0.1.10-mock",
  orchestrationProtocolVersion: 2,
  // The lab plays a computer whose platform has no local speech engine (cloud keys only).
  capabilities: { voiceTranscription: !LAB, cloudVoiceTranscription: true },
};

// Voice: the desktop's speech models on this computer and the cloud keys it holds.
function voiceState() {
  const model = (id, name, size, languages, extra = {}) => ({
    id, name, description: "", size, languages, accuracy: 0, speed: 0, recommended: false, supportsStreaming: false,
    supportsLanguageDetection: languages.length > 1, supportsTranslation: false, active: false, state: "downloadable", ...extra,
  });
  return {
    keys: LAB ? { openai: false, xai: false, openrouter: false } : { openai: true, xai: false, openrouter: true },
    modelId: "mock/sensevoice-small",
    models: [
      model("mock/sensevoice-small", "SenseVoice Small", 252e6, ["zh", "yue", "en", "ja", "ko"], { state: "installed" }),
      model("mock/whisper-small", "Whisper Small", 269e6, ["zh", "en", "ja", "ko", "fr", "de"], { state: "installed" }),
      model("mock/qwen3-asr", "Qwen3-ASR 0.6B", 850e6, ["zh", "en", "yue"], { recommended: true }),
      model("mock/parakeet-en", "Parakeet English", 731e6, ["en"], { recommended: true }),
    ],
  };
}

const SONNET = { instanceId: "claudeAgent", model: "claude-sonnet-5-5" };
const OPUS = { instanceId: "claudeAgent", model: "claude-opus-5-5" };
const CODEX = { instanceId: "codex", model: "gpt-6.1-sol" };

function project(id, title, color, icon) {
  return {
    id, title, hasCustomTitle: false, workspaceRoot: `C:\\code\\${title}`, repositoryIdentity: null,
    defaultModelSelection: null, projectIcon: { kind: "lucide", name: icon, color }, scripts: [],
    pinnedAt: null, archivedAt: null, createdAt: iso(-86400000 * 30), updatedAt: iso(-3600000),
  };
}

function shell(id, projectId, title, extra = {}) {
  return {
    createdBy: "user", creationSource: "web", id, projectId, title, providerInstanceId: "claudeAgent",
    modelSelection: OPUS, runtimeMode: "full-access", interactionMode: "default", branch: null,
    worktreePath: null, lineage: { parentThreadId: null, relationshipToParent: null, rootThreadId: id },
    activeRunId: null, activityRunStatus: null, latestRunId: null, status: "completed", lastError: null,
    pendingRuntimeRequest: null, latestVisibleMessage: null, latestUserMessageAt: iso(-600000),
    hasActionableProposedPlan: false, itemCount: 4, createdAt: iso(-7200000), updatedAt: iso(-600000),
    archivedAt: null, settledOverride: null, settledAt: null, unsettledAt: null, snoozedUntil: null,
    pinnedAt: null, lastVisitedAt: null, deletedAt: null, ...extra,
  };
}

let ordinal = 1;
function item(threadId, type, fields = {}) {
  const now = iso();
  return {
    id: `item-${crypto.randomUUID()}`, threadId, runId: `run-${threadId}`, parentItemId: null,
    ordinal: ordinal++, status: "completed", title: null, startedAt: now, completedAt: now,
    updatedAt: now, createdBy: "agent", creationSource: "provider", type, ...fields,
  };
}

const MARKDOWN_ANSWER = [
  "登录页的样式问题已经修好了。主要改动：",
  "",
  "1. 把 `LoginForm` 的栅格改成了 **flex 布局**，窄屏不再溢出",
  "2. 输入框统一使用 `--radius-md`",
  "3. 修复了深色模式下按钮文字对比度不足",
  "",
  "```css",
  ".login-form {",
  "  display: flex;",
  "  gap: 12px;",
  "}",
  "```",
  "",
  "> 建议之后再跑一次视觉回归测试。",
].join("\n");

let state;

/** The second computer: a different set of projects and threads (ids prefixed `l-`). */
function labState() {
  ordinal = 1;
  const projects = [
    // No icon at all: the client derives a monogram and color from the name, like the desktop.
    { ...project("p-ml", "trainer", "orange", "cpu"), projectIcon: null },
    { ...project("p-infra", "infra-ops", "gray", "server"), projectIcon: { kind: "monogram", text: "IO", color: "rose" } },
    // Same name as a project on the main computer: the phone shows the two as one group.
    { ...project("p-lab-web", "storefront-web", "blue", "store"), projectIcon: null },
  ];
  const threads = new Map();
  const details = new Map();
  const add = (s, items, requests = [], runs = []) => {
    threads.set(s.id, s);
    details.set(s.id, { items, requests, runs });
  };
  add(shell("l-running", "p-ml", "调优训练任务的学习率", {
    status: "running", activeRunId: "run-l-running", activityRunStatus: "running", updatedAt: iso(-40000), modelSelection: CODEX,
    providerInstanceId: "codex",
  }), [
    item("l-running", "user_message", { createdBy: "user", text: "把学习率调度换成 cosine，并对比两组实验。" }),
    item("l-running", "command_execution", { input: "python train.py --sched cosine", status: "running", completedAt: null }),
  ], [], [{ id: "run-l-running", ordinal: 1, status: "running", requestedAt: iso(-240000), startedAt: iso(-240000), completedAt: null }]);
  add(shell("l-inbox", "p-infra", "清理过期的 Docker 镜像", {
    status: "completed", updatedAt: iso(-420000),
    latestVisibleMessage: { id: "m-l-inbox", role: "assistant", text: "已清理 37 个镜像，释放 12.4 GB。", updatedAt: iso(-420000) },
  }), [
    item("l-inbox", "user_message", { createdBy: "user", text: "清理 30 天前的 Docker 镜像。" }),
    item("l-inbox", "assistant_message", { text: "已清理 37 个镜像，释放 12.4 GB。" }),
  ]);
  add(shell("l-web", "p-lab-web", "在实验室复现结账超时", {
    status: "completed", updatedAt: iso(-900000), modelSelection: CODEX, providerInstanceId: "codex",
    latestVisibleMessage: { id: "m-l-web", role: "assistant", text: "超时来自支付网关的重试，已复现。", updatedAt: iso(-900000) },
  }), [
    item("l-web", "user_message", { createdBy: "user", text: "在实验室环境复现结账超时。" }),
    item("l-web", "assistant_message", { text: "超时来自支付网关的重试，已复现。" }),
  ]);
  for (let i = 1; i <= 6; i++) {
    const projectId = ["p-ml", "p-infra"][i % 2];
    add(shell(`l-old-${i}`, projectId, `实验记录 ${String(i).padStart(2, "0")}`, {
      status: "completed", settledAt: iso(-86400000 * i - 3600000), settledOverride: "settled",
      updatedAt: iso(-86400000 * i - 3600000),
    }), [
      item(`l-old-${i}`, "user_message", { createdBy: "user", text: `第 ${i} 次实验` }),
      item(`l-old-${i}`, "assistant_message", { text: "已记录。" }),
    ]);
  }
  return { projects, threads, details, commands: [], outageUntil: 0, suggestions: new Map(), uploads: new Map(), voice: voiceState() };
}

function freshState() {
  if (LAB) {
    return labState();
  }
  ordinal = 1;
  const projects = [
    { ...project("p-web", "storefront-web", "blue", "store"), scripts: [{ id: "test", name: "测试", command: "pnpm test", icon: "test", runOnWorktreeCreate: false }] },
    // Icons as the desktop may have saved them: a favicon file, an emoji, a lucide icon (p-web).
    { ...project("p-api", "billing-api", "green", "server"), projectIcon: null, faviconPath: "C:\code\billing-api\public\favicon.svg" },
    { ...project("p-docs", "docs-site", "violet", "book"), projectIcon: { kind: "emoji", emoji: "📚" } },
  ];
  const threads = new Map();
  const details = new Map();
  const add = (s, items, requests = [], runs = []) => {
    threads.set(s.id, s);
    details.set(s.id, { items, requests, runs });
  };

  add(shell("t-running", "p-web", "重构结账流程", {
    status: "running", activeRunId: "run-t-running", activityRunStatus: "running", updatedAt: iso(-20000),
  }), [
    item("t-running", "user_message", { createdBy: "user", creationSource: "web", text: "把结账流程拆成独立的步骤组件，并补上测试。" }),
    item("t-running", "command_execution", { input: "pnpm test checkout", exitCode: 0, title: "Run tests" }),
    item("t-running", "file_change", { fileName: "src/checkout/Steps.tsx", additions: 84, deletions: 31 }),
    item("t-running", "assistant_message", { id: "item-running-answer", text: "正在拆分结账步骤", streaming: true, status: "running", completedAt: null }),
  ], [], [{ id: "run-t-running", ordinal: 1, status: "running", requestedAt: iso(-60000), startedAt: iso(-60000), completedAt: null }]);

  add(shell("t-approval", "p-api", "升级依赖并修复构建", {
    status: "running", activeRunId: "run-t-approval", activityRunStatus: "waiting", updatedAt: iso(-60000),
    pendingRuntimeRequest: { id: "req-approve", kind: "command", createdAt: iso(-60000), blocking: true },
  }), [
    item("t-approval", "user_message", { createdBy: "user", text: "把依赖升级到最新的小版本，并确保构建通过。" }),
    item("t-approval", "approval_request", {
      requestId: "req-approve", requestKind: "command", prompt: "pnpm up --latest --filter billing-api",
      reason: "需要更新 lockfile", status: "running",
      options: [{ decision: "decline", label: "拒绝" }, { decision: "accept", label: "批准" }],
    }),
  ], [{ id: "req-approve", kind: "command", status: "pending", createdAt: iso(-60000), resolvedAt: null }]);

  add(shell("t-question", "p-api", "选择数据库迁移方案", {
    status: "running", activeRunId: "run-t-question", activityRunStatus: "waiting", updatedAt: iso(-120000),
    pendingRuntimeRequest: { id: "req-question", kind: "user_input", createdAt: iso(-120000), blocking: true },
  }), [
    item("t-question", "user_message", { createdBy: "user", text: "帮我规划账单表的迁移。" }),
    item("t-question", "user_input_request", {
      requestId: "req-question", status: "running",
      questions: [{
        id: "q-db", header: "数据库", question: "迁移目标用哪个数据库？", allowCustomAnswer: false,
        options: [
          { label: "PostgreSQL", description: "与现有服务一致，支持事务 DDL" },
          { label: "SQLite", description: "适合本地开发和测试" },
        ],
      }],
    }),
  ], [{ id: "req-question", kind: "user_input", status: "pending", createdAt: iso(-120000), resolvedAt: null }]);

  // Several questions at once: the phone asks them one page at a time.
  add(shell("t-plan", "p-docs", "确认文档站发布计划", {
    status: "running", activeRunId: "run-t-plan", activityRunStatus: "waiting", updatedAt: iso(-150000),
    pendingRuntimeRequest: { id: "req-plan", kind: "user_input", createdAt: iso(-150000), blocking: true },
  }), [
    item("t-plan", "user_message", { createdBy: "user", text: "帮我排一下文档站的发布。" }),
    item("t-plan", "user_input_request", {
      requestId: "req-plan", status: "running",
      questions: [
        {
          id: "q-scope", header: "范围", question: "这次发布包含哪些部分？", multiSelect: true, allowCustomAnswer: false,
          options: [
            { label: "API 参考", description: "自动生成的接口文档" },
            { label: "教程", description: "新手入门和示例" },
            { label: "更新日志", description: "" },
          ],
        },
        {
          id: "q-when", header: "时间", question: "什么时候上线？",
          options: [
            { label: "今晚", description: "低峰期发布" },
            { label: "明天上午", description: "有人值守" },
          ],
        },
        {
          id: "q-notify", header: "通知", question: "上线后通知谁？", allowCustomAnswer: false,
          options: [
            { label: "只通知团队", description: "" },
            { label: "发全员公告", description: "" },
          ],
        },
      ],
    }),
  ], [{ id: "req-plan", kind: "user_input", status: "pending", createdAt: iso(-150000), resolvedAt: null }]);

  add(shell("t-long", "p-docs", "长时间运行的文档生成", {
    status: "running", activeRunId: "run-t-long", activityRunStatus: "running", updatedAt: iso(-180000),
  }), [
    item("t-long", "user_message", { createdBy: "user", text: "为所有 API 生成参考文档。" }),
    item("t-long", "command_execution", { input: "node scripts/gen-docs.mjs", status: "running", completedAt: null }),
  ], [], [{ id: "run-t-long", ordinal: 1, status: "running", requestedAt: iso(-180000), startedAt: iso(-180000), completedAt: null }]);

  add(shell("t-inbox", "p-web", "修复登录页样式", {
    status: "completed", updatedAt: iso(-300000),
    latestVisibleMessage: { id: "m-inbox", role: "assistant", text: "登录页的样式问题已经修好了（LoginForm 改成了 flex 布局）。", updatedAt: iso(-300000) },
  }), [
    item("t-inbox", "user_message", { createdBy: "user", text: "登录页在小屏手机上排版错乱，帮我修一下。" }),
    item("t-inbox", "reasoning", { title: "思考", text: "先看 LoginForm 的布局……" }),
    item("t-inbox", "command_execution", { input: "rg -n \"login-form\" src", exitCode: 0 }),
    item("t-inbox", "file_change", { fileName: "src/pages/Login.css", additions: 12, deletions: 9 }),
    item("t-inbox", "assistant_message", { text: MARKDOWN_ANSWER }),
  ], [], [{ id: "run-t-inbox", ordinal: 1, status: "completed", requestedAt: iso(-360000), startedAt: iso(-360000), completedAt: iso(-300000) }]);

  add(shell("t-failed", "p-web", "部署预览环境", {
    status: "failed", lastError: "Deployment quota exceeded", updatedAt: iso(-900000),
  }), [
    item("t-failed", "user_message", { createdBy: "user", text: "把当前分支部署到预览环境。" }),
    item("t-failed", "error", { message: "部署失败：预览环境配额已用完" }),
  ]);

  for (let i = 1; i <= 30; i++) {
    const projectId = ["p-web", "p-api", "p-docs"][i % 3];
    add(shell(`t-old-${i}`, projectId, `历史任务 ${String(i).padStart(2, "0")}`, {
      status: "completed", settledAt: iso(-86400000 * i), settledOverride: "settled",
      updatedAt: iso(-86400000 * i), modelSelection: i % 2 ? SONNET : CODEX,
      providerInstanceId: i % 2 ? "claudeAgent" : "codex",
    }), [
      item(`t-old-${i}`, "user_message", { createdBy: "user", text: `第 ${i} 个历史任务` }),
      item(`t-old-${i}`, "assistant_message", { text: "已完成。" }),
    ]);
  }

  // Prompt suggestions (the desktop's Labs switch): what to say next after a thread's latest run.
  const suggestions = new Map([["t-inbox", { runId: "run-t-inbox", text: "再检查一下深色模式下的登录页" }]]);
  return { projects, threads, details, commands: [], outageUntil: 0, suggestions, uploads: new Map(), voice: voiceState() };
}

state = freshState();

// ---------------------------------------------------------------------------------------------
// Minimal WebSocket server (text frames, fragmentation, ping/close)

const sockets = new Set();

function wsAccept(req, socket) {
  const key = req.headers["sec-websocket-key"];
  const accept = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`, "", "",
  ].join("\r\n"));
  const conn = { socket, buffer: Buffer.alloc(0), fragments: [], subs: new Map(), closed: false };
  sockets.add(conn);
  socket.on("data", (data) => onWsData(conn, data));
  socket.on("close", () => closeConn(conn));
  socket.on("error", () => closeConn(conn));
  return conn;
}

function closeConn(conn) {
  if (conn.closed) return;
  conn.closed = true;
  sockets.delete(conn);
  for (const sub of conn.subs.values()) sub.cancel?.();
  try { conn.socket.destroy(); } catch {}
}

function wsSend(conn, text) {
  if (conn.closed) return;
  const payload = Buffer.from(text, "utf8");
  let header;
  if (payload.length < 126) header = Buffer.from([0x81, payload.length]);
  else if (payload.length < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(payload.length, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 127; header.writeBigUInt64BE(BigInt(payload.length), 2); }
  conn.socket.write(Buffer.concat([header, payload]));
}

function onWsData(conn, data) {
  conn.buffer = Buffer.concat([conn.buffer, data]);
  for (;;) {
    const b = conn.buffer;
    if (b.length < 2) return;
    const fin = (b[0] & 0x80) !== 0;
    const opcode = b[0] & 0x0f;
    const masked = (b[1] & 0x80) !== 0;
    let len = b[1] & 0x7f;
    let offset = 2;
    if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); offset = 4; }
    else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); offset = 10; }
    const maskLen = masked ? 4 : 0;
    if (b.length < offset + maskLen + len) return;
    const mask = masked ? b.subarray(offset, offset + 4) : null;
    const body = Buffer.from(b.subarray(offset + maskLen, offset + maskLen + len));
    if (mask) for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
    conn.buffer = b.subarray(offset + maskLen + len);
    if (opcode === 0x8) { closeConn(conn); return; }
    if (opcode === 0x9) { conn.socket.write(Buffer.concat([Buffer.from([0x8a, body.length]), body])); continue; }
    if (opcode === 0x1 || opcode === 0x0) {
      conn.fragments.push(body);
      if (fin) {
        const text = Buffer.concat(conn.fragments).toString("utf8");
        conn.fragments = [];
        onRpcText(conn, text);
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Effect RPC

function onRpcText(conn, text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  const list = Array.isArray(msg) ? msg : [msg];
  for (const m of list) {
    if (m._tag === "Ping") wsSend(conn, JSON.stringify({ _tag: "Pong" }));
    else if (m._tag === "Request") handleRequest(conn, m);
    else if (m._tag === "Interrupt") { conn.subs.get(String(m.requestId))?.cancel?.(); conn.subs.delete(String(m.requestId)); }
  }
}

const chunk = (conn, id, values) => wsSend(conn, JSON.stringify({ _tag: "Chunk", requestId: id, values }));
const exitOk = (conn, id, value) => wsSend(conn, JSON.stringify({ _tag: "Exit", requestId: id, exit: { _tag: "Success", value } }));
const exitFail = (conn, id, message) => wsSend(conn, JSON.stringify({
  _tag: "Exit", requestId: id, exit: { _tag: "Failure", cause: [{ _tag: "Fail", error: { _tag: "MockError", message } }] },
}));

const workspace = createWorkspace({
  lab: LAB, chunk, exitOk, exitFail,
  log: (entry) => state.commands.push(entry),
});

// Model settings as providers report them (ModelCapabilities.optionDescriptors).
const CLAUDE_OPTIONS = [
  { id: "effort", label: "Effort", type: "select", role: "reasoning", options: [
    { id: "low", label: "Low" }, { id: "medium", label: "Medium" }, { id: "high", label: "High", isDefault: true },
    { id: "xhigh", label: "Extra high" }, { id: "max", label: "Max" },
  ] },
  { id: "fastMode", label: "Fast mode", type: "boolean", description: "更快出结果，消耗更多额度", currentValue: false },
];
const CODEX_OPTIONS = [
  { id: "reasoningEffort", label: "Reasoning effort", type: "select", options: [
    { id: "minimal", label: "Minimal" }, { id: "low", label: "Low" }, { id: "medium", label: "Medium", isDefault: true },
    { id: "high", label: "High" }, { id: "xhigh", label: "Extra high" },
  ] },
  { id: "fastMode", label: "Fast mode", type: "boolean", currentValue: false },
];

const CURSOR_GROK_OPTIONS = [
  { id: "reasoning_effort", label: "Reasoning", type: "select", options: [
    { id: "low", label: "Low" }, { id: "medium", label: "Medium" }, { id: "high", label: "High", isDefault: true }, { id: "xhigh", label: "Extra high" },
  ] },
  { id: "fastMode", label: "Fast", type: "boolean", currentValue: true },
];
const CURSOR_OPUS_OPTIONS = [
  ...CLAUDE_OPTIONS,
  { id: "contextWindow", label: "Context", type: "select", options: [{ id: "300k", label: "300k" }, { id: "1m", label: "1M", isDefault: true }] },
];

function providersSnapshot() {
  const limits = workspace.limits();
  const claude = (slug, name, shortName, isDefault) => ({ slug, name, shortName, isCustom: false, isDefault, capabilities: { optionDescriptors: CLAUDE_OPTIONS } });
  const codex = (slug, name, shortName, isDefault) => ({ slug, name, shortName, isCustom: false, isDefault, capabilities: { optionDescriptors: CODEX_OPTIONS } });
  return [
    { instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", enabled: true, installed: true, status: "ready", auth: { status: "authenticated", label: "Claude Max" },
      models: [claude("claude-opus-5-5", "Claude Opus 5.5", "Opus 5.5", true), claude("claude-sonnet-5-5", "Claude Sonnet 5.5", "Sonnet 5.5", false), claude("claude-haiku-5-5", "Claude Haiku 5.5", "Haiku 5.5", false)],
      usageLimits: limits.claudeAgent },
    { instanceId: "codex", driver: "codex", displayName: "Codex", enabled: true, installed: true, status: "ready", auth: { status: "authenticated", label: "ChatGPT Pro" },
      models: [codex("gpt-6.1-sol", "GPT-6.1 Sol", "GPT-6.1 Sol", true), codex("gpt-6.1-sol-mini", "GPT-6.1 Sol mini", "Sol mini", false)],
      usageLimits: limits.codex },
    { instanceId: "cursor", driver: "cursor", displayName: "Cursor", enabled: true, installed: true, status: "ready", auth: { status: "authenticated" },
      models: [
        { slug: "default", name: "Auto", shortName: "Auto", isCustom: false, isDefault: true },
        { slug: "grok-4.7", name: "Grok 4.7", shortName: "Grok 4.7", isCustom: false, isDefault: false, capabilities: { optionDescriptors: CURSOR_GROK_OPTIONS } },
        { slug: "claude-opus-5-5", name: "Claude Opus 5.5", shortName: "Opus 5.5", isCustom: false, isDefault: false, capabilities: { optionDescriptors: CURSOR_OPUS_OPTIONS } },
      ] },
  ];
}

function snapshot() {
  return {
    schemaVersion: 2, snapshotSequence: seq,
    threads: [...state.threads.values()].filter((t) => !t.archivedAt),
    archivedThreads: [], projects: state.projects,
  };
}

function projection(threadId) {
  const t = state.threads.get(threadId);
  const d = state.details.get(threadId);
  return {
    thread: { id: t.id, projectId: t.projectId, title: t.title, providerInstanceId: t.providerInstanceId, modelSelection: t.modelSelection, runtimeMode: t.runtimeMode, interactionMode: "default", branch: null, worktreePath: null },
    runs: d.runs, attempts: [], nodes: [], subagents: [], providerSessions: [], providerThreads: [], providerTurns: [],
    runtimeRequests: d.requests, messages: [], plans: [], turnItems: d.items, checkpointScopes: [], checkpoints: [],
    contextHandoffs: [], contextTransfers: [], updatedAt: iso(),
  };
}

function broadcastShell(item) {
  for (const conn of sockets) for (const sub of conn.subs.values()) if (sub.kind === "shell") chunk(conn, sub.id, [item]);
}

function broadcastThread(threadId, event) {
  const value = { kind: "event", sequence: nextSeq(), event: { id: crypto.randomUUID(), threadId, occurredAt: iso(), ...event } };
  for (const conn of sockets) for (const sub of conn.subs.values()) if (sub.kind === "thread" && sub.threadId === threadId) chunk(conn, sub.id, [value]);
}

function updateShell(threadId, patch) {
  const t = { ...state.threads.get(threadId), ...patch, updatedAt: iso() };
  state.threads.set(threadId, t);
  broadcastShell({ kind: "thread.updated", sequence: nextSeq(), location: t.archivedAt ? "archive" : "active", thread: t });
  return t;
}

function setSuggestion(threadId, value) {
  state.suggestions.set(threadId, value);
  for (const conn of sockets) for (const sub of conn.subs.values()) if (sub.kind === "suggestion" && sub.threadId === threadId) chunk(conn, sub.id, [value]);
}

function upsertItem(threadId, it) {
  const d = state.details.get(threadId);
  const idx = d.items.findIndex((x) => x.id === it.id);
  if (idx >= 0) d.items[idx] = it; else d.items.push(it);
  broadcastThread(threadId, { type: "turn-item.updated", payload: it });
}

const timers = new Set();
const later = (ms, fn) => { const t = setTimeout(() => { timers.delete(t); fn(); }, ms); timers.add(t); };

/** Streams an assistant answer in pieces, then completes the run. */
function streamAnswer(threadId, text, { startDelay = 400, step = 350, runId = null, suggestion = null } = {}) {
  const pieces = text.match(/.{1,6}/gsu) ?? [text];
  const answer = item(threadId, "assistant_message", { text: "", streaming: true, status: "running", completedAt: null });
  let shown = "";
  later(startDelay, () => {
    pieces.forEach((piece, i) => {
      later(i * step, () => {
        if (!state.details.has(threadId)) return;
        shown += piece;
        const done = i === pieces.length - 1;
        upsertItem(threadId, { ...answer, text: shown, streaming: !done, status: done ? "completed" : "running", completedAt: done ? iso() : null, updatedAt: iso() });
        if (done) {
          if (runId) {
            const d = state.details.get(threadId);
            const run = { ...d.runs.find((r) => r.id === runId), status: "completed", completedAt: iso() };
            d.runs = d.runs.map((r) => (r.id === runId ? run : r));
            broadcastThread(threadId, { type: "run.updated", payload: run });
          }
          updateShell(threadId, {
            status: "completed", activeRunId: null, activityRunStatus: null, unsettledAt: iso(),
            latestVisibleMessage: { id: answer.id, role: "assistant", text: shown, updatedAt: iso() },
          });
          if (runId && suggestion) setSuggestion(threadId, { runId, text: suggestion });
        }
      });
    });
  });
}

let runningStarted = false;

function handleRequest(conn, m) {
  const id = String(m.id);
  const p = m.payload ?? {};
  switch (m.tag) {
    case "attachments.createUploadUrl": {
      // Like the server: a signed, single-use upload path; the bytes arrive by POST.
      const attachmentId = `att-${crypto.randomUUID()}`;
      state.uploads.set(attachmentId, { type: p.type ?? "image", name: p.name, mimeType: p.mimeType, sizeBytes: p.sizeBytes, data: null });
      return exitOk(conn, id, { attachmentId, relativeUrl: `/api/attachments/upload/${attachmentId}.mock-signature`, expiresAt: Date.now() + 600_000 });
    }
    case "attachments.delete": {
      state.uploads.delete(p.attachmentId);
      state.commands.push({ tag: m.tag, payload: p, at: iso() });
      return exitOk(conn, id, null);
    }
    case "assets.createUrl": {
      const resource = m.payload?.resource ?? {};
      if (resource._tag === "attachment") {
        if (!state.uploads.get(resource.attachmentId)?.data) return exitFail(conn, id, "Attachment not found");
        return exitOk(conn, id, { relativeUrl: `/api/assets/attachment/${resource.attachmentId}?sig=mock`, expiresAt: Date.now() + 3600_000 });
      }
      if (resource._tag !== "project-favicon") return exitFail(conn, id, "Mock serves only project favicons");
      const project = state.projects.find((p) => p.workspaceRoot === resource.cwd);
      const relativeUrl = project?.faviconPath ? `/api/assets/favicon/${project.id}.svg?sig=mock` : "/api/assets/project-favicon-missing";
      return exitOk(conn, id, { relativeUrl, expiresAt: Date.now() + 3600_000 });
    }
    case "server.getConfig":
      return exitOk(conn, id, { environment: DESCRIPTOR, hostname: "mock", providers: providersSnapshot() });
    case "server.refreshProviders":
      return exitOk(conn, id, { providers: providersSnapshot() });
    case "orchestration.subscribeShell": {
      conn.subs.set(id, { id, kind: "shell" });
      chunk(conn, id, [{ kind: "snapshot", snapshot: snapshot() }]);
      chunk(conn, id, [{ kind: "synchronized" }]);
      return;
    }
    case "orchestration.subscribeThread": {
      const threadId = p.threadId;
      if (!state.threads.has(threadId)) return exitFail(conn, id, "Thread not found");
      conn.subs.set(id, { id, kind: "thread", threadId });
      chunk(conn, id, [{ kind: "snapshot", snapshotSequence: seq, projection: projection(threadId) }]);
      chunk(conn, id, [{ kind: "synchronized" }]);
      if (threadId === "t-running" && !runningStarted) {
        runningStarted = true;
        const it = state.details.get("t-running").items.find((x) => x.id === "item-running-answer");
        const finalText = "结账流程已重构完成：拆成了地址、配送、支付三个步骤组件，测试全部通过。";
        [8, 20, finalText.length].forEach((n, i) => later(1500 + i * 1500, () => {
          const done = n === finalText.length;
          upsertItem("t-running", { ...it, text: finalText.slice(0, n), streaming: !done, status: done ? "completed" : "running", updatedAt: iso() });
          if (done) updateShell("t-running", {
            status: "completed", activeRunId: null, activityRunStatus: null, unsettledAt: iso(),
            latestVisibleMessage: { id: it.id, role: "assistant", text: finalText, updatedAt: iso() },
          });
        }));
      }
      return;
    }
    case "orchestration.subscribePromptSuggestion": {
      conn.subs.set(id, { id, kind: "suggestion", threadId: p.threadId });
      chunk(conn, id, [state.suggestions.get(p.threadId) ?? null]);
      return;
    }
    case "orchestration.dispatchCommand":
      return handleCommand(conn, id, p);
    case "orchestration.launchThread": {
      state.commands.push({ tag: m.tag, payload: p, at: iso() });
      const threadId = p.threadId ?? crypto.randomUUID();
      const t = shell(threadId, p.projectId, p.title ?? "新任务", {
        status: "running", activeRunId: `run-${threadId}`, activityRunStatus: "running", creationSource: p.creationSource ?? "mobile",
        modelSelection: p.modelSelection, providerInstanceId: p.modelSelection?.instanceId ?? "claudeAgent", runtimeMode: p.runtimeMode,
        latestUserMessageAt: iso(), createdAt: iso(), updatedAt: iso(),
      });
      state.threads.set(threadId, t);
      state.details.set(threadId, {
        items: [item(threadId, "user_message", { createdBy: "user", creationSource: "mobile", text: p.initialMessage?.text ?? "", attachments: p.initialMessage?.attachments ?? [] })],
        requests: [], runs: [{ id: `run-${threadId}`, ordinal: 1, status: "running", requestedAt: iso(), startedAt: iso(), completedAt: null }],
      });
      broadcastShell({ kind: "thread.updated", sequence: nextSeq(), location: "active", thread: t });
      exitOk(conn, id, { threadId, projection: projection(threadId), resumed: false, sequence: seq });
      streamAnswer(threadId, "好的，我已经开始处理这个任务了。", { startDelay: 900 });
      return;
    }
    default:
      if (workspace.handle(conn, id, m.tag, p)) return;
      return exitFail(conn, id, `Mock does not implement ${m.tag}`);
  }
}

function handleCommand(conn, id, cmd) {
  state.commands.push({ tag: "orchestration.dispatchCommand", payload: cmd, at: iso() });
  const threadId = cmd.threadId;
  const t = state.threads.get(threadId);
  if (!t) return exitFail(conn, id, "Thread not found");
  const d = state.details.get(threadId);
  switch (cmd.type) {
    case "message.dispatch": {
      upsertItem(threadId, item(threadId, "user_message", { createdBy: "user", creationSource: cmd.creationSource, text: cmd.text, attachments: cmd.attachments ?? [] }));
      const runId = `run-${threadId}-${seq}`;
      const run = { id: runId, ordinal: d.runs.reduce((max, r) => Math.max(max, r.ordinal), 0) + 1, status: "running", requestedAt: iso(), startedAt: iso(), completedAt: null };
      d.runs = [...d.runs, run];
      broadcastThread(threadId, { type: "run.created", payload: run });
      updateShell(threadId, { status: "running", activeRunId: runId, activityRunStatus: "running", latestUserMessageAt: iso() });
      exitOk(conn, id, { sequence: nextSeq() });
      streamAnswer(threadId, `收到：${cmd.text}`, { runId, suggestion: "好的，把这些改动提交一下" });
      return;
    }
    case "runtime-request.respond": {
      const req = d.requests.find((r) => r.id === cmd.requestId);
      if (!req || req.status !== "pending") return exitFail(conn, id, "Request is not pending");
      const resolved = { ...req, status: "resolved", resolvedAt: iso(), decision: cmd.decision, answers: cmd.answers };
      d.requests = d.requests.map((r) => (r.id === req.id ? resolved : r));
      broadcastThread(threadId, { type: "runtime-request.updated", payload: resolved });
      updateShell(threadId, { pendingRuntimeRequest: null, activityRunStatus: "running" });
      exitOk(conn, id, { sequence: nextSeq() });
      const answer = cmd.answers ? `好的，使用 ${Object.values(cmd.answers).flat().join("、")}。` : cmd.decision === "accept" ? "已获批准，正在执行。" : "好的，我不会执行这个命令。";
      streamAnswer(threadId, answer, { startDelay: 300 });
      return;
    }
    case "thread.stop": {
      d.runs = d.runs.map((r) => ({ ...r, status: "interrupted", completedAt: iso() }));
      upsertItem(threadId, item(threadId, "system_notice", { message: "任务已按你的要求停止" }));
      updateShell(threadId, { status: "interrupted", activeRunId: null, activityRunStatus: null });
      return exitOk(conn, id, { sequence: nextSeq() });
    }
    case "thread.archive":
      updateShell(threadId, { archivedAt: iso() });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.settle":
      updateShell(threadId, { settledAt: iso(), settledOverride: "settled" });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.pin":
      updateShell(threadId, { pinnedAt: iso() });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.unpin":
      updateShell(threadId, { pinnedAt: null });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.visit": {
      // Moves the read watermark only; like the server, a visit is not activity.
      const t = { ...state.threads.get(threadId), lastVisitedAt: cmd.visitedAt ?? iso() };
      state.threads.set(threadId, t);
      broadcastShell({ kind: "thread.updated", sequence: nextSeq(), location: t.archivedAt ? "archive" : "active", thread: t });
      return exitOk(conn, id, { sequence: nextSeq() });
    }
    case "thread.model-selection.set":
      updateShell(threadId, { modelSelection: cmd.modelSelection, providerInstanceId: cmd.modelSelection.instanceId });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.runtime-mode.set":
      updateShell(threadId, { runtimeMode: cmd.runtimeMode });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.interaction-mode.set":
      updateShell(threadId, { interactionMode: cmd.interactionMode });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.snooze":
      updateShell(threadId, { snoozedUntil: cmd.snoozedUntil });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.unsnooze":
      updateShell(threadId, { snoozedUntil: null });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.unsettle":
      updateShell(threadId, { settledAt: null, settledOverride: "unsettled", unsettledAt: iso() });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.unarchive":
      updateShell(threadId, { archivedAt: null });
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.metadata.update":
      updateShell(threadId, cmd.title ? { title: cmd.title } : {});
      return exitOk(conn, id, { sequence: nextSeq() });
    case "thread.delete":
      state.threads.delete(threadId);
      broadcastShell({ kind: "thread.removed", sequence: nextSeq(), threadId });
      return exitOk(conn, id, { sequence: nextSeq() });
    default:
      return exitFail(conn, id, `Mock does not implement command ${cmd.type}`);
  }
}

// ---------------------------------------------------------------------------------------------
// HTTP

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

function authorized(req) {
  return (req.headers.authorization ?? "") === `Bearer ${ACCESS_TOKEN}`;
}

const tickets = new Map(); // ticket -> DPoP thumbprint it is bound to (null for bearer sessions)

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks);
    const body = raw.toString("utf8");
    const path = url.pathname;
    // Attachment uploads and downloads go by signed path, without the session credentials.
    const upload = /^\/api\/attachments\/upload\/([^/.]+)\.mock-signature$/.exec(path);
    if (upload && req.method === "POST") {
      const pending = state.uploads.get(upload[1]);
      if (!pending || pending.data) return json(res, 404, { message: "Not Found" });
      if (raw.length !== pending.sizeBytes) return json(res, 400, { message: "Content-Length must match the upload size." });
      pending.data = raw;
      state.commands.push({ tag: "attachment.upload", payload: { name: pending.name, mimeType: pending.mimeType, sizeBytes: raw.length, contentType: req.headers["content-type"] ?? "" }, at: iso() });
      res.writeHead(204);
      return res.end();
    }
    const asset = /^\/api\/assets\/attachment\/([^/?]+)$/.exec(path);
    if (asset) {
      const stored = state.uploads.get(asset[1]);
      if (!stored?.data) return json(res, 404, { message: "Not Found" });
      res.writeHead(200, { "content-type": stored.mimeType });
      return res.end(stored.data);
    }
    if (path === "/__test/reset" && req.method === "POST") {
      for (const t of timers) clearTimeout(t);
      timers.clear();
      for (const conn of [...sockets]) closeConn(conn);
      state = freshState();
      workspace.reset();
      resetConnect();
      runningStarted = false;
      return json(res, 200, { ok: true });
    }
    if (path === "/__test/state") {
      return json(res, 200, { commands: state.commands, threads: [...state.threads.values()].map((t) => ({ id: t.id, status: t.status, archivedAt: t.archivedAt, pinnedAt: t.pinnedAt, settledAt: t.settledAt, snoozedUntil: t.snoozedUntil ?? null, title: t.title })) });
    }
    if (path === "/__test/drop" && req.method === "POST") {
      const count = sockets.size;
      for (const conn of [...sockets]) closeConn(conn);
      return json(res, 200, { dropped: count });
    }
    if (path === "/__test/outage" && req.method === "POST") {
      state.outageUntil = Date.now() + Number(url.searchParams.get("ms") ?? 3000);
      for (const conn of [...sockets]) closeConn(conn);
      return json(res, 200, { until: state.outageUntil });
    }
    if (handleConnectRoutes(req, res, url, body)) return;
    if (handleConnectTestRoutes(req, res, url)) return;
    if (path === "/.well-known/t3/environment") return json(res, 200, DESCRIPTOR);
    if (path.startsWith("/api/assets/favicon/")) {
      res.writeHead(200, { "content-type": "image/svg+xml" });
      return res.end('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#0f766e"/><path d="M16 6v20M11 11h7a3.5 3.5 0 0 1 0 7h-4a3.5 3.5 0 0 0 0 7h7" stroke="#fff" stroke-width="2.6" fill="none" stroke-linecap="round"/></svg>');
    }
    if (path === "/oauth/token" && req.method === "POST") {
      const form = new URLSearchParams(body);
      if (handleTunnelTokenExchange(req, res, form)) return;
      if (form.get("subject_token") !== PAIRING_CODE) {
        return json(res, 400, { error: "invalid_grant", message: "Pairing credential is invalid or expired." });
      }
      state.commands.push({ tag: "oauth.token", payload: { client_label: form.get("client_label"), client_os: form.get("client_os") }, at: iso() });
      return json(res, 200, { access_token: ACCESS_TOKEN, issued_token_type: "urn:ietf:params:oauth:token-type:access_token", token_type: "Bearer", expires_in: 2592000, scope: "orchestration:read orchestration:operate" });
    }
    const dpopThumbprint = dpopPrincipal(req, url);
    if (!authorized(req) && !dpopThumbprint) return json(res, 401, { code: "unauthorized", message: "Missing or invalid credentials" });
    if (path.startsWith("/api/auth/websocket-ticket") && req.method === "POST") {
      if (Date.now() < state.outageUntil) return json(res, 503, { code: "unavailable", message: "Mock outage" });
      const ticket = crypto.randomUUID();
      tickets.set(ticket, dpopThumbprint ?? null);
      return json(res, 200, { ticket, expiresAt: iso(60000) });
    }
    if (path.startsWith("/api/voice/")) return handleVoice(req, res, url, raw, body);
    if (path === "/api/auth/session") return json(res, 200, { authenticated: true, scopes: ["orchestration:read", "orchestration:operate"] });
    if (path === "/api/orchestration/shell") return json(res, 200, snapshot());
    const threadMatch = /^\/api\/orchestration\/threads\/([^/]+)$/.exec(path);
    if (threadMatch) {
      const threadId = decodeURIComponent(threadMatch[1]);
      if (!state.threads.has(threadId)) return json(res, 404, { code: "not_found", message: "Thread not found" });
      return json(res, 200, { snapshotSequence: seq, projection: projection(threadId) });
    }
    json(res, 404, { code: "not_found", message: path });
  });
});

// ---------------------------------------------------------------------------------------------
// Voice (the desktop's Settings › Voice and dictation endpoints)

const invalid = (res, reason) => json(res, 400, { _tag: "EnvironmentRequestInvalidError", code: "invalid_request", reason, traceId: "mock-trace" });
const cloudError = (res, provider, reason) => json(res, 422, { _tag: "CloudSpeechError", provider, reason });

function voiceModels() {
  const v = state.voice;
  return { models: v.models.map((m) => ({ ...m, active: m.id === v.modelId && m.state === "installed" })) };
}

/** Options length (u32 LE), options JSON, then 16 kHz mono Float32 PCM, as the server decodes it. */
function decodeSpeech(raw) {
  if (raw.length < 4) return null;
  const length = raw.readUInt32LE(0);
  if (length > 128000 || 4 + length >= raw.length) return null;
  let options;
  try {
    options = JSON.parse(raw.subarray(4, 4 + length).toString("utf8"));
  } catch {
    return null;
  }
  const pcm = raw.subarray(4 + length);
  if (pcm.length === 0 || pcm.length % 4 !== 0) return null;
  const samples = new Float32Array(Uint8Array.from(pcm).buffer);
  let peak = 0;
  for (const sample of samples) {
    if (!Number.isFinite(sample) || sample < -1 || sample > 1) return null;
    peak = Math.max(peak, Math.abs(sample));
  }
  return { options, seconds: samples.length / 16000, peak, jsonPaddedTo4: length % 4 === 0 };
}

function handleVoice(req, res, url, raw, body) {
  const v = state.voice;
  const path = url.pathname;
  if (path === "/api/voice/cloud/keys") return json(res, 200, v.keys);
  if (path === "/api/voice/cloud/openrouter/models") {
    if (!v.keys.openrouter) return cloudError(res, "openrouter", "missing-key");
    return json(res, 200, { models: [{ id: "openai/gpt-4o-transcribe", name: "GPT-4o Transcribe" }, { id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash" }] });
  }
  if (path === "/api/voice/status") {
    if (!DESCRIPTOR.capabilities.voiceTranscription) return json(res, 200, { supported: false, reason: "unsupported-platform" });
    const active = v.models.find((m) => m.id === v.modelId);
    return json(res, 200, {
      supported: true, state: active?.state === "installed" ? "ready" : "missing-model", modelId: v.modelId, model: active?.name ?? "",
      size: active?.size ?? 0, supportsStreaming: false, supportsTranslation: false, languages: active?.languages ?? [],
      supportsLanguageDetection: active?.supportsLanguageDetection ?? false, acceleration: "auto", benchmarkTier: "cpu",
      modelUnloadTimeout: "min_5", gpuDevices: [],
    });
  }
  if (path === "/api/voice/models") return json(res, 200, voiceModels());
  if (path === "/api/voice/models/select" && req.method === "POST") {
    const { modelId } = JSON.parse(body || "{}");
    const target = v.models.find((m) => m.id === modelId);
    if (!target || target.state !== "installed") return invalid(res, "invalid_command");
    v.modelId = modelId;
    state.commands.push({ tag: "voice.select", payload: { modelId }, at: iso() });
    return json(res, 200, voiceModels());
  }
  if (path === "/api/voice/models/download" && req.method === "POST") {
    const { modelId } = JSON.parse(body || "{}");
    const target = v.models.find((m) => m.id === modelId);
    if (!target) return invalid(res, "invalid_command");
    if (v.models.some((m) => m.state === "downloading")) return invalid(res, "speech_busy");
    state.commands.push({ tag: "voice.download", payload: { modelId }, at: iso() });
    target.state = "downloading";
    target.downloaded = 0;
    // The real server answers once the file is on disk; progress shows in the model list meanwhile.
    const tick = setInterval(() => {
      target.downloaded = Math.min(target.size, (target.downloaded ?? 0) + target.size / 8);
      if (target.downloaded >= target.size) {
        clearInterval(tick);
        timers.delete(tick);
        target.state = "installed";
        delete target.downloaded;
        json(res, 200, voiceModels());
      }
    }, 400);
    timers.add(tick);
    return;
  }
  const cloud = /^\/api\/voice\/cloud\/([a-z]+)\/transcribe$/.exec(path);
  if ((cloud || path === "/api/voice/transcribe") && req.method === "POST") {
    const provider = cloud ? cloud[1] : null;
    if (provider && !v.keys[provider]) return cloudError(res, provider, "missing-key");
    if (!provider && !DESCRIPTOR.capabilities.voiceTranscription) return invalid(res, "speech_unavailable");
    const decoded = decodeSpeech(raw);
    if (!decoded) return invalid(res, "invalid_audio");
    state.commands.push({
      tag: "voice.transcribe",
      payload: {
        destination: provider ?? "local", model: provider ? (url.searchParams.get("model") ?? "") : v.modelId,
        options: decoded.options, seconds: decoded.seconds, peak: decoded.peak, jsonPaddedTo4: decoded.jsonPaddedTo4,
        contentType: req.headers["content-type"] ?? "",
      },
      at: iso(),
    });
    return json(res, 200, { text: provider ? "用云端转写的一句话" : "把登录页的按钮改成蓝色" });
  }
  if (path === "/api/voice/post-process" && req.method === "POST") {
    const request = JSON.parse(body || "{}");
    state.commands.push({ tag: "voice.postProcess", payload: { transcript: request.transcript, draft: request.draft }, at: iso() });
    return json(res, 200, { text: `${request.transcript}。` });
  }
  return json(res, 404, { code: "not_found", message: path });
}

server.on("upgrade", (req, socket) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const ticket = url.searchParams.get("wsTicket");
  if (url.pathname !== "/ws" || url.searchParams.get("orchestrationProtocol") !== "2" || !tickets.has(ticket) || Date.now() < state.outageUntil) {
    socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
    return;
  }
  const boundTo = tickets.get(ticket);
  if (boundTo) {
    // DPoP sessions prove the key again on the upgrade, in the query, bound to the ticket.
    const proof = verifyDpop(url.searchParams.get("dpop"), "GET", `http://${req.headers.host}/ws`, ticket);
    if (proof.error || proof.thumbprint !== boundTo) {
      cs.log.push({ tag: "connect.wsRejected", payload: { error: proof.error ?? "key_mismatch" } });
      socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
      return;
    }
    cs.log.push({ tag: "connect.ws", payload: { connectionMethod: url.searchParams.get("connectionMethod") } });
  }
  tickets.delete(ticket);
  wsAccept(req, socket);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`mock-t3 listening on http://0.0.0.0:${PORT} (pairing code: ${PAIRING_CODE})`);
});
