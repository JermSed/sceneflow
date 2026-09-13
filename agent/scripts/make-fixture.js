// make-fixture.js — emits a base64 Automerge blob for the Swift side of
// the cross-runtime contract test (flowTests/AgentInteropTests.swift).
//
// The doc mimics a real board after the agent has replied: the Swift
// root shape, one user comment mentioning the assistant, and one
// agent-authored reply written through the same makeReplyComment()
// code path production uses. If Swift's `BoardDocument(data:)` +
// `AutomergeDecoder` accept these bytes, an agent reply can never make
// a board fail to open in the app.
//
// Usage: node scripts/make-fixture.js   → base64 on stdout

import { next as A } from "@automerge/automerge";
import { makeReplyComment } from "../src/schema.js";

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
    x: new A.Float64(120),
    y: new A.Float64(340),
    z: 2,
    authorPeerId: new A.RawString("device-peer-1"),
    authorName: new A.RawString("Maya"),
    text: new A.RawString("@assistant is there enough coverage between these beats?"),
    createdAt: new Date("2026-07-10T10:00:00Z"),
    isResolved: false,
  });
});
doc = A.change(doc, d => {
  d.comments.push(
    makeReplyComment(
      { id: "11111111-AAAA-4AAA-8AAA-111111111111", x: 120, y: 340, z: 2 },
      "Consider an insert shot between the wide and the close-up.",
    ),
  );
});

process.stdout.write(Buffer.from(A.save(doc)).toString("base64"));
