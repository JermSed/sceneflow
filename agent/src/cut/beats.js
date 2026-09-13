// beats.js — the board, read as a shot list.
//
// Pure and Automerge-free (it takes the plain values schema.js
// produces), so the whole ordering story is unit-testable without a
// relay, a wasm runtime, or any of the three external apps.
//
// A Sceneflow board is spatial, not linear, so "what order do these
// shots go in?" is a real inference, not a field lookup. Two signals,
// in priority order:
//
//   1. CONNECTORS. An arrow from frame A to frame B is the author
//      explicitly saying B follows A. Arrows form a DAG; we take a
//      topological order of it. This is the strong signal.
//   2. POSITION. Frames the author never wired up fall back to
//      reading order — left to right, then top to bottom, with a row
//      tolerance so a frame nudged 30pt down still counts as "same
//      row" rather than jumping a line.
//
// Frames touched by connectors keep their graph order and are placed
// at the position of their earliest member; unwired frames slot in by
// position. That way a half-wired board (the common case — you draw
// arrows for the tricky bits only) degrades gracefully instead of
// discarding either signal.

import { str } from "../schema.js";

/** Frames within this many points of each other vertically are
 * treated as the same row when falling back to reading order. */
const ROW_TOLERANCE = 200;

/** A text note this close to a frame's box is treated as that frame's
 * label (the slug line / shot description the author scribbled next
 * to the sketch) rather than a free-floating note. */
const LABEL_RADIUS = 260;

/** Stable, short key for a frame. It goes into Todoist task text and
 * Resolve markers so a second run can recognize its own prior output
 * in apps that have no idea what Sceneflow is. Derived from the frame
 * UUID, so it survives reordering, re-runs, and offline merges.
 *
 * It HASHES rather than slices. An 8-character prefix looks fine
 * against random v4 UUIDs and collides immediately against the
 * structured ones that show up in fixtures, imports, and anything
 * seeded from a counter — and two frames sharing a key means the
 * second one silently never reaches the shoot list. FNV-1a over the
 * whole id: cheap, dependency-free, and stable across runtimes. */
export function frameKey(id) {
  const s = str(id).toUpperCase();
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  // Fold the length in so same-character-set ids of different
  // lengths cannot land on the same value.
  h = Math.imul(h ^ s.length, 0x01000193) >>> 0;
  return h.toString(16).toUpperCase().padStart(8, "0");
}

function centerOf(el) {
  return { x: Number(el.x) || 0, y: Number(el.y) || 0 };
}

/** Text notes and comments that sit close enough to a frame to be
 * describing it. Notes are the author's words for the shot — the
 * single most useful thing we can hand the matcher. */
function labelsFor(frame, texts) {
  const c = centerOf(frame);
  const halfW = (Number(frame.width) || 800) / 2;
  const halfH = (Number(frame.height) || 600) / 2;
  return texts
    .map(t => {
      const p = centerOf(t);
      // Distance to the frame's box, not its center: a note tucked
      // under a big frame is close to the box and far from the middle.
      const dx = Math.max(0, Math.abs(p.x - c.x) - halfW);
      const dy = Math.max(0, Math.abs(p.y - c.y) - halfH);
      return { text: str(t.text).trim(), distance: Math.hypot(dx, dy) };
    })
    .filter(t => t.text.length > 0 && t.distance <= LABEL_RADIUS)
    .sort((a, b) => a.distance - b.distance);
}

/** Kahn's algorithm over the connector graph. Returns null if the
 * arrows contain a cycle — boards are hand-drawn and a cycle is a
 * perfectly reasonable thing to sketch (a loop, a flashback), it
 * just means "sequence" is undefined and we should fall back to
 * position rather than invent an order. */
function topoOrder(ids, edges) {
  const indegree = new Map(ids.map(id => [id, 0]));
  const out = new Map(ids.map(id => [id, []]));
  for (const [from, to] of edges) {
    if (!indegree.has(from) || !indegree.has(to)) continue;
    out.get(from).push(to);
    indegree.set(to, indegree.get(to) + 1);
  }
  // Seed in the caller's order so ties break deterministically
  // (position order), not by Map iteration accident.
  const queue = ids.filter(id => indegree.get(id) === 0);
  const order = [];
  while (queue.length > 0) {
    const id = queue.shift();
    order.push(id);
    for (const next of out.get(id)) {
      indegree.set(next, indegree.get(next) - 1);
      if (indegree.get(next) === 0) queue.push(next);
    }
  }
  return order.length === ids.length ? order : null;
}

/** Reading order: left to right, wrapping into rows. */
function positionOrder(frames) {
  const rows = [];
  for (const f of [...frames].sort((a, b) => centerOf(a).y - centerOf(b).y)) {
    const y = centerOf(f).y;
    const row = rows.find(r => Math.abs(r.y - y) <= ROW_TOLERANCE);
    if (row) row.items.push(f);
    else rows.push({ y, items: [f] });
  }
  return rows.flatMap(r => r.items.sort((a, b) => centerOf(a).x - centerOf(b).x));
}

/**
 * The board as an ordered list of beats.
 *
 * @returns {Array<{index:number, id:string, key:string, x:number, y:number,
 *   width:number, height:number, strokeCount:number, labels:string[],
 *   description:string, orderedBy:"connectors"|"position"}>}
 */
export function boardToBeats(doc) {
  const frames = Array.from(doc?.snapshots ?? []).map(s => ({
    id: str(s.id).toUpperCase(),
    x: Number(s.x) || 0,
    y: Number(s.y) || 0,
    width: Number(s.width) || 800,
    height: Number(s.height) || 600,
    strokeCount: Array.from(s.strokes ?? []).length,
  }));
  if (frames.length === 0) return [];

  const texts = Array.from(doc?.texts ?? []).map(t => ({
    x: Number(t.x) || 0,
    y: Number(t.y) || 0,
    text: str(t.text),
  }));

  const byId = new Map(frames.map(f => [f.id, f]));
  const edges = Array.from(doc?.connectors ?? [])
    .map(c => [str(c.from).toUpperCase(), str(c.to).toUpperCase()])
    .filter(([from, to]) => byId.has(from) && byId.has(to));

  const positional = positionOrder(frames);
  let ordered = positional;
  let orderedBy = "position";

  if (edges.length > 0) {
    const topo = topoOrder(positional.map(f => f.id), edges);
    if (topo) {
      ordered = topo.map(id => byId.get(id));
      orderedBy = "connectors";
    }
  }

  return ordered.map((f, i) => {
    const labels = labelsFor(f, texts).map(l => l.text);
    return {
      index: i + 1,
      id: f.id,
      key: frameKey(f.id),
      x: f.x,
      y: f.y,
      width: f.width,
      height: f.height,
      strokeCount: f.strokeCount,
      labels,
      // What a human would call this shot. Falls back to the frame
      // number when the author drew but never wrote — plenty of
      // storyboards are wordless.
      description: labels[0] || `Frame ${i + 1} (unlabeled sketch)`,
      orderedBy,
    };
  });
}
