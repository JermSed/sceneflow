// apps/resolve.js — the Node side of the Resolve integration.
//
// Resolve's API lives inside a Python module that only loads next to
// a running Resolve, so this module's whole job is to hand a plan to
// resolve_bridge.py and interpret what comes back. Keeping the
// boundary at "one JSON plan in, one JSON result out" means the
// orchestrator can be tested with no Resolve anywhere in sight, and
// the bridge can be run by hand against a saved plan when something
// goes wrong on a real machine.
//
// It also means there is a meaningful DRY RUN: the same plan that
// drives Resolve can be written out as a CMX3600 EDL instead. That is
// not a mock — an EDL is a real, importable conform of the same cut,
// which keeps the agent useful on a machine without Resolve Studio
// and gives the eval suite something exact to assert against.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BRIDGE = path.join(HERE, "resolve_bridge.py");

/** Seconds -> 00:00:00:00 timecode at a given frame rate. */
export function timecode(seconds, fps = 24) {
  const totalFrames = Math.max(0, Math.round(seconds * fps));
  const f = totalFrames % fps;
  const totalSec = Math.floor(totalFrames / fps);
  const pad = n => String(n).padStart(2, "0");
  return `${pad(Math.floor(totalSec / 3600))}:${pad(Math.floor(totalSec / 60) % 60)}:${pad(totalSec % 60)}:${pad(f)}`;
}

/**
 * A CMX3600 EDL of the same cut the bridge would build in Resolve.
 * Pure and deterministic — the eval suite diffs this against a
 * golden file, which is how we verify cut order and trim points
 * without automating a GUI application.
 */
export function planToEDL(plan, fps = 24) {
  const lines = [`TITLE: ${plan.timelineName}`, "FCM: NON-DROP FRAME", ""];
  let recordAt = 0;
  let event = 0;
  for (const beat of plan.beats) {
    if (!beat.clipPath) {
      // A hole in the cut is information, not something to hide.
      lines.push(`* MISSING BEAT ${beat.index}: ${beat.description} [sf:${beat.key}]`, "");
      continue;
    }
    event += 1;
    const dur = beat.durationSeconds ?? 3;
    const srcIn = beat.startSeconds ?? 0;
    // CMX3600 reel names are 8 alphanumeric characters. `\W` would
    // keep underscores, which some conform tools reject outright.
    const reel = path.basename(beat.clipPath).replace(/[^A-Za-z0-9]/g, "").slice(0, 8).toUpperCase() || "AX";
    lines.push(
      `${String(event).padStart(3, "0")}  ${reel.padEnd(8)} V     C        ` +
      `${timecode(srcIn, fps)} ${timecode(srcIn + dur, fps)} ` +
      `${timecode(recordAt, fps)} ${timecode(recordAt + dur, fps)}`,
      `* FROM CLIP NAME: ${path.basename(beat.clipPath)}`,
      `* SCENEFLOW BEAT ${beat.index}: ${beat.description} [sf:${beat.key}]`,
    );
    if (beat.cdl) {
      const trio = v => v.map(n => Number(n).toFixed(4)).join(" ");
      lines.push(
        `*ASC_SOP (${trio(beat.cdl.slope)})(${trio(beat.cdl.offset)})(${trio(beat.cdl.power)})`,
        `*ASC_SAT ${Number(beat.cdl.saturation).toFixed(4)}`,
      );
    }
    lines.push("");
    recordAt += dur;
  }
  return lines.join("\n");
}

/** Run the Python bridge against a live Resolve. */
export function buildInResolve(plan, { python = process.env.RESOLVE_PYTHON ?? "python3", onLog } = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(python, [BRIDGE], { stdio: ["pipe", "pipe", "pipe"] });
    let out = "", err = "";
    proc.stdout.on("data", d => { out += d; });
    proc.stderr.on("data", d => { err += d; onLog?.(String(d).trimEnd()); });
    proc.on("error", e => reject(new Error(`could not start ${python}: ${e.message}`)));
    proc.on("close", () => {
      try {
        resolve(JSON.parse(out));
      } catch {
        reject(new Error(`resolve_bridge.py returned no JSON.\nstdout: ${out}\nstderr: ${err}`));
      }
    });
    proc.stdin.end(JSON.stringify(plan));
  });
}

/**
 * Build the cut. Tries Resolve; on any failure — not installed, not
 * running, scripting disabled — falls back to writing an EDL and
 * says so. A degraded result the user can still conform beats a
 * stack trace, and the caller gets `mode` so its report is honest
 * about which one happened.
 */
export async function buildTimeline(plan, { dryRun = false, outDir, onLog } = {}) {
  const writeEDL = reason => {
    const dir = outDir ?? path.resolve(HERE, "../../.state");
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `${plan.timelineName.replace(/[^\w.-]+/g, "_")}.edl`);
    fs.writeFileSync(file, planToEDL(plan));
    return {
      ok: true,
      mode: "edl",
      reason,
      edlPath: file,
      timeline: plan.timelineName,
      placed: plan.beats.filter(b => b.clipPath).map(b => ({ beat: b.index, clip: path.basename(b.clipPath) })),
      skipped: plan.beats.filter(b => !b.clipPath).map(b => ({ beat: b.index, reason: "no clip matched" })),
    };
  };

  if (dryRun) return writeEDL("dry run requested");

  try {
    const result = await buildInResolve(plan, { onLog });
    if (result?.ok) return { ...result, mode: "resolve" };
    return writeEDL(result?.error ?? "resolve_bridge reported failure");
  } catch (err) {
    return writeEDL(err.message);
  }
}
