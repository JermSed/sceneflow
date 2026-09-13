// cut/match.js — the judgement step.
//
// Everything else in this agent is plumbing between apps. This is the
// part that has to be *right*: given N hand-drawn storyboard beats and
// M clips of real footage, decide which clip is which beat, which
// beats were never shot, and what each shot should look like graded.
//
// Three design choices matter for reliability, and the eval suite
// measures all three:
//
//  1. THE MODEL SEES BOTH SIDES AS PICTURES. Each beat goes in as its
//     own cropped render (render.js: renderFramePNG) and each clip as
//     its Drive poster frame. Filename matching alone looks great on
//     tidy demo footage and collapses on a real card dump where
//     everything is C0042.MP4.
//
//  2. THE MODEL MAY DECLINE. "No clip matches this beat" is a
//     first-class answer, not a failure. A confidence below
//     MATCH_THRESHOLD is downgraded to unmatched by code, not by the
//     model's own restraint — the threshold is a dial we can tune and
//     measure rather than a mood.
//
//  3. THE OUTPUT IS REPAIRED, NOT TRUSTED. Structured output still
//     lets a model assign one clip to two beats or return a beat that
//     doesn't exist. `reconcile()` is deterministic and fixes those
//     without a second model call, so a flaky generation degrades to
//     a smaller cut instead of a corrupt one.

import Anthropic from "@anthropic-ai/sdk";
import { renderFramePNG } from "../render.js";

export const MATCH_THRESHOLD = Number(process.env.SCENEFLOW_MATCH_THRESHOLD ?? 0.55);
const MODEL = process.env.SCENEFLOW_MODEL ?? "claude-opus-4-8";

const SYSTEM_PROMPT = `You are the cut assistant for Sceneflow, a storyboarding \
canvas used in film pre-production. You are given, in order, the beats of a \
storyboard — each one a hand-drawn frame plus whatever the director wrote next \
to it — and a catalog of real footage from the shoot, each clip with a poster \
frame and its metadata.

Assign footage to beats.

How to judge a match, in descending order of weight:
- What is actually in the two pictures: subject, shot size (wide / medium / \
close-up), camera angle, screen direction, what is in the foreground.
- The director's note on the beat, against the clip's filename. Crew name \
files meaningfully — scene, shot size, subject, take number — but they also \
dump cards as C0042.MP4, so never let a filename override what you can see.
- Clip duration against the weight of the beat. An establishing wide is not \
a 0.8 second clip.

Rules you must follow:
- Each clip may be used for AT MOST ONE beat. Two beats that both look like \
the same coverage are a sign one of them was not shot.
- If nothing in the catalog plausibly covers a beat, return no clip for it. \
An honest gap is the most useful thing you can report — it becomes a shoot-list \
task. Do not stretch a loosely related clip to fill a hole.
- confidence is your real belief that this clip IS this beat: 0.9+ only when \
the picture matches, 0.5-0.7 when the note and metadata fit but the image is \
ambiguous, below 0.4 when you are guessing.

For every beat, matched or not, also give the look: a short phrase for the \
intended grade drawn from the sketch and the director's note (time of day, \
interior/exterior, mood), and an ASC CDL that expresses it — slope, offset and \
power as [r,g,b] plus saturation. Keep grades restrained and plausible on real \
footage: slope 0.8-1.2, offset -0.05 to 0.05, power 0.9-1.1, saturation 0.6-1.2. \
Neutral is slope [1,1,1], offset [0,0,0], power [1,1,1], saturation 1.0.`;

