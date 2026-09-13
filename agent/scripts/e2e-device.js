// e2e-device.js — plays the iPad's role for an end-to-end plumbing test.
//
// Creates a board through the real relay, pins an @assistant comment,
// and waits for the assistant's reply to arrive over sync. Run the
// relay (sync-server/) and then the agent against the printed DOC_ID;
// this process exits 0 the moment the reply merges in.
//
//   node scripts/e2e-device.js          # prints "DOC_ID <id>", waits
//   ASSISTANT_CANNED=1 node src/index.js <id>   # in another shell

import { Repo } from "@automerge/automerge-repo";
import { BrowserWebSocketClientAdapter } from "@automerge/automerge-repo-network-websocket";
import { next as A } from "@automerge/automerge";

const relay = process.env.SCENEFLOW_RELAY ?? "ws://localhost:3030";
const repo = new Repo({
  network: [new BrowserWebSocketClientAdapter(relay)],
  peerId: "e2e-device",
  sharePolicy: async () => true,
});

const handle = repo.create();
handle.change(d => {
  // Same root shape BoardDocument.seedRoot builds.
  d.snapshots = [];
  d.activeSketch = { strokes: [] };
  d.texts = [];
  d.images = [];
  d.comments = [];
  d.connectors = [];
  d.comments.push({
    id: new A.RawString(crypto.randomUUID().toUpperCase()),
    x: new A.Float64(100),
    y: new A.Float64(100),
    z: 1,
    authorPeerId: new A.RawString("e2e-device"),
    authorName: new A.RawString("E2E"),
    text: new A.RawString("@assistant are you there?"),
    createdAt: new Date(),
    isResolved: false,
  });
});

console.log(`DOC_ID ${handle.documentId}`);

handle.on("change", ({ doc }) => {
  const reply = Array.from(doc.comments).find(c => c.replyTo != null);
  if (reply) {
    console.log(`REPLY_RECEIVED from ${reply.authorName}: ${reply.text}`);
    process.exit(0);
  }
});

setTimeout(() => {
  console.error("TIMEOUT: no reply within 60s");
  process.exit(1);
}, 60_000);
