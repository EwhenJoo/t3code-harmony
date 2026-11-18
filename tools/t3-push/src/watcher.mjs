// Keeps each computer's thread list from the shell stream and reports the moments the phone app
// notifies about: the agent needs an approval or an answer, a run finished, or a run failed.
//
// The first snapshot after the helper starts is history, not news. Marks survive reconnects, so a
// thread that finished while the socket was down is still reported when the next snapshot arrives.

function parseTime(value) {
  const t = value ? Date.parse(value) : NaN;
  return Number.isFinite(t) ? t : 0;
}

function isWatched(thread) {
  if (!thread || thread.deletedAt || thread.archivedAt) return false;
  return (thread.lineage?.relationshipToParent ?? null) !== "subagent";
}

/** The same test the app's list uses for "运行中": real T3 reports a run as `queued` + an active run. */
const WORKING_STATUSES = new Set(["preparing", "queued", "starting", "running", "waiting"]);

export function isWorking(thread) {
  return WORKING_STATUSES.has(String(thread.status ?? ""))
    || (thread.activeRunId ?? null) !== null
    || thread.activityRunStatus === "running";
}

function markOf(thread) {
  const request = thread.pendingRuntimeRequest ?? null;
  return {
    attentionId: request ? String(request.id ?? "pending") : "",
    attentionKind: request?.kind ?? "",
    status: String(thread.status ?? ""),
    working: isWorking(thread),
    runId: String(thread.latestRunId ?? thread.activeRunId ?? ""),
  };
}

export class ThreadWatcher {
  /** `emit(event)` receives { kind: 'approval'|'input'|'done'|'failed', envId, envLabel, thread, project, identity }. */
  constructor(emit) {
    this.emit = emit;
    this.envs = new Map();
  }

  env(envId) {
    let env = this.envs.get(envId);
    if (!env) {
      env = { threads: new Map(), projects: new Map(), marks: new Map(), primed: false };
      this.envs.set(envId, env);
    }
    return env;
  }

  apply(envId, envLabel, items) {
    const env = this.env(envId);
    let sawSnapshot = false;
    for (const item of items) {
      switch (item?.kind) {
        case "snapshot": {
          if (!item.snapshot) break;
          env.threads = new Map((item.snapshot.threads ?? []).map((t) => [t.id, t]));
          env.projects = new Map((item.snapshot.projects ?? []).map((p) => [p.id, p]));
          sawSnapshot = true;
          break;
        }
        case "thread.updated":
          if (!item.thread) break;
          if (item.location === "archive") env.threads.delete(item.thread.id);
          else env.threads.set(item.thread.id, item.thread);
          break;
        case "thread.removed":
          env.threads.delete(item.threadId);
          break;
        case "project.updated":
          if (item.project) env.projects.set(item.project.id, item.project);
          break;
        case "project.removed":
          env.projects.delete(item.projectId);
          break;
        default:
          break;
      }
    }
    if (!env.primed) {
      if (!sawSnapshot) return;
      for (const thread of env.threads.values()) env.marks.set(thread.id, markOf(thread));
      env.primed = true;
      return;
    }
    this.diff(envId, envLabel, env);
  }

  diff(envId, envLabel, env) {
    const now = Date.now();
    for (const thread of env.threads.values()) {
      const before = env.marks.get(thread.id);
      const mark = markOf(thread);
      env.marks.set(thread.id, mark);
      if (!before || !isWatched(thread)) continue;
      const project = env.projects.get(thread.projectId) ?? null;
      const base = { envId, envLabel, thread, project };
      if (mark.attentionId && mark.attentionId !== before.attentionId) {
        const kind = mark.attentionKind === "user_input" ? "input" : "approval";
        this.emit({ ...base, kind, identity: `${kind}:${mark.attentionId}` });
        continue;
      }
      if (parseTime(thread.snoozedUntil) > now) continue;
      const run = mark.runId || thread.updatedAt || now;
      if (mark.status === "failed" && before.status !== "failed") {
        this.emit({ ...base, kind: "failed", identity: `failed:${run}` });
      } else if (before.working && !mark.working) {
        // A run you stopped yourself needs no notice.
        if (mark.status === "interrupted" || mark.status === "cancelled") continue;
        this.emit({ ...base, kind: "done", identity: `done:${run}` });
      }
    }
    for (const id of env.marks.keys()) {
      if (!env.threads.has(id)) env.marks.delete(id);
    }
  }
}

/** What the notification says. Only titles travel through the push service, never message text. */
export function describe(event) {
  const title = event.thread.title || "对话";
  // Threads outside any project come with a placeholder project; leave it out.
  const project = event.project?.title && !/^no project$/i.test(event.project.title) ? event.project.title : "";
  const where = [project, event.envLabel].filter(Boolean).join(" · ");
  const what = {
    approval: "需要你批准",
    input: "等你回答",
    done: "已完成",
    failed: "运行失败",
  }[event.kind];
  return { title, body: where ? `${what} · ${where}` : what };
}

export function threadLink(envId, threadId) {
  return `t3code://thread?id=${encodeURIComponent(threadId)}&env=${encodeURIComponent(envId)}`;
}
