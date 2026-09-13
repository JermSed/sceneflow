// cut/run.js — the orchestrator.
//
// One request — "@claude cut this board" pinned on a Sceneflow
// canvas — turns into a run across three external apps:
//
//   Sceneflow (Automerge)  read the storyboard, in order
//   Google Drive           catalog the footage, fetch poster frames
//   [judgement]            match beats to clips, decide the grade
//   Google Drive           download only the clips that won
//   DaVinci Resolve        build + grade the timeline, mark the holes
//   Todoist                file every unshot beat with its sketch
//   Sceneflow              report back on the board
//
// Two properties this file is responsible for:
//
//   RESUMABILITY. Every stage writes into one report object and the
//   report is persisted per board under .state/. A run that dies at
//   the Resolve stage has already cached its downloads and can be
//   re-run without re-paying for any of it.
//
//   PARTIAL SUCCESS. No stage is allowed to take down the run. If
//   Todoist is down you still get a graded timeline and a report that
//   says Todoist is down. The alternative — an agent that throws away
//   four minutes of work because the last API call failed — is the
//   most common way these things are useless in practice.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { boardToBeats } from "./beats.js";
import { matchBeatsToClips } from "./match.js";
import { renderFramePNG } from "../render.js";
import * as driveModule from "../apps/drive.js";
import { buildTimeline as buildTimelineReal } from "../apps/resolve.js";
import { Todoist as TodoistReal } from "../apps/todoist.js";

/** The three external apps, injectable.
 *
 * Not a testing afterthought: it is the reason the whole
 * orchestration — ordering, matching, repair, partial failure,
 * idempotency — can be exercised in milliseconds with no Drive
 * account, no Resolve install, and no Todoist token, which is what
 * makes `npm test` something a reviewer can actually run. The eval
 * suite substitutes recorded catalogs and fault-injecting doubles
 * through this same seam. */
export const REAL_APPS = {
  drive: driveModule,
  buildTimeline: buildTimelineReal,
  Todoist: TodoistReal,
};

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATE_DIR = path.resolve(HERE, "../../.state");

export const DEFAULTS = {
  driveFolder: process.env.SCENEFLOW_DRIVE_FOLDER ?? "SceneFlowDemo",
  todoistProject: process.env.SCENEFLOW_TODOIST_PROJECT ?? "Shoot List",
  resolveProject: process.env.SCENEFLOW_RESOLVE_PROJECT ?? "Sceneflow",
};

/** Let the director steer the run from the comment itself:
 *   "@claude cut  folder:B-Roll Sept  list:Reshoots  dry"
 * Unrecognized words are ignored, so a natural sentence still works. */
export function parseCutRequest(text = "") {
  // A multi-word value must be quoted. Without that rule a trailing
  // flag ("list:Reshoots dry") gets swallowed into the value, which
  // is exactly the kind of quiet misparse that makes an agent file
  // tasks into a project nobody has.
  const grab = key => {
    const m = text.match(new RegExp(`\\b(?:${key}):\\s*(?:"([^"]+)"|'([^']+)'|(\\S+))`, "i"));
    return (m?.[1] ?? m?.[2] ?? m?.[3] ?? "").trim();
  };
  return {
    // The board's name, for the Resolve timeline. Without it the
    // timeline is named after the share token, which is the first
    // thing anyone opening the project sees.
    boardName: grab("name|board") || undefined,
    driveFolder: grab("folder|drive") || DEFAULTS.driveFolder,
    todoistProject: grab("list|todoist") || DEFAULTS.todoistProject,
    resolveProject: grab("project|resolve") || DEFAULTS.resolveProject,
    dryRun: /\b(dry|dry-run|edl)\b/i.test(text),
  };
}

/** Matches the trigger phrase, not just the mention — the assistant
 * still answers ordinary questions; only "cut" starts a run. */
export const CUT_RE = /\b(cut|assemble|build the (?:cut|edit|timeline))\b/i;

function saveReport(docId, report) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(STATE_DIR, `run-${String(docId).replace(/\W/g, "_")}.json`),
    JSON.stringify(report, null, 2),
  );
}

/** Run one stage, recording what happened either way. A stage that
 * throws is recorded and the run continues. */
async function stage(report, name, fn) {
  const started = Date.now();
  try {
    const value = await fn();
    report.stages.push({ name, ok: true, ms: Date.now() - started });
    return value;
  } catch (err) {
    report.stages.push({ name, ok: false, ms: Date.now() - started, error: err.message });
    report.problems.push(`${name}: ${err.message}`);
    return null;
  }
}

/**
 * @param doc      the Automerge board document (plain read is fine)
 * @param options  from parseCutRequest, plus { docId, boardName, onLog }
 */
