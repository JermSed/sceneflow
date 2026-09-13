// render.js — draws the board to a PNG so the model can see the
// actual sketches, not just their layout.
//
// Geometry mirrors FieldView.swift exactly:
//  • Every element (snapshot, image, text, comment pin) is CENTERED
//    at its (x, y). The field plane is a SwiftUI ZStack (center
//    alignment) and elements are placed with .offset(x:y:), so (x, y)
//    displaces the element's center from the field origin.
//  • Snapshot strokes are frame-local coordinates (0,0 = frame's
//    top-left) and are clipped to the frame's width x height.
//  • Connectors join the CENTERS of their two snapshots and draw
//    behind the frames.
//  • The active sketch's field position is per-device view state (not
//    in the doc), so it can't be placed truthfully — if it has
//    strokes we render it as a separate tile below the board with a
//    label saying its on-field position is unknown.
//
// Frames are numbered 1..n in list order to match describeBoard(), so
// the model can cross-reference the image with the text description.
// The comment being answered is marked with a red ring.

import { Resvg } from "@resvg/resvg-js";
import { str } from "./schema.js";

const PAD = 48;               // field-pts of margin around the content
const MAX_LONG_EDGE = 1568;   // keeps image tokens bounded

/** 0xRRGGBBAA (how the app packs stroke/text colors) → CSS rgba(). */
function cssColor(packed) {
  const c = Number(packed) >>> 0;
  const r = (c >>> 24) & 0xff, g = (c >>> 16) & 0xff, b = (c >>> 8) & 0xff;
  return `rgba(${r},${g},${b},${(c & 0xff) / 255})`;
}

