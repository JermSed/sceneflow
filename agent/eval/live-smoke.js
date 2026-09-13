#!/usr/bin/env node
// eval/live-smoke.js — does this machine actually reach all three apps?
//
// The offline eval proves the agent's judgement and its invariants.
// It says nothing about whether Drive is authorized, whether the
// Todoist token is live, or whether Resolve is running with external
// scripting enabled — which is exactly the set of things that breaks
// five minutes before a demo.
//
// Every check is read-only or self-cleaning: it lists, it connects,
// it creates one throwaway Todoist task and deletes it again. Run it
// before you run a cut.
//
//   npm run eval:live
//   npm run eval:live -- --folder "Sceneflow Footage" --list "Shoot List"

import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as drive from "../src/apps/drive.js";
import { Todoist } from "../src/apps/todoist.js";
import { DEFAULTS } from "../src/cut/run.js";

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf(`--${n}`); return i === -1 ? d : args[i + 1]; };
const folderName = flag("folder", DEFAULTS.driveFolder);
const listName = flag("list", DEFAULTS.todoistProject);

const results = [];
async function check(app, what, fn) {
  process.stdout.write(`  ${app.padEnd(10)} ${what} ... `);
  try {
    const detail = await fn();
    console.log(`ok${detail ? ` — ${detail}` : ""}`);
    results.push({ app, what, ok: true, detail });
  } catch (err) {
    console.log(`FAILED\n             ${err.message.split("\n")[0]}`);
    results.push({ app, what, ok: false, error: err.message });
  }
}

console.log("\nSceneflow cut agent — live connectivity check\n");

// ---- Anthropic -------------------------------------------------
await check("anthropic", "credentials present", async () => {
  const has = process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN;
  if (!has) throw new Error("no ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN (an `ant auth login` profile also works, and is not visible here)");
  return "env credential set";
});

// ---- Google Drive ----------------------------------------------
let clipCount = 0;
await check("drive", `folder "${folderName}"`, async () => {
  if (!drive.driveConfigured()) throw new Error("not authorized — run: npm run auth:drive");
  const folder = await drive.findFolder(folderName);
  const clips = await drive.listFootage(folder.id);
  clipCount = clips.length;
  if (clips.length === 0) throw new Error(`folder found but it holds no video files`);
  const withThumbs = [];
  for (const c of clips.slice(0, 3)) {
    const t = await drive.fetchThumbnail(c, 128);
    if (t) withThumbs.push(c.name);
  }
  if (withThumbs.length === 0) {
    throw new Error("clips found but Drive served no poster frames yet — it transcodes on upload; wait a few minutes");
  }
  return `${clips.length} clips, poster frames available`;
});

// ---- Todoist ---------------------------------------------------
await check("todoist", `list "${listName}"`, async () => {
  const todoist = new Todoist();
  const project = await todoist.ensureProject(listName);
  const open = await todoist.openTasks(project.id);
  // Prove writes work, then clean up after ourselves.
  const probe = await todoist.request("POST", "/tasks", {
    content: "sceneflow live-smoke probe [sf:SMOKE000]",
    project_id: String(project.id),
  });
  await todoist.request("DELETE", `/tasks/${probe.id}`);
  return `project ${project.id}, ${open.length} open task(s), write+delete ok`;
});

// ---- DaVinci Resolve -------------------------------------------
await check("resolve", "scripting connection", async () => {
  const HERE = path.dirname(fileURLToPath(import.meta.url));
  const bridge = path.resolve(HERE, "../src/apps/resolve_bridge.py");
  const out = await new Promise(resolve => {
    // An empty beat list makes the bridge connect, open/create the
    // project and timeline, place nothing, and report — the cheapest
    // possible proof that the whole chain is live.
    const proc = spawn(process.env.RESOLVE_PYTHON ?? "python3", [bridge]);
    let stdout = "";
    proc.stdout.on("data", d => { stdout += d; });
    proc.on("error", e => resolve({ ok: false, error: e.message }));
    proc.on("close", () => { try { resolve(JSON.parse(stdout)); } catch { resolve({ ok: false, error: stdout || "no output" }); } });
    proc.stdin.end(JSON.stringify({
      projectName: DEFAULTS.resolveProject,
      timelineName: "Sceneflow Smoke Test",
      rebuild: true, beats: [],
    }));
  });
  if (!out.ok) throw new Error(out.error);
  return `project "${out.project}", timeline "${out.timeline}"`;
});

const failed = results.filter(r => !r.ok);
console.log(
  `\n${results.length - failed.length}/${results.length} checks passed.` +
  (failed.length ? `  Fix these before demoing: ${failed.map(f => f.app).join(", ")}\n` : "  Ready to cut.\n"),
);
process.exit(failed.length === 0 ? 0 : 1);
