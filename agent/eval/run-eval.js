#!/usr/bin/env node
// eval/run-eval.js — the offline evaluation.
//
//   npm run eval                 # model matcher, 3 runs per fixture
//   npm run eval -- --runs 5     # more runs; variance is the point
//   npm run eval -- --baseline   # deterministic filename matcher
//
// Runs the matcher repeatedly over golden storyboards with known
// answers and reports precision, recall, decline accuracy, and the
// run-to-run spread. The baseline mode needs no API key and no
// network, so `npm run eval -- --baseline` is a one-command proof
// that the pipeline works on a fresh clone.
//
// Every run is also checked against structural invariants. Those are
// pass/fail, not scored: a single violation means the agent could
// have produced a corrupt timeline, and that is a bug regardless of
// how good the matching was.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MATCHABLE } from "./fixtures/boards.js";
import { boardToBeats } from "../src/cut/beats.js";
import { matchBeatsToClips, filenameBaseline, reconcile, MATCH_THRESHOLD } from "../src/cut/match.js";
import { score, checkInvariants, mean, stdev, pct } from "./harness.js";

const args = process.argv.slice(2);
const runs = Number(args[args.indexOf("--runs") + 1]) || (args.includes("--baseline") ? 1 : 3);
const baseline = args.includes("--baseline");
if (baseline) process.env.SCENEFLOW_CANNED = "1";

const HERE = path.dirname(fileURLToPath(import.meta.url));

console.log(
  `\nSceneflow cut agent — offline evaluation\n` +
  `matcher: ${baseline ? "filename baseline (deterministic)" : process.env.SCENEFLOW_MODEL ?? "claude-opus-4-8"}   ` +
  `runs per fixture: ${runs}   confidence threshold: ${MATCH_THRESHOLD}\n`,
);

const results = [];
let invariantViolations = 0;

for (const fixture of MATCHABLE) {
  const beats = boardToBeats(fixture.doc).map(b => ({
    ...b,
    strokes: fixture.doc.snapshots.find(s => s.id === b.id)?.strokes ?? [],
  }));
  const perRun = [];

  for (let i = 0; i < runs; i++) {
    const cut = baseline
      ? reconcile(beats, fixture.clips, filenameBaseline(beats, fixture.clips))
      : await matchBeatsToClips(beats, fixture.clips, { onLog: () => {} });

    const violations = checkInvariants(beats, fixture.clips, cut);
    if (violations.length) {
      invariantViolations += violations.length;
      for (const v of violations) console.log(`  INVARIANT VIOLATED  ${fixture.name} run ${i + 1}: ${v}`);
    }
    perRun.push(score(cut.assignments, fixture.truth));
  }

  const agg = {
    fixture: fixture.name,
    hard: !!fixture.hard,
    beats: beats.length,
    clips: fixture.clips.length,
    precision: mean(perRun.map(r => r.precision)),
    recall: mean(perRun.map(r => r.recall)),
    declineAccuracy: mean(perRun.map(r => r.declineAccuracy)),
    exactRate: mean(perRun.map(r => (r.exact ? 1 : 0))),
    falseFills: mean(perRun.map(r => r.falseFill)),
    wrongMatches: mean(perRun.map(r => r.wrongMatch)),
    misses: mean(perRun.map(r => r.miss)),
    // Run-to-run spread on the metric a user feels. Non-zero here
    // means the same board can produce different cuts, which is
    // worth knowing before you demo it.
    exactStdev: stdev(perRun.map(r => (r.exact ? 1 : 0))),
    runs: perRun,
  };
  results.push(agg);
}

const head = ["fixture", "beats", "clips", "precis", "recall", "decline", "exact", "±", "falseFill"];
const widths = [12, 6, 6, 7, 7, 8, 7, 6, 10];
const row = cells => cells.map((c, i) => String(c).padStart(widths[i])).join("");
console.log(row(head));
console.log("-".repeat(widths.reduce((a, b) => a + b, 0)));
for (const r of results) {
  console.log(row([
    r.fixture + (r.hard ? "*" : ""), r.beats, r.clips,
    pct(r.precision), pct(r.recall), pct(r.declineAccuracy), pct(r.exactRate),
    r.exactStdev.toFixed(2), r.falseFills.toFixed(1),
  ]));
}
console.log("-".repeat(widths.reduce((a, b) => a + b, 0)));
console.log(row([
  "OVERALL", "", "",
  pct(mean(results.map(r => r.precision))),
  pct(mean(results.map(r => r.recall))),
  pct(mean(results.map(r => r.declineAccuracy))),
  pct(mean(results.map(r => r.exactRate))),
  "", mean(results.map(r => r.falseFills)).toFixed(1),
]));
console.log(`\n* "carddump" is the adversarial fixture: camera-original filenames, so only the image and duration carry signal.`);
console.log(`Structural invariant violations: ${invariantViolations}${invariantViolations === 0 ? "  (none — no run could have produced a corrupt timeline)" : "  <-- BUG"}`);

const out = path.join(HERE, "results", baseline ? "baseline.json" : "latest.json");
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify({
  matcher: baseline ? "filename-baseline" : process.env.SCENEFLOW_MODEL ?? "claude-opus-4-8",
  threshold: MATCH_THRESHOLD, runs, ranAt: new Date().toISOString(),
  invariantViolations, results,
}, null, 2));
console.log(`Wrote ${path.relative(process.cwd(), out)}\n`);

process.exit(invariantViolations === 0 ? 0 : 1);