const CUT_TOOL = {
  name: "submit_cut",
  description: "Submit the beat-to-footage assignment for the whole storyboard. Include every beat exactly once.",
  input_schema: {
    type: "object",
    properties: {
      assignments: {
        type: "array",
        items: {
          type: "object",
          properties: {
            beat: { type: "integer", description: "The beat number, as labeled in the prompt." },
            clipId: {
              type: ["string", "null"],
              description: "Drive file id of the matching clip, or null if this beat has no footage.",
            },
            confidence: { type: "number", minimum: 0, maximum: 1 },
            reason: { type: "string", description: "One sentence: what in the two images or the metadata decided this." },
            startSeconds: { type: ["number", "null"], description: "Where in the clip the usable action starts." },
            durationSeconds: { type: ["number", "null"], description: "How long this beat should hold on screen." },
            look: { type: "string", description: "Short phrase for the intended grade, e.g. 'cold dusk exterior'." },
            cdl: {
              type: "object",
              properties: {
                slope: { type: "array", items: { type: "number" }, minItems: 3, maxItems: 3 },
                offset: { type: "array", items: { type: "number" }, minItems: 3, maxItems: 3 },
                power: { type: "array", items: { type: "number" }, minItems: 3, maxItems: 3 },
                saturation: { type: "number" },
              },
              required: ["slope", "offset", "power", "saturation"],
            },
          },
          required: ["beat", "clipId", "confidence", "reason", "look", "cdl"],
        },
      },
      sequenceNotes: {
        type: "string",
        description: "One or two sentences for the editor about the cut as a whole: coverage gaps, continuity risks, anything that needs a human eye.",
      },
    },
    required: ["assignments", "sequenceNotes"],
  },
};

const NEUTRAL_CDL = { slope: [1, 1, 1], offset: [0, 0, 0], power: [1, 1, 1], saturation: 1 };

function clampCDL(cdl) {
  if (!cdl) return NEUTRAL_CDL;
  const trio = (v, lo, hi, fallback) =>
    Array.isArray(v) && v.length === 3 && v.every(n => Number.isFinite(Number(n)))
      ? v.map(n => Math.min(hi, Math.max(lo, Number(n))))
      : fallback;
  return {
    slope: trio(cdl.slope, 0.5, 2, NEUTRAL_CDL.slope),
    offset: trio(cdl.offset, -0.2, 0.2, NEUTRAL_CDL.offset),
    power: trio(cdl.power, 0.5, 2, NEUTRAL_CDL.power),
    // `Number(null)` is 0, which is finite — and a saturation of 0
    // silently ships a black-and-white cut. Reject empties first.
    saturation: cdl.saturation == null || cdl.saturation === "" || !Number.isFinite(Number(cdl.saturation))
      ? 1
      : Math.min(2, Math.max(0, Number(cdl.saturation))),
  };
}

/**
 * Turn whatever the model returned into a valid cut. Pure, sync,
 * and unit-tested against adversarial inputs — this is the function
 * that stands between a bad generation and a corrupt timeline.
 *
 * Repairs, in order:
 *  - drop assignments for beats that don't exist
 *  - drop clip ids that aren't in the catalog (hallucinated footage)
 *  - downgrade sub-threshold confidence to unmatched
 *  - resolve a clip claimed by two beats in favor of the higher
 *    confidence; the loser becomes unmatched (and therefore a task)
 *  - fill in any beat the model forgot as unmatched
 *  - clamp every CDL into a range that cannot wreck an image
 */
