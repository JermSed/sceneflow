// The two connectors with logic worth testing offline: the EDL
// conform (exact, golden-file comparable) and the Todoist client's
// version probing, retry, and dedupe (mocked at the fetch boundary,
// so it exercises the real request-building code).
import { test } from "node:test";
import assert from "node:assert/strict";
import { planToEDL, timecode } from "../src/apps/resolve.js";
import { Todoist, taskMarker } from "../src/apps/todoist.js";

test("timecode converts seconds to frames at the timeline rate", () => {
  assert.equal(timecode(0), "00:00:00:00");
  assert.equal(timecode(1.5, 24), "00:00:01:12");
  assert.equal(timecode(3661.25, 24), "01:01:01:06");
  assert.equal(timecode(-5), "00:00:00:00", "negative seconds clamp rather than emit garbage");
});

test("the EDL is a valid conform of the plan, holes included", () => {
  const plan = {
    timelineName: "Rooftop — Sceneflow Cut",
    beats: [
      { index: 1, key: "AB12CD34", description: "WIDE rooftop", clipPath: "/m/rooftop_wide.mov",
        startSeconds: 2, durationSeconds: 4,
        cdl: { slope: [0.9, 0.95, 1.1], offset: [0, 0, 0.01], power: [1, 1, 0.98], saturation: 0.85 } },
      { index: 2, key: "EE55FF66", description: "INSERT letter", clipPath: null },
      { index: 3, key: "AA11BB22", description: "CU Ray", clipPath: "/m/ray_cu.mov",
        startSeconds: 0, durationSeconds: 2.5 },
    ],
  };
  const edl = planToEDL(plan);

  assert.match(edl, /^TITLE: Rooftop — Sceneflow Cut/);
  // Events are numbered over placed clips only, and record times are
  // contiguous — beat 3 starts where beat 1 ended, because beat 2 has
  // no footage to occupy the timeline.
  assert.match(edl, /001\s+ROOFTOPW\s+V\s+C\s+00:00:02:00 00:00:06:00 00:00:00:00 00:00:04:00/);
  assert.match(edl, /002\s+RAYCUMOV\s+V\s+C\s+00:00:00:00 00:00:02:12 00:00:04:00 00:00:06:12/);
  // The hole is recorded as a comment, not silently dropped.
  assert.match(edl, /\* MISSING BEAT 2: INSERT letter \[sf:EE55FF66\]/);
  // The grade travels with the cut in standard ASC form.
  assert.match(edl, /\*ASC_SOP \(0\.9000 0\.9500 1\.1000\)\(0\.0000 0\.0000 0\.0100\)\(1\.0000 1\.0000 0\.9800\)/);
  assert.match(edl, /\*ASC_SAT 0\.8500/);
});

/** Swap global fetch for a scripted responder. */
function mockFetch(handler) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method ?? "GET" });
    return handler(String(url), init, calls.length);
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

test("the client probes the unified v1 API first and remembers the answer", async () => {
  const m = mockFetch(url => url.includes("/api/v1/projects") ? json({ results: [], next_cursor: null }) : json({}, 404));
  try {
    const t = new Todoist("token");
    await t.ensureProject("Shoot List");
    await t.ensureProject("Shoot List");
    assert.ok(m.calls.every(c => c.url.includes("/api/v1/")));
    assert.equal(m.calls.filter(c => c.method === "POST").length, 2, "probing did not add extra writes");
  } finally { m.restore(); }
});

test("it falls back to REST v2 when v1 is gone, and normalizes the bare-array response", async () => {
  const m = mockFetch(url => {
    if (url.includes("/api/v1/")) return json({}, 404);
    if (url.includes("/rest/v2/projects")) return json([{ id: "p1", name: "Shoot List" }]);
    return json({}, 404);
  });
  try {
    const project = await new Todoist("token").ensureProject("Shoot List");
    assert.equal(project.id, "p1", "found the existing project rather than creating a second one");
  } finally { m.restore(); }
});

test("a 429 is retried with backoff rather than dropped", async () => {
  let hits = 0;
  const m = mockFetch(url => {
    if (url.endsWith("/api/v1/projects") && hits === 0) { hits++; return json({ results: [] }); }
    if (url.includes("/tasks")) {
      hits++;
      if (hits < 4) return new Response("slow down", { status: 429, headers: { "retry-after": "0" } });
      return json([{ id: "t1", content: "Shoot: x [sf:ABCD1234]" }]);
    }
    return json({ results: [] });
  });
  try {
    const tasks = await new Todoist("token").openTasks("p1");
    assert.equal(tasks.length, 1);
    assert.ok(hits >= 4, "it actually retried");
  } finally { m.restore(); }
});

test("a bad token fails loudly instead of falling back to v2 and failing confusingly", async () => {
  const m = mockFetch(() => json({ error: "unauthorized" }, 401));
  try {
    await assert.rejects(() => new Todoist("bad").ensureProject("x"), /401|token/i);
  } finally { m.restore(); }
});

test("ensureShotTask writes once and recognizes its own marker on a second pass", async () => {
  const created = [];
  const m = mockFetch((url, init) => {
    if (url.endsWith("/api/v1/projects")) return json({ results: [] });
    if (url.includes("/tasks") && init.method === "POST") {
      const body = JSON.parse(init.body);
      created.push(body.content);
      return json({ id: `t${created.length}`, content: body.content });
    }
    return json({ results: [] });
  });
  try {
    const t = new Todoist("token");
    const existing = [];
    const beat = { frameKey: "ABCD1234", title: "Shoot: DRONE pull back", description: "d" };
    const first = await t.ensureShotTask("p1", existing, beat);
    const second = await t.ensureShotTask("p1", existing, beat);
    assert.equal(first.created, true);
    assert.equal(second.created, false);
    assert.equal(created.length, 1, "only one task hit the API");
    assert.ok(created[0].includes(taskMarker("ABCD1234")));
  } finally { m.restore(); }
});
