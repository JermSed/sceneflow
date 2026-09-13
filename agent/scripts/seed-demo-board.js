// seed-demo-board.js — create a ready-to-cut board on the relay.
//
// Insurance for a demo. Drawing six frames by hand on an iPad while a
// clock runs is a bad time to discover your relay is down, so this
// pushes a complete storyboard — sketched frames, slug lines, and
// connector arrows setting the sequence — straight onto the relay and
// prints the share token.
//
// The board it writes is a real board: the app opens it, you can draw
// on it, and `npm run cut` treats it exactly like one somebody made
// by hand. Every string goes through A.RawString per the Swift
// schema contract in src/schema.js, so it decodes in the app.
//
//   node scripts/seed-demo-board.js [--relay ws://localhost:3030]
//   node scripts/seed-demo-board.js --shots "WIDE - alley,CU - hand,MEDIUM - Ana"

import { Repo } from "@automerge/automerge-repo";
import { BrowserWebSocketClientAdapter } from "@automerge/automerge-repo-network-websocket";
import { next as A } from "@automerge/automerge";
import { sketch, toDocStrokes, uuid, f64 } from "./sketch-shapes.js";

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf(`--${n}`); return i === -1 ? d : args[i + 1]; };
const relayUrl = flag("relay", process.env.SCENEFLOW_RELAY ?? "ws://localhost:3030");

const DEFAULT_SHOTS = [
  // Eight beats against six clips. Two of these were never shot —
  // that is the point of the demo, not an oversight: they are what
  // lands on the Todoist shoot list.
  "WIDE - the whole table, board in the middle, four players",
  "CLOSE UP - hands shaking and rolling the dice",
  "INSERT - the longest road card sitting on the table",
  "CLOSE UP - hand placing a settlement on the board",
  "WIDE - reactions around the table after the roll",
  "OTS - over a player's shoulder at their resource cards",
  "CLOSE UP - hands sorting resource cards",
  "WIDE - the finished board at the end of the night",
];
const shots = (flag("shots", "") || "").trim()
  ? flag("shots").split(",").map(s => s.trim()).filter(Boolean)
  : DEFAULT_SHOTS;


const repo = new Repo({
  network: [new BrowserWebSocketClientAdapter(relayUrl)],
  peerId: "sceneflow-seed",
  sharePolicy: async () => true,
});

console.error(`[seed] connecting to ${relayUrl}`);
const handle = repo.create();

handle.change(d => {
  d.snapshots = [];
  d.activeSketch = { strokes: [] };
  d.texts = [];
  d.images = [];
  d.comments = [];
  d.connectors = [];

  const ids = [];
  shots.forEach((shot, i) => {
    // Three across, wrapping — the same reading order a person lays
    // a board out in.
    const x = 100 + (i % 3) * 980;
    const y = 100 + Math.floor(i / 3) * 900;
    const id = uuid();
    ids.push(id);
    d.snapshots.push({
      id, x: f64(x), y: f64(y), z: i,
      width: f64(800), height: f64(600),
      strokes: toDocStrokes(sketch(shot, i + 1)),
    });
    // The slug line, tucked just under the frame so beats.js picks
    // it up as that frame's description.
    d.texts.push({
      id: uuid(), x: f64(x), y: f64(y + 340), z: i,
      text: new A.RawString(shot), fontSize: f64(24), color: 0x111111ff,
    });
  });

  // Arrows stating the sequence explicitly, so the run reports
  // orderedBy: connectors rather than falling back to position.
  for (let i = 0; i < ids.length - 1; i++) {
    d.connectors.push({ id: uuid(), from: ids[i], to: ids[i + 1] });
  }
});

await handle.whenReady();

// Stay connected. An Automerge relay routes between peers; a seeding
// process that creates a document and immediately exits can leave
// the board unreachable, which surfaces later as a 60-second timeout
// with no explanation. Holding the connection open is also what a
// real device does — this script is standing in for an iPad.
await new Promise(r => setTimeout(r, 3000));

console.error(`[seed] created a ${shots.length}-beat board and holding the connection open`);
console.error(`[seed] in another terminal:  npm run cut -- ${handle.documentId}`);
console.error(`[seed] Ctrl-C here once the app has opened the board at least once.\n`);
console.log(handle.documentId);

if (args.includes("--exit")) process.exit(0);
process.stdin.resume();

