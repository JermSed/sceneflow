// Sceneflow's sync relay — a thin, observable wrapper around the same
// pieces `@automerge/automerge-repo-sync-server` uses (Repo +
// NodeWSServerAdapter + NodeFS storage). We run our own copy for one
// reason: to LOG the traffic, so demos and debugging can show changes
// flowing through the relay in real time.
//
//   [sync] peer connected: 2f9a1c…
//   [sync] 2f9a1c… → storage-server sync 4kSJt2Qn… (1.4 KB)
//
// The logging is a passive tap: we attach our own 'message' listener
// on each WebSocket alongside the adapter's, decode just the CBOR
// envelope (type / sender / target / documentId), and never touch the
// payload. The relay remains exactly as dumb as before — it stores
// and forwards; it still can't read a board.

import fs from "node:fs";
import os from "node:os";
import { WebSocketServer } from "ws";
import { Repo } from "@automerge/automerge-repo";
import { NodeWSServerAdapter } from "@automerge/automerge-repo-network-websocket";
import { NodeFSStorageAdapter } from "@automerge/automerge-repo-storage-nodefs";
import { decode } from "cbor-x";

const PORT = process.env.PORT !== undefined ? parseInt(process.env.PORT) : 3030;
const DATA_DIR = process.env.DATA_DIR ?? ".amrg";
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR);

const wss = new WebSocketServer({ port: PORT });

const short = id => (id ? String(id).slice(0, 8) + "…" : "?");
const kb = n => (n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`);

wss.on("connection", socket => {
  let who = "unknown-peer";
  socket.on("message", data => {
    try {
      const msg = decode(new Uint8Array(data));
      switch (msg.type) {
        case "join":
          who = msg.senderId;
          console.log(`peer connected: ${who}`);
          break;
        case "sync":
        case "request":
          // The payload (msg.data) is the opaque Automerge sync
          // bytes — heads, Bloom filter, and/or change chunks.
          console.log(
            `${short(msg.senderId)} → ${short(msg.targetId)} ` +
            `${msg.type} doc ${short(msg.documentId)} (${kb(data.byteLength)})`);
          break;
        case "ephemeral":
          // Not used today (presence rides its own relay) but log
          // it if it ever shows up, so nothing passes invisibly.
          console.log(`${short(msg.senderId)} ephemeral (${kb(data.byteLength)})`);
          break;
        // 'peer' (our handshake reply) and anything else: quiet.
      }
    } catch {
      console.log(`unparseable message (${kb(data.byteLength ?? 0)})`);
    }
  });
  socket.on("close", () => console.log(`peer disconnected: ${who}`));
});

// Same config as the stock server: storage peer, shares nothing
// proactively — clients ask for documents by ID.
new Repo({
  network: [new NodeWSServerAdapter(wss)],
  storage: new NodeFSStorageAdapter(DATA_DIR),
  peerId: `storage-server-${os.hostname()}`,
  sharePolicy: async () => false,
});

console.log(`Listening on port ${PORT} (logging relay)`);
