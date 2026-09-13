// cut-cli.js — run one cut against a board and exit.
//
// The watcher in index.js is how the agent behaves in production: it
// sits on the board and reacts to a pinned comment. This is the same
// run, invoked directly, which is what you want for a demo, for CI,
// and for debugging a single stage without typing a comment into an
// iPad. It prints the full report as JSON on stdout so it composes
// with other tools.
//
//   node src/cut-cli.js <documentId> [--folder "Sceneflow Footage"]
//                                    [--list "Shoot List"]
//                                    [--project Sceneflow]
//                                    [--dry] [--no-grade] [--no-comment]

import { Repo } from "@automerge/automerge-repo";
import { BrowserWebSocketClientAdapter } from "@automerge/automerge-repo-network-websocket";
import { AGENT_PEER_ID, makeReplyComment } from "./schema.js";
import { runCut, reportToComment, DEFAULTS } from "./cut/run.js";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? fallback : args[i + 1];
};
const has = name => args.includes(`--${name}`);
// The first bare word that isn't the value of a preceding flag.
const VALUELESS = new Set(["--dry", "--no-comment", "--no-grade"]);
const docArg = (() => {
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("--")) { if (!VALUELESS.has(args[i])) i++; continue; }
    return args[i];
  }
  return null;
})();

if (!docArg) {
  console.error("usage: node src/cut-cli.js <documentId> [--name 'Board name'] [--folder NAME] [--list NAME] [--project NAME] [--dry] [--no-grade] [--no-comment]");
  process.exit(1);
}

const relayUrl = flag("relay", process.env.SCENEFLOW_RELAY ?? "ws://localhost:3030");
const repo = new Repo({
  network: [new BrowserWebSocketClientAdapter(relayUrl)],
  peerId: AGENT_PEER_ID,
  sharePolicy: async () => true,
});

console.error(`[cut] connecting to ${relayUrl}, board ${docArg}`);
const handle = repo.find(docArg);
handle.on("unavailable", () =>
  console.error("[cut] board not on the relay yet — open it in the app once while online."));
await handle.whenReady();

const report = await runCut(handle.docSync(), {
  docId: docArg,
  // A share token makes a terrible timeline name. Let the caller give
  // the board a name; otherwise fall back to something an editor
  // opening Resolve tomorrow can read.
  boardName: flag("name", process.env.SCENEFLOW_BOARD_NAME ?? "Sceneflow board"),
  driveFolder: flag("folder", DEFAULTS.driveFolder),
  todoistProject: flag("list", DEFAULTS.todoistProject),
  resolveProject: flag("project", DEFAULTS.resolveProject),
  dryRun: has("dry"),
  grade: !has("no-grade"),
  onLog: m => console.error(`[cut] ${m}`),
});

// Post the report back to the board, so the run is visible where the
// work is — same as the watcher does. Skippable for CI runs.
if (!has("no-comment")) {
  const anchor = {
    id: "00000000-0000-0000-0000-000000000000",
    x: 0, y: 0, z: 0,
  };
  handle.change(d => {
    if (!d.comments) d.comments = [];
    d.comments.push(makeReplyComment(anchor, reportToComment(report)));
  });
  // Let the change flush to the relay before we exit.
  await new Promise(r => setTimeout(r, 1500));
}

console.log(JSON.stringify(report, null, 2));
process.exit(report.ok ? 0 : 1);
