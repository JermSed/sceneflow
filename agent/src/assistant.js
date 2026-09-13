// assistant.js — pure decision logic: which comments need a reply,
// and what the agent can see of the board when composing one.
//
// Deliberately network-free and Automerge-free (it consumes the plain
// values `schema.js` produces) so it can be unit-tested without a
// relay or a wasm runtime.
//
// Dedupe is CRDT-native rather than agent-local: a mention is
// "handled" iff the document contains a reply pointing at it via
// `replyTo`. Because that marker lives in the same Automerge doc as
// the mention itself, it survives agent restarts, merges cleanly if
// the agent answered while a peer was offline, and even stays correct
// if two agent instances race — both replies land (list CRDT appends
// both), which is noisy but never wrong, and trivially visible.

import { AGENT_PEER_ID, readComments, str } from "./schema.js";

/** What counts as summoning the agent inside a comment's text. */
export const MENTION_RE = /@(assistant|claude)\b/i;

/** Comments that mention the agent and still lack an agent reply.
 * Skips resolved pins (resolving a thread is the human gesture for
 * "conversation over") and anything the agent itself wrote. */
export function findPendingMentions(doc) {
  const comments = readComments(doc);
  const answered = new Set(
    comments.filter(c => c.replyTo != null).map(c => c.replyTo),
  );
  return comments.filter(c =>
    MENTION_RE.test(c.text) &&
    !c.isResolved &&
    c.authorPeerId !== AGENT_PEER_ID &&
    !answered.has(c.id),
  );
}

/** A text description of the board for the model: everything except
 * the raw stroke geometry (that arrives with the vision step —
 * sketch content only makes sense rendered). Positions are included
 * because spatial arrangement IS the medium in Sceneflow: left-to-
 * right usually reads as sequence order.
 *
 * `asking` is the comment being answered; nearby elements matter
 * more than far ones, so we report each element's distance to it. */
export function describeBoard(doc, asking) {
  const dist = el =>
    Math.round(Math.hypot(el.x - asking.x, el.y - asking.y));
  const lines = [];

  const snapshots = Array.from(doc?.snapshots ?? []);
  lines.push(`Snapshots (captured frames): ${snapshots.length}`);
  const snapIndex = new Map();
  snapshots.forEach((s, i) => {
    const id = str(s.id).toUpperCase();
    snapIndex.set(id, i + 1);
    lines.push(
      `  Frame ${i + 1}: at (${Math.round(s.x)}, ${Math.round(s.y)}), ` +
      `${Math.round(s.width ?? 800)}x${Math.round(s.height ?? 600)}, ` +
      `${(s.strokes ?? []).length} strokes, ` +
      `${dist({ x: Number(s.x), y: Number(s.y) })}pt from the question pin`,
    );
  });

  const connectors = Array.from(doc?.connectors ?? []);
  if (connectors.length > 0) {
    lines.push(`Connectors (arrows between frames):`);
    for (const c of connectors) {
      const from = snapIndex.get(str(c.from).toUpperCase());
      const to = snapIndex.get(str(c.to).toUpperCase());
      if (from && to) lines.push(`  Frame ${from} -> Frame ${to}`);
    }
  }

  const texts = Array.from(doc?.texts ?? []);
  if (texts.length > 0) {
    lines.push(`Text notes:`);
    for (const t of texts) {
      lines.push(
        `  "${str(t.text)}" at (${Math.round(t.x)}, ${Math.round(t.y)}), ` +
        `${dist({ x: Number(t.x), y: Number(t.y) })}pt from the question pin`,
      );
    }
  }

  const comments = readComments(doc).filter(c => c.id !== asking.id);
  if (comments.length > 0) {
    lines.push(`Other comments on the board:`);
    for (const c of comments) {
      lines.push(
        `  ${c.authorName}${c.isResolved ? " (resolved)" : ""}: "${c.text}"`,
      );
    }
  }

  return lines.join("\n");
}
