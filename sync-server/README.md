# Sceneflow sync server

Local Automerge sync relay for development. A thin wrapper around
[`@automerge/automerge-repo-sync-server`](https://www.npmjs.com/package/@automerge/automerge-repo-sync-server)
— the relay forwards opaque change blobs between Sceneflow clients
and does not understand the document model.

## Run

```sh
cd sync-server
npm install
npm start
```

This listens on `ws://localhost:3030` by default. The Swift client
defaults to that URL.

Document blobs are persisted under `./.amrg/` (created on first run,
git-ignored). Delete that directory to reset relay state.

## Configuration

| Env var      | Default   | Purpose                              |
| ------------ | --------- | ------------------------------------ |
| `PORT`       | `3030`    | TCP port to listen on                |
| `DATA_DIR`   | `.amrg`   | Where the relay persists blobs       |

Example: `PORT=4040 DATA_DIR=/tmp/sceneflow-relay npm start`

## Health check

Once running, `GET http://localhost:3030/` returns a small text
acknowledgement — useful for confirming the relay is up without
opening a WebSocket.
