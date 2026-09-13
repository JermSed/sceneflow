// render-preview.js — render a LIVE board to a PNG so a human can
// compare the agent's view of the board against the app's.
//
//   node scripts/render-preview.js <documentId> [out.png]
//
// Needs the relay up and the board announced (open it in the app
// once), exactly like running the agent itself.

import { writeFileSync } from "node:fs";
import { Repo } from "@automerge/automerge-repo";
import { BrowserWebSocketClientAdapter } from "@automerge/automerge-repo-network-websocket";
import { renderBoardPNG } from "../src/render.js";

const [docArg, outArg] = process.argv.slice(2);
if (!docArg) {
  console.error("usage: node scripts/render-preview.js <documentId> [out.png]");
  process.exit(1);
}
const out = outArg ?? "board-preview.png";
const relay = process.env.SCENEFLOW_RELAY ?? "ws://localhost:3030";

const repo = new Repo({
  network: [new BrowserWebSocketClientAdapter(relay)],
  peerId: "sceneflow-render-preview",
  sharePolicy: async () => true,
});

const handle = repo.find(docArg);
await handle.whenReady();
const rendered = renderBoardPNG(handle.docSync(), null);
if (!rendered) {
  console.log("board has nothing visual to render");
  process.exit(0);
}
writeFileSync(out, rendered.png);
console.log(`wrote ${out} (${rendered.width}x${rendered.height}, ${rendered.png.length} bytes)`);
process.exit(0);
