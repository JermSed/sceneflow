// sketch-shapes.js — crude storyboard compositions, generated.
//
// Split out from the seeding CLI for one reason: the CLI opens a
// WebSocket the moment it is imported, so nothing that lives inside
// it can be rendered, eyeballed, or unit-tested. These are the shapes
// only, pure and importable.
//
// The shot size in a slug line picks the composition. Crude is the
// point — a storyboard is crude — but a WIDE must read as a small
// figure in a big space and a CLOSE UP as one subject filling the
// frame, because the matcher is shown each frame as a picture and
// those are the cues it has to work with.

import { next as A } from "@automerge/automerge";
import { randomUUID } from "node:crypto";

export const uuid = () => new A.RawString(randomUUID().toUpperCase());
export const f64 = n => new A.Float64(n);

/** Wrap a plain stroke list into the scalar types the Swift decoder
 * expects (see src/schema.js). Kept separate from `sketch()` so the
 * shapes stay plain numbers: an A.Float64 only becomes a number once
 * it has been through an Automerge document, so a wrapped stroke
 * renders as an empty frame everywhere else — including in a preview
 * meant to check the shapes are right. Ask me how I know. */
export function toDocStrokes(strokes) {
  return strokes.map(s => ({
    id: uuid(),
    color: s.color,
    width: s.width,
    points: s.points.map(p => ({ x: f64(p.x), y: f64(p.y), pressure: f64(p.pressure) })),
  }));
}

/** Sketch a frame that actually reads as the shot it describes.
 *
 * The generic version of this drew the same four scribbles eight
 * times, which is useless twice over: on camera the board looks
 * fake, and the matcher — which is shown each frame as a picture —
 * gets no visual signal at all and falls back to reading the slug
 * line, defeating the point of the vision step.
 *
 * So the shot size in the slug line picks the composition. These are
 * crude on purpose; a storyboard is crude. What matters is that a
 * WIDE reads as a small figure in a big space and a CLOSE UP reads
 * as one subject filling the frame — the same cues a human uses to
 * tell them apart at a glance.
 */
export function sketch(text, seed) {
  const W = 800, H = 600;
  const jitter = k => ((seed * 37 + k * 53) % 40) - 20;
  const stroke = (points, width = 4) => ({
    color: 0x1a1a1aff, width,
    points: points.map(([x, y]) => ({ x, y, pressure: 0.7 })),
  });
  // A head-and-shoulders figure, sized and placed to taste.
  const figure = (cx, cy, scale) => {
    const r = 34 * scale;
    const circle = [];
    for (let a = 0; a <= 360; a += 24) {
      const rad = (a * Math.PI) / 180;
      circle.push([cx + r * Math.cos(rad), cy - r * Math.sin(rad)]);
    }
    const shoulderY = Math.min(H - 10, cy + r * 3.2);
    return [
      stroke(circle, 3),
      stroke([[cx - r * 1.5, shoulderY], [cx - r * 1.1, cy + r * 0.9],
              [cx + r * 1.1, cy + r * 0.9], [cx + r * 1.5, shoulderY]], 3),
    ];
  };
  const box = (x1, y1, x2, y2) =>
    stroke([[x1, y1], [x2, y1], [x2, y2], [x1, y2], [x1, y1]], 3);

  const t = String(text).toLowerCase();
  const is = (...keys) => keys.some(k => t.includes(k));

  // A horizon says "there is a space behind this subject", which is
  // exactly what a close-up or an insert is NOT saying — on those it
  // just draws a line through the subject's face. Tight shots get no
  // horizon at all.
  const tight = is("close up", "close-up", "cu ", " cu", "closeup",
                   "insert", "detail", "note", "letter", "object");
  const horizonY = is("wide", "establishing", "drone", "aerial") ? 300 : 380;
  const parts = tight
    ? []
    : [stroke([[40, horizonY + jitter(1)], [W - 40, horizonY + jitter(2)]], 3)];

  if (is("insert", "detail", "note", "letter", "object")) {
    // One object, centred, nothing else competing with it.
    parts.push(box(280 + jitter(3), 210, 520 + jitter(4), 400));
    parts.push(stroke([[320, 260], [470, 260]], 3));
    parts.push(stroke([[320, 300], [440, 300]], 3));
    parts.push(stroke([[320, 340], [460, 340]], 3));
  } else if (is("close up", "close-up", "cu ", " cu", "closeup")) {
    // Subject fills the frame: head high, shoulders running off the
    // bottom edge, nothing else in shot.
    parts.push(...figure(W / 2 + jitter(5), 230, 2.4));
  } else if (is("ots", "over the shoulder", "over-the-shoulder")) {
    // Near shoulder blocking one side, subject beyond it.
    parts.push(stroke([[80, H], [140, 330], [300, 300], [330, H]], 4));
    parts.push(...figure(540 + jitter(6), 270, 1.5));
  } else if (is("medium", " ms", "mid")) {
    parts.push(...figure(W / 2 + jitter(7), 280, 1.7));
  } else if (is("drone", "aerial", "pull back")) {
    // Looking down: rooftops, no figure worth drawing.
    parts.push(box(140, 330, 340, 470));
    parts.push(box(380, 300, 560, 500));
    parts.push(box(600, 360, 720, 460));
  } else {
    // Default: wide. Small figure, lots of space around it.
    parts.push(...figure(300 + jitter(8), horizonY - 70, 0.8));
    parts.push(stroke([[60, H - 60], [200, horizonY + 40]], 3));
    parts.push(stroke([[W - 60, H - 60], [W - 220, horizonY + 40]], 3));
  }
  return parts;
}

