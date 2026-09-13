// Tests for the board renderer. These assert the pipeline (SVG →
// resvg → PNG) and the geometry edge cases; whether the picture
// *looks* right is verified by eyeball via scripts/render-preview.js.

import { test } from "node:test";
import assert from "node:assert/strict";
import { next as A } from "@automerge/automerge";
import { renderBoardPNG } from "../src/render.js";
import { findPendingMentions } from "../src/assistant.js";

// 1x1 red PNG for the image-note case.
const TINY_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==",
  "base64",
);

function stroke(points, color = 0x000000ff, width = 3) {
  return {
    id: new A.RawString(crypto.randomUUID().toUpperCase()),
    color, width: new A.Float64(width),
    points: points.map(([x, y]) => ({ x: new A.Float64(x), y: new A.Float64(y), pressure: new A.Float64(0.5) })),
  };
}

function makeDoc(build) {
  let doc = A.init();
  doc = A.change(doc, d => {
    d.snapshots = [];
    d.activeSketch = { strokes: [] };
    d.texts = [];
    d.images = [];
    d.comments = [];
    d.connectors = [];
    build?.(d);
  });
  return doc;
}

test("empty board renders nothing", () => {
  const doc = makeDoc();
  assert.equal(renderBoardPNG(doc, null), null);
});

test("full board renders a PNG with sane dimensions", () => {
  const doc = makeDoc(d => {
    d.snapshots.push({
      id: new A.RawString("33333333-CCCC-4CCC-8CCC-333333333333"),
      x: new A.Float64(0), y: new A.Float64(0), z: 1,
      width: new A.Float64(800), height: new A.Float64(600),
      strokes: [stroke([[100, 100], [300, 200], [500, 150]])],
    });
    d.snapshots.push({
      id: new A.RawString("44444444-DDDD-4DDD-8DDD-444444444444"),
      x: new A.Float64(1000), y: new A.Float64(0), z: 2,
      width: new A.Float64(800), height: new A.Float64(600),
      strokes: [stroke([[400, 300]])], // single-point stroke (a tap)
    });
    d.connectors.push({
      id: new A.RawString("55555555-EEEE-4EEE-8EEE-555555555555"),
      from: new A.RawString("33333333-CCCC-4CCC-8CCC-333333333333"),
      to: new A.RawString("44444444-DDDD-4DDD-8DDD-444444444444"),
    });
    d.texts.push({
      id: new A.RawString("66666666-FFFF-4FFF-8FFF-666666666666"),
      x: new A.Float64(0), y: new A.Float64(400), z: 1,
      text: new A.RawString("WIDE <alley> & \"entrance\""), // XML-escaping case
      fontSize: new A.Float64(24), color: 0xcc0000ff,
    });
    d.images.push({
      id: new A.RawString("77777777-AAAA-4AAA-8AAA-777777777777"),
      x: new A.Float64(500), y: new A.Float64(500), z: 1,
      width: new A.Float64(100), height: new A.Float64(100),
      data: new Uint8Array(TINY_PNG), format: new A.RawString("png"),
    });
    d.activeSketch.strokes.push(stroke([[10, 10], [790, 590]], 0x0000ffff));
    d.comments.push({
      id: new A.RawString("11111111-AAAA-4AAA-8AAA-111111111111"),
      x: new A.Float64(450), y: new A.Float64(-100), z: 3,
      authorPeerId: new A.RawString("p"), authorName: new A.RawString("Maya"),
      text: new A.RawString("@assistant does this cut work?"),
      createdAt: new Date(), isResolved: false,
    });
  });

  const [mention] = findPendingMentions(doc);
  const rendered = renderBoardPNG(doc, mention);

  assert.ok(rendered, "should render");
  // PNG magic bytes.
  assert.deepEqual([...rendered.png.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
  // Long edge capped at 1568 (the field spans ~1848pt wide + padding).
  assert.ok(rendered.width <= 1568, `width ${rendered.width}`);
  assert.ok(rendered.height > 0);
  // Big enough that content actually rasterized (a blank canvas
  // compresses to almost nothing).
  assert.ok(rendered.png.length > 5_000, `png only ${rendered.png.length} bytes`);
});

test("board with only active-sketch strokes still renders", () => {
  const doc = makeDoc(d => {
    d.activeSketch.strokes.push(stroke([[0, 0], [100, 100]]));
  });
  const rendered = renderBoardPNG(doc, null);
  assert.ok(rendered);
  assert.ok(rendered.width > 0 && rendered.height > 0);
});
