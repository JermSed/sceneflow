// schema.js — the JS side of Sceneflow's Automerge schema contract.
//
// The Swift app authors the document with specific low-level scalar
// types (see flow/Model/BoardDocument.swift). This agent writes into
// the SAME document from JavaScript, so every value it writes must
// land as a scalar type Swift's `AutomergeDecoder` accepts — this
// file is the one place that knows those rules.
//
// The rules, verified against automerge JS 2.2.9 (`proxies.js
// import_value`) and automerge-swift 0.7.2's decoder:
//
//  • STRINGS — the dangerous one. automerge-repo uses the JS "next"
//    API, where a plain JS string becomes a collaborative Text
//    OBJECT. But Swift decodes String fields only from plain "str"
//    scalars — a Text object makes the entire CanvasDoc decode
//    throw, and the board would fail to open in the app. Every
//    string we write is therefore wrapped in `A.RawString`, which
//    forces the "str" scalar Swift expects.
//
//  • NUMBERS — forgiving. Swift decodes Double from both f64 and
//    int scalars, and Int from int/uint. JS stores integer numbers
//    as "int" by default, so we wrap coordinates in `A.Float64`
//    only to keep the doc's schema uniform with what Swift writes
//    (x/y are always f64), not because decode would fail.
//
//  • DATES — a JS `Date` becomes a "timestamp" scalar, exactly
//    matching Swift's `.Timestamp(comment.createdAt)`.
//
//  • UUIDS — Automerge has no UUID scalar; both sides store
//    `uuidString` as a plain string. Swift emits uppercase, so we
//    generate uppercase and compare case-insensitively on read.

import { next as A } from "@automerge/automerge";
import { randomUUID } from "node:crypto";

/** Stable identity this agent writes as `authorPeerId`. The Swift app
 * shows comments by name, so this mostly matters for "did I write
 * this?" checks — which is how the agent avoids replying to itself. */
export const AGENT_PEER_ID = "sceneflow-assistant";
export const AGENT_NAME = "Assistant";

/** Normalize any Automerge string representation (RawString from a
 * "str" scalar, string from a Text object) to a plain JS string. */
export function str(value) {
  if (value == null) return "";
  return value.toString();
}

/** Read `doc.comments` into plain JS values so the rest of the agent
 * never touches Automerge proxy types. */
export function readComments(doc) {
  const list = doc?.comments ?? [];
  return Array.from(list, c => ({
    id: str(c.id).toUpperCase(),
    x: Number(c.x),
    y: Number(c.y),
    z: Number(c.z),
    authorPeerId: str(c.authorPeerId),
    authorName: str(c.authorName),
    text: str(c.text),
    createdAt: c.createdAt instanceof Date ? c.createdAt : new Date(Number(c.createdAt) || 0),
    isResolved: Boolean(c.isResolved),
    // Optional threading field — absent on comments from app builds
    // that predate the agent. `replyTo` is what lets the agent (and
    // eventually the UI) tie an answer back to its question.
    replyTo: c.replyTo == null ? null : str(c.replyTo).toUpperCase(),
  }));
}

/** Build a reply comment ready to `push` inside `handle.change()`.
 * Placed just below-right of the original pin so the pair reads as a
 * thread on the field. */
export function makeReplyComment(original, text) {
  return {
    id: new A.RawString(randomUUID().toUpperCase()),
    x: new A.Float64(original.x + 36),
    y: new A.Float64(original.y + 36),
    z: original.z + 1,
    authorPeerId: new A.RawString(AGENT_PEER_ID),
    authorName: new A.RawString(AGENT_NAME),
    text: new A.RawString(text),
    createdAt: new Date(),
    isResolved: false,
    replyTo: new A.RawString(original.id),
  };
}
