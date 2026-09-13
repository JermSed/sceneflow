// End-to-end orchestration across all three apps, with the apps
// faked. This is the test that says the AGENT works — ordering,
// routing matched beats to Resolve and unmatched beats to Todoist,
// surviving each app failing in turn, and staying idempotent when
// the same board is cut twice.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runCut, reportToComment } from "../src/cut/run.js";
import { FIXTURES } from "../eval/fixtures/boards.js";
import { fakeDrive, fakeResolve, fakeTodoistFactory, scriptedMatcher } from "./fakes.js";

const gaps = FIXTURES.find(f => f.name === "gaps");
const quiet = () => {};

function harness(overrides = {}) {
  const drive = overrides.drive ?? fakeDrive({ clips: gaps.clips });
  const buildTimeline = overrides.buildTimeline ?? fakeResolve();
  const Todoist = overrides.Todoist ?? fakeTodoistFactory();
  return {
    drive, buildTimeline, Todoist,
    run: (extra = {}) => runCut(gaps.doc, {
      docId: "test-board", boardName: "Rooftop",
      apps: { drive, buildTimeline, Todoist },
      matcher: scriptedMatcher({ 1: gaps.clips[0].id, 2: gaps.clips[1].id }),
      onLog: quiet,
      ...extra,
    }),
  };
}

test("matched beats go to Resolve, unmatched beats go to Todoist, and the counts agree", async () => {
  const h = harness();
  const report = await h.run();

  assert.equal(report.ok, true, report.problems.join("; "));
  assert.equal(report.beatCount, 6);
  assert.equal(report.matchedCount, 2);
  assert.equal(report.missingCount, 4);

  // Resolve got all six beats, two with footage and four as holes.
  const plan = h.buildTimeline.calls[0];
  assert.equal(plan.beats.length, 6);
  assert.equal(plan.beats.filter(b => b.clipPath).length, 2);
  assert.equal(report.resolve.markers.length, 4);

  // Todoist got exactly the four that Resolve could not fill.
  assert.equal(report.todoist.created, 4);
  const filed = h.Todoist.state.tasks.map(t => t.content);
  assert.equal(filed.length, 4);
  assert.ok(filed.every(c => /\[sf:[0-9A-F]{8}\]/.test(c)), "every task carries a stable frame key");
  assert.ok(filed.some(c => c.includes("DRONE")), "the beat's own words reach the task");

  // Only clips that made the cut were downloaded — the other four
  // beats cost no bandwidth.
  assert.equal(h.drive.downloaded.length, 2);
});

test("cutting the same board twice files no duplicate tasks", async () => {
  const Todoist = fakeTodoistFactory();
  const first = await harness({ Todoist }).run();
  const second = await harness({ Todoist }).run();

  assert.equal(first.todoist.created, 4);
  assert.equal(second.todoist.created, 0);
  assert.equal(second.todoist.existing, 4);
  assert.equal(Todoist.state.tasks.length, 4, "the shoot list did not grow on a re-run");
  assert.equal(Todoist.state.projects.length, 1, "no second project was created");
});

test("Todoist being down still yields a graded timeline", async () => {
  const report = await harness({ Todoist: fakeTodoistFactory({ failOn: "ensureProject" }) }).run();
  assert.equal(report.ok, false);
  assert.equal(report.resolve.mode, "resolve");
  assert.equal(report.resolve.placed.length, 2);
  assert.match(report.problems.join(" "), /401/);
  assert.match(reportToComment(report), /Problems:/);
});

test("Resolve being unavailable degrades to an EDL and says so", async () => {
  const report = await harness({ buildTimeline: fakeResolve({ fail: true }) }).run();
  assert.equal(report.resolve.mode, "edl");
  assert.equal(report.todoist.created, 4, "the shoot list is filed regardless");
  assert.match(reportToComment(report), /Resolve unavailable/);
});

test("Drive being unreachable stops the run cleanly instead of cutting nothing into a timeline", async () => {
  const report = await harness({ drive: fakeDrive({ failOn: "listFootage" }) }).run();
  assert.equal(report.clipCount, 0);
  assert.match(report.problems.join(" "), /429/);
  // With no catalog, every beat is unshot — which is the correct
  // answer, and the whole board lands on the shoot list.
  assert.equal(report.missingCount, 6);
});

test("a board with no frames reports why instead of building an empty timeline", async () => {
  const h = harness();
  const report = await runCut({ snapshots: [], texts: [], connectors: [] }, {
    docId: "empty", apps: { drive: h.drive, buildTimeline: h.buildTimeline, Todoist: h.Todoist },
    matcher: scriptedMatcher({}), onLog: quiet,
  });
  assert.equal(report.beatCount, 0);
  assert.match(report.problems.join(" "), /no captured frames/);
  assert.equal(h.buildTimeline.calls.length, 0, "Resolve was never touched");
});

test("the board comment stays short enough to be a pinned comment", async () => {
  const report = await harness().run();
  const comment = reportToComment(report);
  assert.ok(comment.length <= 900, `comment was ${comment.length} chars`);
  assert.ok(!comment.includes("**"), "no markdown — Sceneflow comments render plain");
});