export async function runCut(doc, options = {}) {
  const opts = { ...DEFAULTS, ...options };
  const { drive, buildTimeline, Todoist } = { ...REAL_APPS, ...(options.apps ?? {}) };
  const log = opts.onLog ?? (m => console.log(`[cut] ${m}`));
  const report = {
    startedAt: new Date().toISOString(),
    board: opts.boardName ?? opts.docId ?? "board",
    options: { driveFolder: opts.driveFolder, todoistProject: opts.todoistProject, resolveProject: opts.resolveProject, dryRun: !!opts.dryRun },
    stages: [],
    problems: [],
  };

  // ---- 1. Sceneflow: the storyboard, in order --------------------
  const rawFrames = Array.from(doc?.snapshots ?? []);
  const beats = boardToBeats(doc).map(b => ({
    ...b,
    // Carry the strokes through for rendering; beats.js keeps only
    // the count so its own logic stays cheap and comparable.
    strokes: Array.from(rawFrames.find(s => String(s.id).toUpperCase() === b.id)?.strokes ?? []),
  }));
  report.beatCount = beats.length;
  report.orderedBy = beats[0]?.orderedBy ?? "none";
  log(`${beats.length} beats, ordered by ${report.orderedBy}`);
  if (beats.length === 0) {
    report.problems.push("board has no captured frames — nothing to cut");
    saveReport(opts.docId, report);
    return report;
  }

  // ---- 2. Google Drive: the footage catalog ----------------------
  let clips = await stage(report, "drive.catalog", async () => {
    const folder = await drive.findFolder(opts.driveFolder);
    const found = await drive.listFootage(folder.id);
    log(`Drive: ${found.length} clips in "${folder.name}"`);
    // Poster frames, in parallel but bounded — Drive throttles bursts.
    for (let i = 0; i < found.length; i += 5) {
      const batch = found.slice(i, i + 5);
      await Promise.all(batch.map(async c => {
        try { c.thumbnail = await drive.fetchThumbnail(c); } catch { c.thumbnail = null; }
      }));
    }
    report.driveFolderId = folder.id;
    return found;
  }) ?? [];
  report.clipCount = clips.length;
  report.thumbnailCount = clips.filter(c => c.thumbnail).length;

  // ---- 3. Judgement: beats -> clips ------------------------------
  const match = options.matcher ?? matchBeatsToClips;
  const cut = await stage(report, "match", () => match(beats, clips, { onLog: log }));
  if (!cut) {
    saveReport(opts.docId, report);
    return report;
  }
  report.sequenceNotes = cut.sequenceNotes;
  report.matchWarnings = cut.warnings;
  // The reconciler already checks assignments against the catalog it
  // was given, but the catalog can be empty (Drive failed) or stale
  // (a clip was moved mid-run). Re-check against what we actually
  // hold before anything reaches Drive or Resolve: an unknown id
  // becomes an unshot beat, which is a task, not a crash.
  const catalogIds = new Set(clips.map(c => c.id));
  for (const a of cut.assignments) {
    if (a.clipId && !catalogIds.has(a.clipId)) {
      cut.warnings.push(`beat ${a.index}: clip ${a.clipId} is not in the catalog — treated as unshot`);
      a.clipId = null;
    }
  }

  const matched = cut.assignments.filter(a => a.clipId);
  const missing = cut.assignments.filter(a => !a.clipId);
  report.matchedCount = matched.length;
  report.missingCount = missing.length;
  log(`matched ${matched.length}/${beats.length} beats; ${missing.length} unshot`);
  for (const w of cut.warnings) log(`  ! ${w}`);

  // ---- 4. Google Drive: pull down only what made the cut ---------
  const byId = new Map(clips.map(c => [c.id, c]));
  await stage(report, "drive.download", async () => {
    const totalMB = matched.reduce((n, a) => n + (byId.get(a.clipId)?.sizeBytes ?? 0), 0) / 1e6;
    if (totalMB > 500) {
      // Worth saying out loud: a multi-gigabyte pull is minutes of
      // silence otherwise, and the most likely reason someone thinks
      // the agent has hung.
      log(`Drive: ${totalMB.toFixed(0)} MB to fetch — this is the slow stage. Cached clips are reused on a re-run.`);
    }
    for (const a of matched) {
      const clip = byId.get(a.clipId);
      a.clipName = clip.name;
      a.clipPath = await drive.downloadClip(clip, c =>
        log(`Drive: downloading ${c.name} (${((c.sizeBytes ?? 0) / 1e6).toFixed(0)} MB)`));
      // Fall back to the clip's own length when the model declined
      // to pick a duration — better a full clip than a zero-length one.
      a.durationSeconds ??= clip.durationSeconds ? Math.min(6, clip.durationSeconds) : 3;
      a.startSeconds ??= 0;
    }
    log(`Drive: ${matched.length} clip(s) cached locally`);
  });

  // ---- 5. DaVinci Resolve: build + grade the timeline ------------
  const plan = {
    projectName: opts.resolveProject,
    timelineName: `${report.board} — Sceneflow Cut`,
    rebuild: true,
    beats: cut.assignments.map(a => ({
      index: a.index, key: a.key, description: a.description,
      clipPath: a.clipPath ?? null,
      startSeconds: a.startSeconds ?? null,
      durationSeconds: a.durationSeconds ?? null,
      look: a.look,
      // `grade: false` lays the cut down ungraded. Worth having as a
      // switch rather than a code change: the assembly is the part
      // you cannot do by hand in a minute, and on someone else's
      // footage a grade is a matter of taste that should never be
      // the reason the useful half is unusable.
      cdl: opts.grade === false ? null : a.cdl,
    })),
  };
  report.resolve = await stage(report, "resolve.timeline", () =>
    buildTimeline(plan, { dryRun: opts.dryRun, onLog: m => log(m) }));
  if (report.resolve) {
    log(`Resolve: ${report.resolve.mode === "resolve" ? "built in Resolve" : `EDL fallback (${report.resolve.reason})`}`);
  }

  // ---- 6. Todoist: everything that still needs shooting ----------
  report.todoist = await stage(report, "todoist.shotlist", async () => {
    if (missing.length === 0) {
      log("Todoist: nothing missing — no tasks filed");
      return { created: 0, existing: 0, tasks: [] };
    }
    const todoist = new Todoist();
    const project = await todoist.ensureProject(opts.todoistProject);
    const open = await todoist.openTasks(project.id);
    const filed = [];
    let created = 0, existing = 0;
    for (const beat of missing) {
      const { task, created: isNew } = await todoist.ensureShotTask(project.id, open, {
        frameKey: beat.key,
        title: `Shoot: ${beat.description}`,
        description:
          `Storyboard beat ${beat.index} of ${beats.length} on "${report.board}" has no footage in ` +
          `Drive/${opts.driveFolder}.\n\n` +
          (beat.look ? `Intended look: ${beat.look}\n` : "") +
          (beat.reason ? `Why unmatched: ${beat.reason}\n` : "") +
          (beat.labels?.length ? `Board notes: ${beat.labels.join(" | ")}\n` : ""),
        labels: ["sceneflow"],
      });
      if (isNew) {
        created += 1;
        // Attach the sketch. If the upload fails the task still
        // stands — a task without a picture is a minor loss.
        try {
          const png = renderFramePNG(
            { width: beat.width, height: beat.height, strokes: beat.strokes ?? [] },
            { label: `Beat ${beat.index} — ${beat.description}` },
          );
          if (png && beat.strokeCount > 0) {
            await todoist.attachImage(task.id, `beat-${beat.index}-${beat.key}.png`, png.png);
          }
        } catch (err) {
          report.problems.push(`todoist.attach beat ${beat.index}: ${err.message}`);
        }
      } else {
        existing += 1;
      }
      filed.push({ beat: beat.index, taskId: task.id, url: task.url ?? null, created: isNew });
    }
    log(`Todoist: ${created} task(s) filed, ${existing} already on the list`);
    return { project: project.name, projectId: project.id, created, existing, tasks: filed };
  });

  report.finishedAt = new Date().toISOString();
  report.ok = report.problems.length === 0;
  saveReport(opts.docId, report);
  return report;
}

