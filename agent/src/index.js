// index.js — the Sceneflow assistant as a headless Automerge peer.
//
// There is no special "AI integration" in the sync layer: this
// process joins the board exactly the way a second iPad does — a
// Repo, a WebSocket to the relay, `repo.find(<share token>)` — and
// everything it says is an ordinary comment appended to the same
// CRDT list the app renders. Offline tolerance therefore comes for
// free: if the human is away, their question syncs when they return,
// the agent answers, and the answer merges back whenever they next
// connect.
//
// Usage:
//   node src/index.js <documentId | automerge:url> [--relay ws://localhost:3030]
//
// The documentId is the same bs58 token the app's share sheet
// produces (BoardSummary.documentIdString).

import { Repo } from "@automerge/automerge-repo";
import { BrowserWebSocketClientAdapter } from "@automerge/automerge-repo-network-websocket";
import { AGENT_PEER_ID, makeReplyComment } from "./schema.js";
import { findPendingMentions } from "./assistant.js";
import { composeReply } from "./respond.js";
import { CUT_RE, parseCutRequest, runCut, reportToComment } from "./cut/run.js";

const args = process.argv.slice(2);
const docArg = args.find(a => !a.startsWith("--"));
const relayFlag = args.indexOf("--relay");
const relayUrl =
  relayFlag !== -1 ? args[relayFlag + 1]
  : process.env.SCENEFLOW_RELAY ?? "ws://localhost:3030";

if (!docArg) {
  console.error("usage: node src/index.js <documentId> [--relay ws://host:port]");
  process.exit(1);
}

const repo = new Repo({
  network: [new BrowserWebSocketClientAdapter(relayUrl)],
  peerId: AGENT_PEER_ID,
  // Mirror the app's SharePolicy.agreeable: we're a leaf peer talking
  // to a relay that only routes, so there's nothing to withhold.
  sharePolicy: async () => true,
});

console.log(`[assistant] connecting to ${relayUrl}, board ${docArg}`);
// `find` accepts either the bare bs58 documentId or an automerge: URL
// and returns a handle immediately; the doc itself streams in from
// whichever peer (via the relay) has it.
const handle = repo.find(docArg);

handle.on("unavailable", () => {
  console.log(
    "[assistant] board not found on the relay yet — waiting. " +
    "(Is the app open and online? It must announce the doc once.)",
  );
});

await handle.whenReady();
console.log("[assistant] board synced — watching for @assistant mentions");

// Serialize scans: composing a reply is async (a model call), and
// `change` events keep arriving while we work — including the echo
// of our own reply. One scan at a time + a rescan flag keeps this
// simple; `inFlight` stops a re-entrant scan from answering a
// mention twice before its reply lands in the doc.
const inFlight = new Set();
let scanning = false;
let rescanWanted = false;

async function scan() {
  if (scanning) { rescanWanted = true; return; }
  scanning = true;
  try {
    do {
      rescanWanted = false;
      const doc = handle.docSync();
      const pending = findPendingMentions(doc).filter(c => !inFlight.has(c.id));
      for (const mention of pending) {
        inFlight.add(mention.id);
        console.log(`[assistant] ${mention.authorName} asked: "${mention.text}"`);
        try {
          // Two kinds of mention. Most are questions about the board
          // and get an answer. A mention that asks for a CUT starts
          // the multi-app run: Drive -> match -> Resolve -> Todoist,
          // reported back as a comment on this same board.
          const text = CUT_RE.test(mention.text)
            ? reportToComment(await runCut(doc, {
                ...parseCutRequest(mention.text),
                docId: docArg,
                onLog: m => console.log(`[cut] ${m}`),
              }))
            : await composeReply(doc, mention);
          handle.change(d => {
            if (!d.comments) d.comments = [];
            d.comments.push(makeReplyComment(mention, text));
          });
          console.log(`[assistant] replied to ${mention.id}`);
        } catch (err) {
          console.error(`[assistant] failed to reply to ${mention.id}:`, err);
        } finally {
          inFlight.delete(mention.id);
        }
      }
    } while (rescanWanted);
  } finally {
    scanning = false;
  }
}

handle.on("change", () => { void scan(); });
void scan();
