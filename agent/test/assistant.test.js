// Unit tests for the assistant's decision logic and the JS side of the
// schema contract. Everything runs on an in-memory Automerge doc — no
// relay, no API key (dedupe and mention logic are pure functions).
//
// The schema assertions here are the JS half of the cross-runtime
// contract; the Swift half is AgentInteropTests in flowTests, which
// decodes bytes produced by test/make-fixture.js.

import { test } from "node:test";
import assert from "node:assert/strict";
import { next as A } from "@automerge/automerge";
import { AGENT_PEER_ID, makeReplyComment, readComments } from "../src/schema.js";
import { findPendingMentions, describeBoard, MENTION_RE } from "../src/assistant.js";

/** A doc shaped the way the Swift app seeds a board (BoardDocument.seedRoot),
 * with one user comment asking for the assistant. */
function makeBoardDoc() {
  let doc = A.init();
  doc = A.change(doc, d => {
    d.snapshots = [];
    d.activeSketch = { strokes: [] };
    d.texts = [];
    d.images = [];
    d.comments = [];
    d.connectors = [];
    d.comments.push({
      id: new A.RawString("11111111-AAAA-4AAA-8AAA-111111111111"),
      x: new A.Float64(100),
      y: new A.Float64(200),
      z: 3,
      authorPeerId: new A.RawString("some-ipad"),
      authorName: new A.RawString("Maya"),
      text: new A.RawString("@assistant is there enough coverage here?"),
      createdAt: new Date("2026-07-10T10:00:00Z"),
      isResolved: false,
    });
  });
  return doc;
}

test("mention regex matches @assistant and @claude, not emails", () => {
  assert.ok(MENTION_RE.test("hey @assistant look at this"));
  assert.ok(MENTION_RE.test("@Claude what do you think"));
  assert.ok(!MENTION_RE.test("mail me at bob@assistantfilms.com".replace("@assistant", "@assistantx")));
  assert.ok(!MENTION_RE.test("no mention here"));
});

test("finds an unanswered mention", () => {
  const doc = makeBoardDoc();
  const pending = findPendingMentions(doc);
  assert.equal(pending.length, 1);
  assert.equal(pending[0].authorName, "Maya");
});

test("a reply with replyTo marks the mention answered", () => {
  let doc = makeBoardDoc();
  const [mention] = findPendingMentions(doc);
  doc = A.change(doc, d => {
    d.comments.push(makeReplyComment(mention, "Looks good — add a close-up between frames 2 and 3."));
  });
  assert.equal(findPendingMentions(doc).length, 0);
});

test("agent's own comments and resolved pins are never pending", () => {
  let doc = makeBoardDoc();
  doc = A.change(doc, d => {
    // The agent talking about itself must not trigger a self-reply loop.
    d.comments.push({
      id: new A.RawString("22222222-BBBB-4BBB-8BBB-222222222222"),
      x: new A.Float64(0), y: new A.Float64(0), z: 1,
      authorPeerId: new A.RawString(AGENT_PEER_ID),
      authorName: new A.RawString("Assistant"),
      text: new A.RawString("@assistant mentioned in my own reply"),
      createdAt: new Date(), isResolved: false,
    });
    d.comments[0].isResolved = true; // human resolved the original thread
  });
  assert.equal(findPendingMentions(doc).length, 0);
});

test("reply survives save/load with the scalar types Swift expects", () => {
  let doc = makeBoardDoc();
  const [mention] = findPendingMentions(doc);
  doc = A.change(doc, d => {
    d.comments.push(makeReplyComment(mention, "reply text"));
  });

  // Round-trip through the wire format, then check the low-level types.
  const loaded = A.load(A.save(doc));
  const reply = loaded.comments[1];

  // Strings must come back as RawString (a "str" scalar) — a plain JS
  // string here would mean we wrote a Text object, which makes the
  // whole CanvasDoc decode throw on the Swift side.
  for (const key of ["id", "authorPeerId", "authorName", "text", "replyTo"]) {
    assert.ok(reply[key] instanceof A.RawString, `${key} must be a str scalar, got ${typeof reply[key]}`);
  }
  assert.ok(reply.createdAt instanceof Date, "createdAt must be a timestamp scalar");
  assert.equal(typeof reply.isResolved, "boolean");
  assert.equal(reply.replyTo.toString(), mention.id);

  // And the normalized read path agrees.
  const [, normalized] = readComments(loaded);
  assert.equal(normalized.authorPeerId, AGENT_PEER_ID);
  assert.equal(normalized.replyTo, mention.id);
});

test("describeBoard reports frames, connectors, and notes", () => {
  let doc = makeBoardDoc();
  doc = A.change(doc, d => {
    d.snapshots.push({
      id: new A.RawString("33333333-CCCC-4CCC-8CCC-333333333333"),
      x: new A.Float64(50), y: new A.Float64(60), z: 1,
      width: new A.Float64(800), height: new A.Float64(600),
      strokes: [],
    });
    d.snapshots.push({
      id: new A.RawString("44444444-DDDD-4DDD-8DDD-444444444444"),
      x: new A.Float64(950), y: new A.Float64(60), z: 2,
      width: new A.Float64(800), height: new A.Float64(600),
      strokes: [],
    });
    d.connectors.push({
      id: new A.RawString("55555555-EEEE-4EEE-8EEE-555555555555"),
      from: new A.RawString("33333333-CCCC-4CCC-8CCC-333333333333"),
      to: new A.RawString("44444444-DDDD-4DDD-8DDD-444444444444"),
    });
    d.texts.push({
      id: new A.RawString("66666666-FFFF-4FFF-8FFF-666666666666"),
      x: new A.Float64(50), y: new A.Float64(700), z: 1,
      text: new A.RawString("WIDE — alley entrance"),
      fontSize: new A.Float64(24), color: 0xFF0000FF,
    });
  });
  const [mention] = findPendingMentions(doc);
  const description = describeBoard(doc, mention);
  assert.match(description, /Snapshots \(captured frames\): 2/);
  assert.match(description, /Frame 1 -> Frame 2/);
  assert.match(description, /WIDE — alley entrance/);
});
