// Minimal presence broadcast relay.
//
// Sceneflow runs this alongside @automerge/automerge-repo-sync-server
// because automerge-repo-swift 0.3.2 stubs out its ephemeral-message
// receive path (logs "UNIMPLEMENTED EPHEMERAL MESSAGE PASSING" and
// drops the message). Until upstream wires that up, presence cursors
// and live-stroke previews travel on this side channel instead.
//
// Protocol:
//   - Plain WebSocket on ws://localhost:3031 (override with PRESENCE_PORT).
//   - Whatever bytes a client sends are forwarded verbatim to every
//     OTHER connected client. No state, no auth, no per-board routing
//     here — the Swift side encodes the documentId in its JSON
//     payload and filters on receive.
//
// Why no per-board fan-out in the server? Two reasons. (1) Keep the
// server brain-dead simple so the relay never becomes a place we
// have to reason about. (2) Bandwidth is fine at the scale we care
// about (a handful of peers per board, ~30 msg/sec each).

import { WebSocketServer } from "ws"

const PORT = Number.parseInt(process.env.PRESENCE_PORT ?? "3031", 10)

const wss = new WebSocketServer({ port: PORT })

wss.on("listening", () => {
  console.log(`presence relay listening on ws://localhost:${PORT}`)
})

wss.on("connection", (ws, req) => {
  const peer = `${req.socket.remoteAddress}:${req.socket.remotePort}`
  console.log(`presence: connected ${peer} (${wss.clients.size} total)`)

  ws.on("message", (data, isBinary) => {
    for (const client of wss.clients) {
      if (client !== ws && client.readyState === ws.OPEN) {
        client.send(data, { binary: isBinary })
      }
    }
  })

  ws.on("close", () => {
    console.log(`presence: disconnected ${peer} (${wss.clients.size} left)`)
  })
})
