// Workspace surfaces of the mock server: git status and actions, diffs, branches, the file tree,
// terminals (a tiny scripted shell), usage, provider limits and pull requests. Deterministic
// fixtures so the HarmonyOS UI tests can assert on them.

const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();

export function createWorkspace({ lab, chunk, exitOk, exitFail, log }) {
  // ---- Git ----------------------------------------------------------------------------------
  const repos = new Map(); // cwd -> status

  function repoFor(cwd) {
    if (!repos.has(cwd)) {
      const dirty = !lab;
      repos.set(cwd, {
        local: {
          isRepo: true,
          sourceControlProvider: { kind: "github", name: "GitHub", baseUrl: "https://github.com" },
          hasPrimaryRemote: true,
          isDefaultRef: lab,
          refName: lab ? "main" : "feature/checkout-steps",
          hasWorkingTreeChanges: dirty,
          workingTree: dirty
            ? {
                files: [
                  { path: "src/checkout/Steps.tsx", insertions: 84, deletions: 31 },
                  { path: "src/checkout/Address.tsx", insertions: 40, deletions: 0 },
                ],
                insertions: 124,
                deletions: 31,
              }
            : { files: [], insertions: 0, deletions: 0 },
        },
        remote: { hasUpstream: true, aheadCount: lab ? 0 : 1, behindCount: 0, pr: null },
        branches: lab ? ["main", "exp/cosine"] : ["feature/checkout-steps", "main", "fix/login-css"],
      });
    }
    return repos.get(cwd);
  }

  const vcsSubs = new Set(); // { conn, id, cwd }

  function pushStatus(cwd) {
    const repo = repoFor(cwd);
    for (const sub of vcsSubs) {
      if (sub.cwd === cwd && !sub.conn.closed) chunk(sub.conn, sub.id, [{ _tag: "snapshot", local: repo.local, remote: repo.remote }]);
    }
  }

  const DIFF = [
    "diff --git a/src/checkout/Steps.tsx b/src/checkout/Steps.tsx",
    "index 3b1c2aa..9f0e4d1 100644",
    "--- a/src/checkout/Steps.tsx",
    "+++ b/src/checkout/Steps.tsx",
    "@@ -1,6 +1,9 @@",
    " import { useState } from 'react';",
    "-import { CheckoutForm } from './CheckoutForm';",
    "+import { AddressStep } from './Address';",
    "+import { ShippingStep } from './Shipping';",
    "+import { PaymentStep } from './Payment';",
    " ",
    " export function Steps() {",
    "-  return <CheckoutForm />;",
    "+  const [step, setStep] = useState(0);",
    "+  return [<AddressStep key=\"a\" />, <ShippingStep key=\"s\" />, <PaymentStep key=\"p\" />][step];",
    " }",
    "diff --git a/src/checkout/Address.tsx b/src/checkout/Address.tsx",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/src/checkout/Address.tsx",
    "@@ -0,0 +1,3 @@",
    "+export function AddressStep() {",
    "+  return <form className=\"address\" />;",
    "+}",
    "",
  ].join("\n");

  // ---- Files --------------------------------------------------------------------------------
  const TREE = {
    "": [["src", "directory"], ["package.json", "file"], ["README.md", "file"], ["tsconfig.json", "file"]],
    src: [["src/checkout", "directory"], ["src/index.ts", "file"]],
    "src/checkout": [["src/checkout/Steps.tsx", "file"], ["src/checkout/Address.tsx", "file"]],
  };
  const FILES = {
    "package.json": '{\n  "name": "storefront-web",\n  "version": "1.4.0",\n  "scripts": {\n    "dev": "vite",\n    "test": "vitest"\n  }\n}\n',
    "README.md": "# storefront-web\n\n店面前端。运行 `pnpm dev` 启动开发服务器。\n",
    "tsconfig.json": '{\n  "compilerOptions": { "strict": true, "jsx": "react-jsx" }\n}\n',
    "src/index.ts": "export * from './checkout/Steps';\n",
    "src/checkout/Steps.tsx": "import { useState } from 'react';\nimport { AddressStep } from './Address';\n\nexport function Steps() {\n  const [step, setStep] = useState(0);\n  return <AddressStep />;\n}\n",
    "src/checkout/Address.tsx": "export function AddressStep() {\n  return <form className=\"address\" />;\n}\n",
  };

  // ---- Terminals ----------------------------------------------------------------------------
  const terminals = new Map(); // `${threadId}:${terminalId}` -> session
  const metaSubs = new Set(); // { conn, id }
  const attachSubs = new Set(); // { conn, id, key }

  function summary(t) {
    return {
      threadId: t.threadId, terminalId: t.terminalId, cwd: t.cwd, worktreePath: null, status: t.status,
      pid: 4242, exitCode: null, exitSignal: null, hasRunningSubprocess: false, label: t.label, updatedAt: t.updatedAt,
    };
  }

  function snapshotOf(t) {
    return {
      threadId: t.threadId, terminalId: t.terminalId, cwd: t.cwd, worktreePath: null, status: t.status, pid: 4242,
      history: t.history, exitCode: null, exitSignal: null, label: t.label, updatedAt: t.updatedAt, cols: t.cols, rows: t.rows,
    };
  }

  function broadcastMeta(event) {
    for (const sub of metaSubs) if (!sub.conn.closed) chunk(sub.conn, sub.id, [event]);
  }

  function output(t, data) {
    t.history += data;
    t.updatedAt = iso();
    for (const sub of attachSubs) {
      if (sub.key === `${t.threadId}:${t.terminalId}` && !sub.conn.closed) {
        chunk(sub.conn, sub.id, [{ type: "output", threadId: t.threadId, terminalId: t.terminalId, data }]);
      }
    }
  }

  const prompt = (t) => `\x1b[32mmock\x1b[0m:\x1b[34m${t.cwd.split(/[\\/]/).pop()}\x1b[0m$ `;

  function runLine(t, line) {
    const cmd = line.trim();
    t.commands.push(cmd);
    log({ tag: "terminal.command", payload: { threadId: t.threadId, terminalId: t.terminalId, command: cmd }, at: iso() });
    let out = "";
    if (cmd === "") out = "";
    else if (cmd === "ls" || cmd === "dir") out = "README.md  package.json  src  tsconfig.json\r\n";
    else if (cmd === "pwd") out = `${t.cwd}\r\n`;
    else if (cmd === "pnpm test") out = "\x1b[32m✓\x1b[0m 128 tests passed\r\n";
    else if (cmd.startsWith("echo ")) out = `${cmd.substring(5)}\r\n`;
    else if (cmd === "git status") out = "On branch feature/checkout-steps\r\nChanges not staged for commit:\r\n\t\x1b[31mmodified:   src/checkout/Steps.tsx\x1b[0m\r\n";
    else out = `${cmd.split(" ")[0]}: command not found\r\n`;
    output(t, `\r\n${out}${prompt(t)}`);
  }

  function writeInput(t, data) {
    for (const ch of data) {
      if (ch === "\r" || ch === "\n") {
        const line = t.line;
        t.line = "";
        runLine(t, line);
      } else if (ch === "\x7f" || ch === "\b") {
        if (t.line.length > 0) {
          t.line = t.line.slice(0, -1);
          output(t, "\b \b");
        }
      } else if (ch === "\x03") {
        t.line = "";
        output(t, `^C\r\n${prompt(t)}`);
      } else if (ch >= " ") {
        t.line += ch;
        output(t, ch);
      }
    }
  }

  // ---- Usage --------------------------------------------------------------------------------
  function usageSummary(p) {
    const buckets = [];
    const since = new Date(`${p.sinceDay}T00:00:00`);
    const until = new Date(`${p.untilDay}T00:00:00`);
    let i = 0;
    for (let d = new Date(since); d <= until; d.setDate(d.getDate() + 1), i++) {
      const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
      const wave = 1 + Math.sin(i * 0.9) * 0.5;
      const scale = lab ? 0.4 : 1;
      buckets.push({
        day, provider: "claude", model: "claude-opus-5-5",
        totals: { uncachedInputTokens: Math.round(180000 * wave * scale), cachedInputTokens: Math.round(900000 * wave * scale), cacheCreationTokens: 40000, outputTokens: Math.round(60000 * wave * scale), reasoningTokens: 0 },
        costUsd: Number((6.2 * wave * scale).toFixed(2)), cacheSavingsUsd: 1.1, costSource: "modelPriced", records: 40, unpricedRecords: 0, sessions: 3,
      });
      buckets.push({
        day, provider: "codex", model: "gpt-6.1-sol",
        totals: { uncachedInputTokens: Math.round(90000 * wave), cachedInputTokens: Math.round(300000 * wave), cacheCreationTokens: 0, outputTokens: Math.round(30000 * wave), reasoningTokens: 8000 },
        costUsd: Number((2.4 * wave * scale).toFixed(2)), cacheSavingsUsd: 0.4, costSource: "modelPriced", records: 18, unpricedRecords: 0, sessions: 2,
      });
    }
    return {
      contractVersion: 6, readAt: iso(), timeZone: p.timeZone ?? "Asia/Shanghai", sinceDay: p.sinceDay, untilDay: p.untilDay,
      buckets, sources: [], pricing: { status: "fresh", source: "mock", fetchedAt: iso(), knownModels: 12 }, scanDurationMs: 12,
    };
  }

  const limits = () => ({
    claudeAgent: {
      checkedAt: iso(),
      windows: [
        { id: "session", kind: "session", label: "5 小时", usedPercent: lab ? 12 : 42, resetsAt: iso(2 * 3600000), windowDurationMins: 300 },
        { id: "weekly", kind: "weekly", label: "每周", usedPercent: lab ? 20 : 63, resetsAt: iso(3 * 86400000), windowDurationMins: 10080 },
      ],
    },
    codex: {
      checkedAt: iso(),
      windows: [
        { id: "session", kind: "session", label: "5 小时", usedPercent: 18, resetsAt: iso(4 * 3600000), windowDurationMins: 300 },
        { id: "weekly", kind: "weekly", label: "每周", usedPercent: 91, resetsAt: iso(86400000), windowDurationMins: 10080 },
      ],
    },
  });

  // ---- Pull requests ------------------------------------------------------------------------
  const actor = (login) => ({ login, name: null, avatarUrl: null });
  const freshPrs = () => lab
    ? [
        {
          number: 7, projectId: "p-ml", projectTitle: "trainer", repository: "lab/trainer", title: "cosine 学习率调度",
          author: actor("lab-bot"), headBranch: "exp/cosine", baseBranch: "main", state: "open", isDraft: false,
          checksState: "pending", reviewDecision: "review-required", viewerReviewRequested: true, additions: 44, deletions: 6,
        },
      ]
    : [
        {
          number: 42, projectId: "p-web", projectTitle: "storefront-web", repository: "acme/storefront-web", title: "拆分结账步骤组件",
          author: actor("mock-dev"), headBranch: "feature/checkout-steps", baseBranch: "main", state: "open", isDraft: false,
          checksState: "passing", reviewDecision: "approved", viewerReviewRequested: false, additions: 124, deletions: 31,
        },
        {
          number: 41, projectId: "p-api", projectTitle: "billing-api", repository: "acme/billing-api", title: "升级依赖到最新小版本",
          author: actor("renovate"), headBranch: "deps/minor", baseBranch: "main", state: "open", isDraft: true,
          checksState: "failing", reviewDecision: "review-required", viewerReviewRequested: true, additions: 310, deletions: 280,
        },
        {
          number: 38, projectId: "p-web", projectTitle: "storefront-web", repository: "acme/storefront-web", title: "修复深色模式按钮对比度",
          author: actor("mock-dev"), headBranch: "fix/dark-buttons", baseBranch: "main", state: "merged", isDraft: false,
          checksState: "passing", reviewDecision: "approved", viewerReviewRequested: false, additions: 12, deletions: 9,
        },
      ];
  let prs = freshPrs();

  function entryOf(pr) {
    return {
      provider: "github", host: "github.com", projectId: pr.projectId, projectTitle: pr.projectTitle, repository: pr.repository,
      number: pr.number, title: pr.title, url: `https://github.com/${pr.repository}/pull/${pr.number}`, author: pr.author,
      headBranch: pr.headBranch, baseBranch: pr.baseBranch, state: pr.state, isDraft: pr.isDraft, mergeability: "mergeable",
      additions: pr.additions, deletions: pr.deletions, createdAt: iso(-86400000 * 2), updatedAt: iso(-3600000 * (pr.number % 7) - 600000),
      viewerReviewRequested: pr.viewerReviewRequested, labels: pr.isDraft ? [{ name: "dependencies", color: "0366d6" }] : [],
      reviewDecision: pr.reviewDecision, checksState: pr.checksState,
    };
  }

  function detailOf(pr) {
    return {
      ...entryOf(pr),
      capabilities: {}, viewerPermissions: {}, workspaceRoot: `C:\\code\\${pr.projectTitle}`,
      body: `## 改动\n\n- ${pr.title}\n- 补充了单元测试\n\n## 测试\n\n\`pnpm test\` 全部通过。`,
      changedFiles: 3, mergedAt: pr.state === "merged" ? iso(-3600000) : null, closedAt: null,
      reviewers: [actor("reviewer-a")],
      checks: [
        { name: "build", status: pr.checksState === "failing" ? "failure" : "success", description: null, url: null, required: true },
        { name: "unit-tests", status: pr.checksState === "pending" ? "pending" : "success", description: "128 个测试", url: null },
      ],
      mergeCapabilities: { merge: true, squash: true, rebase: true },
    };
  }

  // ---- Dispatch -----------------------------------------------------------------------------
  function handle(conn, id, tag, p) {
    switch (tag) {
      case "subscribeVcsStatus": {
        const repo = repoFor(p.cwd);
        const sub = { conn, id, cwd: p.cwd };
        vcsSubs.add(sub);
        conn.subs.set(id, { id, kind: "vcs", cancel: () => vcsSubs.delete(sub) });
        chunk(conn, id, [{ _tag: "snapshot", local: repo.local, remote: repo.remote }]);
        return true;
      }
      case "vcs.refreshStatus": {
        const repo = repoFor(p.cwd);
        exitOk(conn, id, { ...repo.local, ...repo.remote });
        return true;
      }
      case "vcs.pull": {
        log({ tag, payload: p, at: iso() });
        const repo = repoFor(p.cwd);
        repo.remote = { ...repo.remote, behindCount: 0 };
        pushStatus(p.cwd);
        exitOk(conn, id, { status: "skipped_up_to_date", refName: repo.local.refName, upstreamRef: `origin/${repo.local.refName}` });
        return true;
      }
      case "git.runStackedAction": {
        log({ tag, payload: p, at: iso() });
        const repo = repoFor(p.cwd);
        const phases = p.action.includes("commit") ? ["commit", "push"] : ["push"];
        if (p.action.endsWith("pr")) phases.push("pr");
        chunk(conn, id, [{ actionId: p.actionId, cwd: p.cwd, action: p.action, kind: "action_started", phases }]);
        setTimeout(() => {
          chunk(conn, id, [{ actionId: p.actionId, cwd: p.cwd, action: p.action, kind: "phase_started", phase: phases[0], label: phases[0] === "commit" ? "正在提交" : "正在推送" }]);
          repo.local = { ...repo.local, hasWorkingTreeChanges: false, workingTree: { files: [], insertions: 0, deletions: 0 } };
          const pr = p.action.endsWith("pr") || p.action === "create_pr"
            ? { number: 43, title: "拆分结账步骤组件", url: "https://github.com/acme/storefront-web/pull/43", baseRef: "main", headRef: repo.local.refName, state: "open" }
            : repo.remote.pr;
          repo.remote = { ...repo.remote, aheadCount: 0, hasUpstream: true, pr };
          pushStatus(p.cwd);
          chunk(conn, id, [{
            actionId: p.actionId, cwd: p.cwd, action: p.action, kind: "action_finished",
            result: { action: p.action, branch: { status: "skipped_not_requested" }, commit: { status: p.action.includes("commit") ? "created" : "skipped_not_requested", commitSha: "abc1234", subject: p.commitMessage ?? "Split checkout steps" }, push: { status: "pushed", branch: repo.local.refName }, pr: { status: pr ? "created" : "skipped_not_requested" } },
          }]);
          exitOk(conn, id, null);
        }, 600);
        return true;
      }
      case "vcs.listRefs": {
        const repo = repoFor(p.cwd);
        exitOk(conn, id, {
          refs: repo.branches.map((name) => ({ name, current: name === repo.local.refName, isDefault: name === "main", worktreePath: null })),
          isRepo: true, hasPrimaryRemote: true, nextCursor: null, totalCount: repo.branches.length,
        });
        return true;
      }
      case "vcs.switchRef": {
        log({ tag, payload: p, at: iso() });
        const repo = repoFor(p.cwd);
        repo.local = { ...repo.local, refName: p.refName, isDefaultRef: p.refName === "main" };
        pushStatus(p.cwd);
        exitOk(conn, id, { refName: p.refName });
        return true;
      }
      case "review.getDiffPreview": {
        const repo = repoFor(p.cwd);
        const dirty = repo.local.hasWorkingTreeChanges;
        exitOk(conn, id, {
          cwd: p.cwd, generatedAt: iso(),
          sources: [{
            id: "working-tree", kind: "working-tree", title: "工作区改动", baseRef: null, headRef: null,
            diff: dirty ? DIFF : "", diffHash: dirty ? "h1" : "h0", truncated: false,
            files: dirty ? [
              { path: "src/checkout/Steps.tsx", previousPath: null, changeType: "change", additions: 5, deletions: 2 },
              { path: "src/checkout/Address.tsx", previousPath: null, changeType: "new", additions: 3, deletions: 0 },
            ] : [],
          }],
        });
        return true;
      }
      case "projects.listEntries": {
        const dir = p.directoryPath ?? "";
        const entries = (TREE[dir] ?? []).map(([path, kind]) => ({ path, kind }));
        exitOk(conn, id, { entries, truncated: false });
        return true;
      }
      case "projects.readFile": {
        const contents = FILES[p.relativePath];
        if (contents === undefined) {
          exitFail(conn, id, `File not found: ${p.relativePath}`);
        } else {
          exitOk(conn, id, { relativePath: p.relativePath, contents, byteLength: Buffer.byteLength(contents), truncated: false, exists: true });
        }
        return true;
      }
      case "subscribeTerminalMetadata": {
        const sub = { conn, id };
        metaSubs.add(sub);
        conn.subs.set(id, { id, kind: "terminal-meta", cancel: () => metaSubs.delete(sub) });
        chunk(conn, id, [{ type: "snapshot", terminals: [...terminals.values()].map(summary) }]);
        return true;
      }
      case "terminal.attach": {
        const key = `${p.threadId}:${p.terminalId}`;
        let t = terminals.get(key);
        if (!t) {
          t = { threadId: p.threadId, terminalId: p.terminalId, cwd: p.cwd ?? "C:\\code", status: "running", history: "", line: "", commands: [], label: "shell", updatedAt: iso(), cols: p.cols ?? 80, rows: p.rows ?? 24 };
          t.history = `Mock shell · ${t.cwd}\r\n${prompt(t)}`;
          terminals.set(key, t);
          log({ tag, payload: p, at: iso() });
          broadcastMeta({ type: "upsert", terminal: summary(t) });
        }
        const sub = { conn, id, key };
        attachSubs.add(sub);
        conn.subs.set(id, { id, kind: "terminal", cancel: () => attachSubs.delete(sub) });
        chunk(conn, id, [{ type: "snapshot", snapshot: snapshotOf(t) }]);
        return true;
      }
      case "terminal.write": {
        log({ tag, payload: p, at: iso() });
        const t = terminals.get(`${p.threadId}:${p.terminalId}`);
        if (!t) {
          exitFail(conn, id, "Terminal not running");
        } else {
          writeInput(t, p.data);
          exitOk(conn, id, null);
        }
        return true;
      }
      case "terminal.resize": {
        const t = terminals.get(`${p.threadId}:${p.terminalId}`);
        if (t) {
          t.cols = p.cols;
          t.rows = p.rows;
        }
        exitOk(conn, id, null);
        return true;
      }
      case "terminal.close": {
        log({ tag, payload: p, at: iso() });
        const key = `${p.threadId}:${p.terminalId}`;
        const t = terminals.get(key);
        if (t) {
          terminals.delete(key);
          for (const sub of attachSubs) if (sub.key === key && !sub.conn.closed) chunk(sub.conn, sub.id, [{ type: "closed", threadId: t.threadId, terminalId: t.terminalId }]);
          broadcastMeta({ type: "remove", threadId: t.threadId, terminalId: t.terminalId });
        }
        exitOk(conn, id, null);
        return true;
      }
      case "server.getUsageSummary":
        exitOk(conn, id, usageSummary(p));
        return true;
      case "pullRequests.list": {
        const state = p.state ?? "open";
        let list = prs.filter((pr) => state === "all" || pr.state === state);
        if (p.involvement === "reviewing") list = list.filter((pr) => pr.viewerReviewRequested);
        if (p.involvement === "authored") list = list.filter((pr) => pr.author?.login === "mock-dev");
        if (p.query) list = list.filter((pr) => pr.title.includes(p.query) || String(pr.number) === p.query.replace("#", ""));
        exitOk(conn, id, {
          viewers: { "github.com": "mock-dev" },
          providers: [{ host: "github.com", kind: "github", searchesOnHost: true, projectCount: 2, configured: true, detail: null }],
          entries: list.map(entryOf), errors: [], truncated: false, nextCursors: {},
        });
        return true;
      }
      case "pullRequests.detail": {
        const pr = prs.find((x) => x.number === p.number && x.repository === p.repository);
        if (!pr) exitFail(conn, id, "Pull request not found");
        else exitOk(conn, id, detailOf(pr));
        return true;
      }
      case "pullRequests.runAction": {
        log({ tag, payload: p, at: iso() });
        const pr = prs.find((x) => x.number === p.number && x.repository === p.repository);
        if (!pr) {
          exitFail(conn, id, "Pull request not found");
          return true;
        }
        if (p.action === "merge") pr.state = "merged";
        if (p.action === "close") pr.state = "closed";
        if (p.action === "reopen") pr.state = "open";
        if (p.action === "ready") pr.isDraft = false;
        if (p.action === "draft") pr.isDraft = true;
        exitOk(conn, id, undefined);
        return true;
      }
      default:
        return false;
    }
  }

  function reset() {
    repos.clear();
    terminals.clear();
    prs = freshPrs();
  }

  return { handle, reset, limits };
}