/** The report as a comment for the board — plain text, short, and
 * specific, because it gets pinned next to the question. */
export function reportToComment(report) {
  const lines = [];
  const r = report.resolve;
  lines.push(
    `Cut assembled: ${report.matchedCount ?? 0} of ${report.beatCount ?? 0} beats matched to footage.`,
  );
  if (r?.mode === "resolve") lines.push(`Resolve: timeline "${r.timeline}" in project ${r.project}, ${r.placed?.length ?? 0} clips placed, ${r.graded?.length ?? 0} graded, ${r.markers?.length ?? 0} gap markers.`);
  else if (r) lines.push(`Resolve unavailable (${r.reason}) — wrote an importable EDL instead: ${r.edlPath}`);
  if (report.todoist) {
    lines.push(
      report.todoist.created || report.todoist.existing
        ? `Todoist "${report.todoist.project}": ${report.todoist.created} new task(s), ${report.todoist.existing} already filed.`
        : `Todoist: nothing missing.`,
    );
  }
  if (report.sequenceNotes) lines.push(report.sequenceNotes);
  if (report.problems?.length) lines.push(`Problems: ${report.problems.join("; ")}`);
  const text = lines.join("\n");
  // Board comments are pinned UI, not a log — keep them readable.
  return text.length > 900 ? `${text.slice(0, 880)}…` : text;
}
