// Ordering and labeling: how a spatial board becomes a shot list.
import { test } from "node:test";
import assert from "node:assert/strict";
import { boardToBeats, frameKey } from "../src/cut/beats.js";
import { FIXTURES } from "../eval/fixtures/boards.js";

const fixture = name => FIXTURES.find(f => f.name === name);

test("reading order: left to right, then wrapping into rows", () => {
  const beats = boardToBeats(fixture("gaps").doc);
  assert.equal(beats.length, 6);
  assert.deepEqual(beats.map(b => b.description.slice(0, 6)),
    ["WIDE -", "OTS - ", "INSERT", "CLOSE ", "DRONE ", "WIDE -"]);
  assert.equal(beats[0].orderedBy, "position");
});

test("connectors override position", () => {
  const f = fixture("wired");
  const beats = boardToBeats(f.doc);
  assert.deepEqual(beats.map(b => b.id), f.expectedOrder);
  assert.equal(beats[0].orderedBy, "connectors");
  // Sanity: position order would have been different.
  assert.notDeepEqual(beats.map(b => b.x), [...beats.map(b => b.x)].sort((a, b) => a - b));
});

test("a cycle in the arrows falls back to reading order instead of hanging", () => {
  const f = fixture("cycle");
  const beats = boardToBeats(f.doc);
  assert.deepEqual(beats.map(b => b.id), f.expectedOrder);
  assert.equal(beats[0].orderedBy, "position");
});

test("a nearby text note becomes the beat's description; a distant one does not", () => {
  const doc = {
    snapshots: [{ id: "AAAA", x: 0, y: 0, width: 800, height: 600, strokes: [] }],
    texts: [
      { x: 0, y: 340, text: "WIDE - alley" },      // just under the frame
      { x: 6000, y: 6000, text: "unrelated note" }, // far away
    ],
    connectors: [],
  };
  const [beat] = boardToBeats(doc);
  assert.equal(beat.description, "WIDE - alley");
  assert.deepEqual(beat.labels, ["WIDE - alley"]);
});

test("an unlabeled frame still gets a usable description", () => {
  const doc = { snapshots: [{ id: "BBBB", x: 0, y: 0, strokes: [] }], texts: [], connectors: [] };
  assert.equal(boardToBeats(doc)[0].description, "Frame 1 (unlabeled sketch)");
});

test("frame keys are stable, case-insensitive, and do not collide on structured UUIDs", () => {
  const uuid = "3F2A1B4C-5D6E-4F70-8A9B-0C1D2E3F4A5B";
  assert.equal(frameKey(uuid), frameKey(uuid), "stable");
  assert.equal(frameKey(uuid.toLowerCase()), frameKey(uuid), "case-insensitive");
  assert.match(frameKey(uuid), /^[0-9A-F]{8}$/);

  // The regression that matters: ids differing only in their last
  // characters must not share a key, or the second beat never
  // reaches the shoot list.
  const sequential = Array.from({ length: 500 }, (_, i) =>
    frameKey(`00000000-0000-4000-8000-${String(i).padStart(12, "0")}`));
  assert.equal(new Set(sequential).size, sequential.length, "no collisions across 500 sequential ids");
});

test("an empty board yields no beats rather than throwing", () => {
  assert.deepEqual(boardToBeats({}), []);
  assert.deepEqual(boardToBeats(null), []);
});