export function reconcile(beats, clips, raw, { threshold = MATCH_THRESHOLD } = {}) {
  const clipIds = new Set(clips.map(c => c.id));
  const byBeat = new Map();
  const warnings = [];

  for (const a of raw?.assignments ?? []) {
    const beat = beats.find(b => b.index === Number(a.beat));
    if (!beat) { warnings.push(`dropped assignment for unknown beat ${a.beat}`); continue; }
    if (byBeat.has(beat.index)) { warnings.push(`duplicate assignment for beat ${beat.index}`); continue; }

    let clipId = a.clipId ?? null;
    const confidence = Number(a.confidence) || 0;
    if (clipId && !clipIds.has(clipId)) {
      warnings.push(`beat ${beat.index}: model returned a clip id that is not in the catalog`);
      clipId = null;
    }
    if (clipId && confidence < threshold) {
      warnings.push(`beat ${beat.index}: confidence ${confidence.toFixed(2)} below ${threshold} — treated as unshot`);
      clipId = null;
    }
    byBeat.set(beat.index, {
      ...beat,
      clipId,
      confidence,
      reason: String(a.reason ?? "").trim(),
      look: String(a.look ?? "").trim(),
      cdl: clampCDL(a.cdl),
      startSeconds: Number.isFinite(Number(a.startSeconds)) ? Math.max(0, Number(a.startSeconds)) : null,
      durationSeconds: Number.isFinite(Number(a.durationSeconds)) && Number(a.durationSeconds) > 0
        ? Number(a.durationSeconds) : null,
    });
  }

  // One clip, one beat. Highest confidence keeps it.
  const claim = new Map();
  for (const beat of [...byBeat.values()].sort((a, b) => b.confidence - a.confidence)) {
    if (!beat.clipId) continue;
    if (claim.has(beat.clipId)) {
      warnings.push(
        `beat ${beat.index}: clip already used by beat ${claim.get(beat.clipId)} — treated as unshot`,
      );
      beat.clipId = null;
    } else {
      claim.set(beat.clipId, beat.index);
    }
  }

  for (const beat of beats) {
    if (byBeat.has(beat.index)) continue;
    warnings.push(`beat ${beat.index}: model returned no assignment — treated as unshot`);
    byBeat.set(beat.index, {
      ...beat, clipId: null, confidence: 0,
      reason: "no assignment returned", look: "", cdl: NEUTRAL_CDL,
      startSeconds: null, durationSeconds: null,
    });
  }

  const assignments = beats.map(b => byBeat.get(b.index));
  return { assignments, sequenceNotes: String(raw?.sequenceNotes ?? "").trim(), warnings };
}

/** The prompt payload: every beat as a picture, every clip as a
 * picture. Split out so the eval suite can assert on what the model
 * is actually shown without spending a token. */
export function buildMatchContent(beats, clips, frames, thumbnails) {
  const content = [];
  content.push({ type: "text", text: `STORYBOARD — ${beats.length} beats, in order:` });
  for (const beat of beats) {
    const png = frames.get(beat.index);
    content.push({
      type: "text",
      text: `Beat ${beat.index}: ${beat.description}` +
        (beat.labels.length > 1 ? `\n  other notes nearby: ${beat.labels.slice(1).join(" | ")}` : "") +
        `\n  ordered by: ${beat.orderedBy}${png ? "" : "  (nothing drawn on this frame)"}`,
    });
    if (png) {
      content.push({
        type: "image",
        source: { type: "base64", media_type: "image/png", data: png.toString("base64") },
      });
    }
  }

  content.push({ type: "text", text: `\nFOOTAGE CATALOG — ${clips.length} clips from Google Drive:` });
  for (const clip of clips) {
    const dur = clip.durationSeconds ? `${clip.durationSeconds.toFixed(1)}s` : "duration unknown";
    const res = clip.width ? `${clip.width}x${clip.height}` : "resolution unknown";
    content.push({
      type: "text",
      text: `Clip id ${clip.id}\n  filename: ${clip.name}\n  ${dur}, ${res}, shot ${clip.createdTime ?? "unknown date"}`,
    });
    const thumb = thumbnails.get(clip.id);
    if (thumb) {
      content.push({
        type: "image",
        source: { type: "base64", media_type: thumb.mediaType, data: thumb.buffer.toString("base64") },
      });
    }
  }

  content.push({
    type: "text",
    text: "\nAssign footage to beats and submit with the submit_cut tool. " +
      "Every beat must appear exactly once. Leave clipId null for beats with no footage.",
  });
  return content;
}

let client = null;

