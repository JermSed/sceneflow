// test/fakes.js — stand-ins for the three external apps.
//
// Deliberately behavioral rather than assertion-only: the fake
// Todoist really does store tasks and really does dedupe on the
// `[sf:KEY]` marker, so the idempotency test proves the agent's
// logic rather than proving that a stub was called twice.

export function fakeDrive({ clips = [], failOn = null } = {}) {
  const downloaded = [];
  return {
    downloaded,
    findFolder: async name => {
      if (failOn === "findFolder") throw new Error("Drive is unreachable");
      return { id: "folder-1", name };
    },
    listFootage: async () => {
      if (failOn === "listFootage") throw new Error("Drive 429 rate limited");
      return clips.map(c => ({ ...c }));
    },
    fetchThumbnail: async () => null,
    downloadClip: async clip => {
      if (failOn === "downloadClip") throw new Error("Drive download failed mid-stream");
      downloaded.push(clip.id);
      return `/tmp/media/${clip.id}__${clip.name}`;
    },
  };
}

export function fakeResolve({ fail = false } = {}) {
  const calls = [];
  const buildTimeline = async plan => {
    calls.push(plan);
    if (fail) return { ok: true, mode: "edl", reason: "Resolve is not running", edlPath: "/tmp/x.edl", placed: [], skipped: [] };
    return {
      ok: true, mode: "resolve", project: plan.projectName, timeline: plan.timelineName,
      placed: plan.beats.filter(b => b.clipPath).map(b => ({ beat: b.index, clip: b.clipPath })),
      skipped: plan.beats.filter(b => !b.clipPath).map(b => ({ beat: b.index, reason: "no clip matched" })),
      graded: plan.beats.filter(b => b.clipPath && b.cdl).map(b => ({ beat: b.index, look: b.look })),
      markers: plan.beats.filter(b => !b.clipPath).map(b => ({ beat: b.index })),
    };
  };
  buildTimeline.calls = calls;
  return buildTimeline;
}

/** A Todoist that persists across constructions, so a second run of
 * the agent sees the first run's tasks — which is the only way to
 * test idempotency honestly. */
export function fakeTodoistFactory({ failOn = null } = {}) {
  const projects = [];
  const tasks = [];
  let nextId = 1;
  class FakeTodoist {
    constructor() {
      if (failOn === "construct") throw new Error("TODOIST_API_TOKEN is not set.");
    }
    async ensureProject(name) {
      if (failOn === "ensureProject") throw new Error("Todoist 401 unauthorized");
      let p = projects.find(p => p.name === name);
      if (!p) { p = { id: `p${projects.length + 1}`, name }; projects.push(p); }
      return p;
    }
    async openTasks(projectId) {
      return tasks.filter(t => t.project_id === projectId);
    }
    async ensureShotTask(projectId, existing, { frameKey, title, description }) {
      const marker = `[sf:${frameKey}]`;
      const already = existing.find(t => t.content.includes(marker));
      if (already) return { task: already, created: false };
      const task = { id: `t${nextId++}`, project_id: projectId, content: `${title} ${marker}`, description, url: null };
      tasks.push(task); existing.push(task);
      return { task, created: true };
    }
    async attachImage(taskId, filename) {
      if (failOn === "attachImage") throw new Error("upload failed (413)");
      const t = tasks.find(t => t.id === taskId);
      if (t) t.attachment = filename;
      return { ok: true };
    }
  }
  FakeTodoist.state = { projects, tasks };
  return FakeTodoist;
}

/** A matcher with a scripted answer, so pipeline tests are about
 * orchestration rather than about model behavior. */
export function scriptedMatcher(map, { sequenceNotes = "scripted", warnings = [] } = {}) {
  return async beats => ({
    assignments: beats.map(b => ({
      ...b,
      clipId: map[b.index] ?? null,
      confidence: map[b.index] ? 0.9 : 0,
      reason: "scripted",
      look: "neutral",
      cdl: { slope: [1, 1, 1], offset: [0, 0, 0], power: [1, 1, 1], saturation: 1 },
      startSeconds: 0,
      durationSeconds: 3,
    })),
    sequenceNotes,
    warnings,
  });
}