function esc(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function strokePath(stroke, offsetX, offsetY) {
  const pts = Array.from(stroke.points ?? []);
  if (pts.length === 0) return "";
  const d = pts
    .map((p, i) => `${i === 0 ? "M" : "L"}${(offsetX + Number(p.x)).toFixed(1)} ${(offsetY + Number(p.y)).toFixed(1)}`)
    .join(" ");
  // A single tap produces a 1-point stroke; give it a dot to render.
  const path = pts.length === 1 ? `${d} l0.1 0` : d;
  return `<path d="${path}" fill="none" stroke="${cssColor(stroke.color)}" ` +
    `stroke-width="${Number(stroke.width) || 2}" stroke-linecap="round" stroke-linejoin="round"/>`;
}

/** One frame tile: white card, border, title, clipped strokes. */
function frameTile({ cx, cy, w, h, title, strokes, clipId }) {
  const left = cx - w / 2, top = cy - h / 2;
  const body = Array.from(strokes ?? []).map(s => strokePath(s, left, top)).join("");
  return `
  <g>
    <clipPath id="${clipId}"><rect x="${left}" y="${top}" width="${w}" height="${h}" rx="6"/></clipPath>
    <rect x="${left}" y="${top}" width="${w}" height="${h}" rx="6" fill="white" stroke="#bbb" stroke-width="1.5"/>
    <text x="${left}" y="${top - 8}" font-size="16" font-family="Helvetica, Arial, sans-serif" fill="#555">${esc(title)}</text>
    <g clip-path="url(#${clipId})">${body}</g>
  </g>`;
}

/**
 * Render the whole board to a PNG. Returns
 * `{ png: Buffer, width, height }` or null when the board has nothing
 * visual to show (no frames, sketch strokes, images, or text).
 */
export function renderBoardPNG(doc, asking) {
  const snapshots = Array.from(doc?.snapshots ?? []);
  const images = Array.from(doc?.images ?? []);
  const texts = Array.from(doc?.texts ?? []);
  const comments = Array.from(doc?.comments ?? []);
  const connectors = Array.from(doc?.connectors ?? []);
  const sketchStrokes = Array.from(doc?.activeSketch?.strokes ?? []);

  if (snapshots.length + images.length + texts.length + sketchStrokes.length === 0) return null;

  // ---- bounding box over everything positioned on the field ----
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  const grow = (cx, cy, w, h) => {
    minX = Math.min(minX, cx - w / 2); maxX = Math.max(maxX, cx + w / 2);
    minY = Math.min(minY, cy - h / 2); maxY = Math.max(maxY, cy + h / 2);
  };
  for (const s of snapshots) grow(Number(s.x), Number(s.y), Number(s.width ?? 800), Number(s.height ?? 600));
  for (const i of images) grow(Number(i.x), Number(i.y), Number(i.width), Number(i.height));
  for (const t of texts) grow(Number(t.x), Number(t.y), 200, Number(t.fontSize) * 1.6);
  for (const c of comments) grow(Number(c.x), Number(c.y), 40, 40);
  if (!Number.isFinite(minX)) { minX = minY = 0; maxX = maxY = 100; }

  const parts = [];

  // Connectors first (they draw behind frames in the app too).
  const centerOf = new Map(snapshots.map(s => [str(s.id).toUpperCase(), [Number(s.x), Number(s.y)]]));
  for (const c of connectors) {
    const from = centerOf.get(str(c.from).toUpperCase());
    const to = centerOf.get(str(c.to).toUpperCase());
    if (!from || !to) continue;
    parts.push(`<line x1="${from[0]}" y1="${from[1]}" x2="${to[0]}" y2="${to[1]}" stroke="#888" stroke-width="3"/>`);
  }

  snapshots.forEach((s, i) => {
    parts.push(frameTile({
      cx: Number(s.x), cy: Number(s.y),
      w: Number(s.width ?? 800), h: Number(s.height ?? 600),
      title: `Frame ${i + 1}`, strokes: s.strokes, clipId: `snap${i}`,
    }));
  });

  for (const img of images) {
    const w = Number(img.width), h = Number(img.height);
    const bytes = img.data instanceof Uint8Array ? img.data : new Uint8Array(img.data ?? []);
    const mime = str(img.format) === "png" ? "image/png" : "image/jpeg";
    parts.push(`<image x="${Number(img.x) - w / 2}" y="${Number(img.y) - h / 2}" width="${w}" height="${h}" ` +
      `href="data:${mime};base64,${Buffer.from(bytes).toString("base64")}"/>`);
  }

  for (const t of texts) {
    parts.push(`<text x="${Number(t.x)}" y="${Number(t.y)}" font-size="${Number(t.fontSize)}" ` +
      `font-family="Helvetica, Arial, sans-serif" fill="${cssColor(t.color)}" ` +
      `text-anchor="middle" dominant-baseline="central">${esc(str(t.text))}</text>`);
  }

  // Comment pins; the one being answered gets a red ring + label.
  for (const c of comments) {
    const isAsking = asking && str(c.id).toUpperCase() === asking.id;
    const x = Number(c.x), y = Number(c.y);
    parts.push(`<circle cx="${x}" cy="${y}" r="10" fill="${isAsking ? "#e33" : "#f5a623"}" stroke="white" stroke-width="2"/>`);
    if (isAsking) {
      parts.push(`<circle cx="${x}" cy="${y}" r="18" fill="none" stroke="#e33" stroke-width="3"/>`);
      parts.push(`<text x="${x + 26}" y="${y}" font-size="18" font-family="Helvetica, Arial, sans-serif" ` +
        `fill="#e33" dominant-baseline="central">this question</text>`);
    }
  }

  // Active sketch tile below the board content (position untruthful —
  // see header). Sized like the app's fixed 800x600 scratchpad.
  let sketchBottom = 0;
  if (sketchStrokes.length > 0) {
    const cx = (minX + maxX) / 2;
    const cy = maxY + PAD + 22 + 300; // 22 title gap + half tile height
    parts.push(frameTile({
      cx, cy, w: 800, h: 600,
      title: "Live sketch (scratchpad — its position on the field varies per device)",
      strokes: sketchStrokes, clipId: "livesketch",
    }));
    grow(cx, cy, 800, 600 + 60);
    sketchBottom = cy + 300;
  }

  const width = maxX - minX + PAD * 2;
  const height = Math.max(maxY, sketchBottom) - minY + PAD * 2;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" ` +
    `viewBox="${minX - PAD} ${minY - PAD} ${width} ${height}">` +
    `<rect x="${minX - PAD}" y="${minY - PAD}" width="${width}" height="${height}" fill="#f2f1ee"/>` +
    parts.join("") +
    `</svg>`;

  const scale = Math.min(1, MAX_LONG_EDGE / Math.max(width, height));
  const resvg = new Resvg(svg, {
    fitTo: { mode: "width", value: Math.round(width * scale) },
    font: { loadSystemFonts: true },
  });
  const rendered = resvg.render();
  return { png: Buffer.from(rendered.asPng()), width: rendered.width, height: rendered.height };
}

/**
 * Render ONE frame on its own, tightly cropped, at a size a vision
 * model can actually read.
 *
 * The board render above is the right picture for "what do you think
 * of this sequence?" — it preserves spatial context, which in
 * Sceneflow carries meaning. It is the wrong picture for matching a
 * beat to footage: at board scale a single sketch is a few dozen
 * pixels, and the model ends up comparing a smudge to a video
 * thumbnail. So the cut agent asks for frames one at a time.
 *
 * The same PNG is what gets attached to the Todoist task for an
 * unshot beat, so whoever picks up the shoot sees the drawing.
 *
 * @returns {{png: Buffer, width: number, height: number} | null}
 */
export function renderFramePNG(frame, { width: outWidth = 640, label } = {}) {
  const w = Number(frame.width) || 800;
  const h = Number(frame.height) || 600;
  const strokes = Array.from(frame.strokes ?? []);
  const pad = 12;
  const titleH = label ? 28 : 0;

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w + pad * 2}" height="${h + pad * 2 + titleH}" viewBox="0 0 ${w + pad * 2} ${h + pad * 2 + titleH}">
  <rect width="100%" height="100%" fill="#f4f4f4"/>
  ${label ? `<text x="${pad}" y="20" font-size="18" font-family="Helvetica, Arial, sans-serif" fill="#333">${esc(label)}</text>` : ""}
  <rect x="${pad}" y="${pad + titleH}" width="${w}" height="${h}" rx="6" fill="white" stroke="#bbb" stroke-width="1.5"/>
  <g>${strokes.map(s => strokePath(s, pad, pad + titleH)).join("")}</g>
</svg>`;

  const rendered = new Resvg(svg, { fitTo: { mode: "width", value: outWidth } }).render();
  return { png: rendered.asPng(), width: rendered.width, height: rendered.height };
}
