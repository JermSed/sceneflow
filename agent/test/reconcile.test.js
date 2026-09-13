// The repair layer: what happens when the model returns nonsense.
//
// A structured-output schema constrains shape, not sense. These are
// the cases that would otherwise reach Resolve and Todoist.
import { test } from "node:test";
import assert from "node:assert/strict";
import { reconcile, filenameBaseline, MATCH_THRESHOLD } from "../src/cut/match.js";

const beats = [1, 2, 3].map(i => ({
  index: i, key: `KEY${i}`, description: `beat ${i}`, labels: [`beat ${i}`],
  width: 800, height: 600, strokeCount: 2, orderedBy: "position",
}));
const clips = [
  { id: "c1", name: "one_wide.mov", durationSeconds: 8 },
  { id: "c2", name: "two_close.mov", durationSeconds: 3 },
];
const cdl = { slope: [1, 1, 1], offset: [0, 0, 0], power: [1, 1, 1], saturation: 1 };
const ok = (beat, clipId, confidence = 0.9) => ({ beat, clipId, confidence, reason: "r", look: "l", cdl });

test("a clean response passes through unchanged", () => {
  const r = reconcile(beats, clips, { assignments: [ok(1, "c1"), ok(2, "c2"), ok(3, null)], sequenceNotes: "n" });
  assert.deepEqual(r.assignments.map(a => a.clipId), ["c1", "c2", null]);
  assert.deepEqual(r.warnings, []);
});

test("one clip claimed by two beats: the confident beat keeps it, the other becomes unshot", () => {
  const r = reconcile(beats, clips, { assignments: [ok(1, "c1", 0.7), ok(2, "c1", 0.95), ok(3, null)] });
  assert.deepEqual(r.assignments.map(a => a.clipId), [null, "c1", null]);
  assert.match(r.warnings.join(" "), /already used by beat 2/);
});

test("a hallucinated clip id is dropped, not sent to Resolve", () => {
  const r = reconcile(beats, clips, { assignments: [ok(1, "does-not-exist"), ok(2, null), ok(3, null)] });
  assert.equal(r.assignments[0].clipId, null);
  assert.match(r.warnings.join(" "), /not in the catalog/);
});

test("low confidence is downgraded to unshot by code, not by the model's restraint", () => {
  const under = MATCH_THRESHOLD - 0.1;
  const r = reconcile(beats, clips, { assignments: [ok(1, "c1", under), ok(2, null), ok(3, null)] });
  assert.equal(r.assignments[0].clipId, null);
  assert.match(r.warnings.join(" "), /below/);
});

test("a beat the model forgot is filled in as unshot, so it still reaches the shoot list", () => {
  const r = reconcile(beats, clips, { assignments: [ok(1, "c1")] });
  assert.equal(r.assignments.length, 3);
  assert.deepEqual(r.assignments.map(a => a.index), [1, 2, 3]);
  assert.match(r.warnings.join(" "), /returned no assignment/);
});

test("an assignment for a beat that does not exist is discarded", () => {
  const r = reconcile(beats, clips, { assignments: [ok(99, "c1"), ok(1, "c2"), ok(2, null), ok(3, null)] });
  assert.equal(r.assignments.length, 3);
  assert.match(r.warnings.join(" "), /unknown beat 99/);
});

test("a wild grade is clamped into a range that cannot wreck an image", () => {
  const wild = { slope: [99, -99, 0], offset: [5, 5, 5], power: [0, 0, 0], saturation: 40 };
  const r = reconcile(beats, clips, { assignments: [{ ...ok(1, "c1"), cdl: wild }] });
  const g = r.assignments[0].cdl;
  assert.deepEqual(g.slope, [2, 0.5, 0.5]);
  assert.deepEqual(g.offset, [0.2, 0.2, 0.2]);
  assert.equal(g.saturation, 2);
});

test("a malformed grade falls back to neutral rather than to NaN", () => {
  const r = reconcile(beats, clips, { assignments: [{ ...ok(1, "c1"), cdl: { slope: "bright", saturation: null } }] });
  assert.deepEqual(r.assignments[0].cdl, { slope: [1, 1, 1], offset: [0, 0, 0], power: [1, 1, 1], saturation: 1 });
});

test("garbage in, valid cut out — every beat still accounted for", () => {
  for (const junk of [null, {}, { assignments: null }, { assignments: [{}] }, { assignments: "no" }]) {
    const r = reconcile(beats, clips, junk);
    assert.equal(r.assignments.length, 3, `failed for ${JSON.stringify(junk)}`);
    assert.ok(r.assignments.every(a => a.cdl && Number.isFinite(a.cdl.saturation)));
  }
});

test("the filename baseline never assigns one clip twice", () => {
  const twins = [{ id: "x1", name: "wide_alley.mov" }, { id: "x2", name: "wide_alley_alt.mov" }];
  const both = [
    { ...beats[0], labels: ["WIDE alley"], description: "WIDE alley" },
    { ...beats[1], labels: ["WIDE alley"], description: "WIDE alley" },
  ];
  const r = reconcile(both, twins, filenameBaseline(both, twins));
  const used = r.assignments.map(a => a.clipId).filter(Boolean);
  assert.equal(new Set(used).size, used.length);
});