/**
 * Match beats to clips. Returns the reconciled cut.
 *
 * `SCENEFLOW_CANNED=1` skips the model and matches on filename
 * tokens instead — a deterministic baseline that exercises every
 * other step of the pipeline with no API key and no cost. The eval
 * suite reports both, so "did the model help?" is a number.
 */
export async function matchBeatsToClips(beats, clips, { onLog } = {}) {
  const frames = new Map();
  for (const beat of beats) {
    const rendered = renderFramePNG(
      { width: beat.width, height: beat.height, strokes: beat.strokes ?? [] },
      { label: `Beat ${beat.index} — ${beat.description}` },
    );
    if (rendered && beat.strokeCount > 0) frames.set(beat.index, rendered.png);
  }

  if (process.env.SCENEFLOW_CANNED === "1") {
    onLog?.("matcher: canned filename baseline (SCENEFLOW_CANNED=1)");
    return reconcile(beats, clips, filenameBaseline(beats, clips));
  }

  const thumbnails = new Map();
  for (const clip of clips) {
    if (clip.thumbnail) thumbnails.set(clip.id, clip.thumbnail);
  }

  client ??= new Anthropic();
  onLog?.(`matcher: asking ${MODEL} to match ${beats.length} beats against ${clips.length} clips`);
  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 16000,
    thinking: { type: "adaptive" },
    system: SYSTEM_PROMPT,
    tools: [CUT_TOOL],
    tool_choice: { type: "tool", name: "submit_cut" },
    messages: [{ role: "user", content: buildMatchContent(beats, clips, frames, thumbnails) }],
  });

  const call = response.content.find(b => b.type === "tool_use" && b.name === "submit_cut");
  if (!call) throw new Error(`model did not call submit_cut (stop_reason: ${response.stop_reason})`);
  return reconcile(beats, clips, call.input);
}

/** Deterministic fallback matcher: score on shared word tokens
 * between the beat's note and the clip's filename. Weak on purpose —
 * it is the baseline the model has to beat, and the thing that keeps
 * the pipeline runnable with no credentials. */
export function filenameBaseline(beats, clips) {
  const tokens = s => new Set(String(s).toLowerCase().match(/[a-z]{3,}/g) ?? []);
  const SIZES = { wide: ["wide", "ws", "establishing", "est"], medium: ["medium", "ms", "mid"], close: ["close", "cu", "closeup", "insert", "detail"] };
  const used = new Set();
  const assignments = beats.map(beat => {
    const beatTokens = tokens(beat.labels.join(" "));
    for (const [size, aliases] of Object.entries(SIZES)) {
      if (aliases.some(a => beatTokens.has(a))) aliases.forEach(a => beatTokens.add(a));
      if (beatTokens.has(size)) aliases.forEach(a => beatTokens.add(a));
    }
    // Score by how many meaningful words the note and the filename
    // share. Two is the floor: one shared word ("wide") matches
    // every wide in the folder.
    let best = null, bestOverlap = 0;
    for (const clip of clips) {
      if (used.has(clip.id)) continue;
      const overlap = [...tokens(clip.name)].filter(t => beatTokens.has(t)).length;
      if (overlap > bestOverlap) { bestOverlap = overlap; best = clip; }
    }
    const matched = best && bestOverlap >= 2;
    if (matched) used.add(best.id);
    return {
      beat: beat.index,
      clipId: matched ? best.id : null,
      confidence: matched ? Math.min(0.95, 0.4 + 0.18 * bestOverlap) : Math.min(0.4, 0.18 * bestOverlap),
      reason: best ? `${bestOverlap} filename word(s) shared with ${best.name}` : "no filename overlap",
      look: "neutral",
      cdl: NEUTRAL_CDL,
      startSeconds: 0,
      durationSeconds: best?.durationSeconds ? Math.min(5, best.durationSeconds) : 3,
    };
  });
  return { assignments, sequenceNotes: "Filename baseline — no model call." };
}
