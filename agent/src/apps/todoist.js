// apps/todoist.js — external app #3: Todoist.
//
// This is where the agent's *negative* result goes, and that's the
// point. An edit assistant that quietly drops the six frames it
// couldn't match is worse than useless on a real production — the
// whole value is knowing what's still missing. Every storyboard beat
// with no footage behind it becomes a task on a shoot list, with the
// sketch attached so whoever picks it up can see what to shoot.
//
// Two things make this safe to run more than once:
//
//   • IDEMPOTENCY. Each task carries `[sf:<frameKey>]` in its text.
//     Before creating anything the agent reads the project's open
//     tasks and skips keys it already filed. Todoist has no
//     upsert-by-external-id, so the key lives in content where both
//     the API and a human can see it.
//   • API DRIFT. Todoist is mid-migration from REST v2 to the
//     unified v1 API. Rather than bet on one, the client probes v1
//     once and falls back to v2, normalizing both response shapes.

const V1 = "https://api.todoist.com/api/v1";
const V2 = "https://api.todoist.com/rest/v2";

/** Marker embedded in task text so a re-run recognizes its own work. */
export function taskMarker(frameKey) {
  return `[sf:${frameKey}]`;
}

export class Todoist {
  constructor(token = process.env.TODOIST_API_TOKEN) {
    if (!token) {
      throw new Error(
        "TODOIST_API_TOKEN is not set. Todoist > Settings > Integrations > Developer.",
      );
    }
    this.token = token;
    this.base = null; // resolved on first use
  }

  get headers() {
    return { Authorization: `Bearer ${this.token}` };
  }

  /** Pick an API version once, then stick with it.
   *
   * The failure message matters as much as the probe: "could not
   * reach Todoist" with no cause is the least useful thing to read
   * ten minutes before a demo, and the three reasons this fails —
   * bad token, no network, both versions retired — need different
   * fixes. So each attempt's actual outcome is carried into the
   * error. */
  async resolveBase() {
    if (this.base) return this.base;
    const tried = [];
    for (const candidate of [V1, V2]) {
      let res;
      try {
        res = await fetch(`${candidate}/projects`, { headers: this.headers });
      } catch (err) {
        // A transport failure is a network/DNS/egress problem, not a
        // version problem — trying v2 will fail identically.
        tried.push(`${candidate}: ${err.cause?.code ?? err.message}`);
        continue;
      }
      if (res.ok) { this.base = candidate; return this.base; }
      // 401 is the token, not the version. Stop rather than making a
      // second doomed request and blaming the API shape.
      if (res.status === 401) {
        throw new Error("Todoist rejected the token (401) — check TODOIST_API_TOKEN.");
      }
      tried.push(`${candidate}: HTTP ${res.status}`);
    }
    throw new Error(`Could not reach the Todoist API. Tried — ${tried.join("; ")}`);
  }

  async request(method, endpoint, body, { retries = 3 } = {}) {
    const base = await this.resolveBase();
    let lastError;
    for (let attempt = 0; attempt <= retries; attempt++) {
      const res = await fetch(`${base}${endpoint}`, {
        method,
        headers: {
          ...this.headers,
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      // Todoist rate-limits hard on bursts; honor Retry-After rather
      // than hammering, and treat 5xx as transient.
      if (res.status === 429 || res.status >= 500) {
        const wait = Number(res.headers.get("retry-after")) * 1000
          || Math.min(2 ** attempt * 500, 8000);
        lastError = new Error(`Todoist ${res.status} on ${endpoint}`);
        await new Promise(r => setTimeout(r, wait));
        continue;
      }
      if (!res.ok) {
        throw new Error(`Todoist ${res.status} on ${method} ${endpoint}: ${await res.text()}`);
      }
      if (res.status === 204) return null;
      return await res.json();
    }
    throw lastError;
  }

  /** Both API versions return either a bare array (v2) or
   * `{results, next_cursor}` (v1). Normalize and page. */
  async list(endpoint) {
    const out = [];
    let cursor;
    do {
      const sep = endpoint.includes("?") ? "&" : "?";
      const page = await this.request(
        "GET",
        cursor ? `${endpoint}${sep}cursor=${encodeURIComponent(cursor)}` : endpoint,
      );
      if (Array.isArray(page)) { out.push(...page); cursor = null; }
      else { out.push(...(page.results ?? [])); cursor = page.next_cursor ?? null; }
    } while (cursor);
    return out;
  }

  /** Find or create the shoot-list project. Never creates a second
   * project with the same name. */
  async ensureProject(name) {
    const existing = (await this.list("/projects")).find(p => p.name === name);
    if (existing) return existing;
    return await this.request("POST", "/projects", { name });
  }

  async openTasks(projectId) {
    return await this.list(`/tasks?project_id=${encodeURIComponent(projectId)}`);
  }

  /**
   * File one missing-shot task, unless this frame already has one.
   * @returns {{task: object, created: boolean}}
   */
  async ensureShotTask(projectId, existingTasks, { frameKey, title, description, priority = 2, labels = [] }) {
    const marker = taskMarker(frameKey);
    const already = existingTasks.find(t => (t.content ?? "").includes(marker));
    if (already) return { task: already, created: false };
    const task = await this.request("POST", "/tasks", {
      content: `${title} ${marker}`,
      description,
      project_id: String(projectId),
      priority,
      labels,
    });
    existingTasks.push(task);
    return { task, created: true };
  }

  /** Upload bytes and attach them to a task as a comment. This is how
   * the storyboard sketch itself reaches the shoot list — the person
   * filming sees the drawing, not just a line of text. */
  async attachImage(taskId, filename, buffer, mediaType = "image/png") {
    const base = await this.resolveBase();
    const form = new FormData();
    form.append("file_name", filename);
    form.append("file", new Blob([buffer], { type: mediaType }), filename);
    // v1 exposes /uploads; v2's sibling lives on the sync API.
    const uploadUrl = base === V1
      ? `${V1}/uploads`
      : "https://api.todoist.com/sync/v9/uploads/add";
    const up = await fetch(uploadUrl, { method: "POST", headers: this.headers, body: form });
    if (!up.ok) throw new Error(`Todoist upload failed (${up.status}): ${await up.text()}`);
    const attachment = await up.json();
    return await this.request("POST", "/comments", {
      task_id: String(taskId),
      content: "Storyboard frame from Sceneflow",
      attachment,
    });
  }
}
