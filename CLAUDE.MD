# Sceneflow

A native, offline-first, real-time collaborative canvas for cinematic planning.
Filmmakers co-edit a shared sketch surface, capture frozen "snapshots," and arrange
them spatially. Think Figma/Miro, but for cinematic storytelling, and built to work
on bad/no connectivity.

## Stack (decided — do not change without asking)

- **Client:** SwiftUI, multiplatform — one codebase for iPad and macOS. This is a
  regular **App**, NOT a document-based app. Do not use `DocumentGroup` or the
  file-based document architecture; Sceneflow is a synced shared space, not an
  open/save-files app. We manage our own list of boards and persistence.
- **Document / offline-first:** the `automerge-swift` package (Automerge CRDT). All
  collaborative state lives in an Automerge document so edits apply locally and merge
  automatically on reconnect.
- **Sync stack:** `automerge-repo-swift` (`AutomergeRepo` module) — `Repo`,
  `DocHandle`, and `WebSocketProvider`. This is the same path MeetingNotes
  actually takes today (an earlier draft of this file said MeetingNotes had
  its own networking; that's no longer true — they migrated to
  `automerge-repo-swift`). The library is still pre-1.0; insulate every
  `Repo` / `DocHandle` / provider call behind our model wrapper so a future
  bump touches one place.
- **Sync server:** `@automerge/automerge-repo-sync-server` running locally
  during development. Lives in `sync-server/` in this repo; `npm install
  && npm start` brings it up on `ws://localhost:3030`. It forwards opaque
  change blobs and does not understand the document.
- **Presence** (who's online, cursors, who's drawing): a SEPARATE ephemeral channel.
  Never store presence/cursor data in the Automerge document.

Rust was considered and dropped intentionally — pure Swift + Automerge is the chosen path.

## MVP scope — build only this first

Two (or more) people open a shared canvas, co-edit a sketch surface, capture frozen
snapshots, and arrange them in a spatial field — live, and tolerant of bad connectivity.

OUT OF SCOPE for v1 (do not build unless asked): timelines, emotional-beat mapping,
narrative-flow mapping, audio, threaded feedback, reference/mood-board import, a web
client, accounts/teams beyond the basics.

## Document model

One Automerge document per board, shaped as a tree of maps and lists:

```
root
├── snapshots: [ Snapshot ]                            // the spatial field of captured frames
│     └── Snapshot { id, x, y, z, width, height, strokes }   // editable; strokes list is open to edits
├── activeSketch                                       // the live, co-edited scratchpad
│     └── strokes: [ Stroke ]
│           └── Stroke { id, color, width, points: [Point] }
│                 └── Point { x, y, pressure }
├── texts: [ TextNote ]                                // free-floating text labels
│     └── TextNote { id, x, y, z, text, fontSize, color }
├── images: [ ImageNote ]                              // pasted / dropped images
│     └── ImageNote { id, x, y, z, width, height, data, format }
├── comments: [ Comment ]                              // Figma-style pinned discussion
│     └── Comment { id, x, y, z, authorPeerId, authorName, text, createdAt, isResolved, replyTo? }
└── connectors: [ Connector ]                          // arrows between snapshots
      └── Connector { id, from, to }
```

Matching Swift domain types:

```swift
struct CanvasDoc { var snapshots: [Snapshot]; var activeSketch: Sketch; var texts: [TextNote] = []; var images: [ImageNote] = []; var comments: [Comment] = []; var connectors: [Connector] = [] }
struct Snapshot: Identifiable { let id: UUID; var x, y: Double; var z: Int; var strokes: [Stroke]; var width: Double = 800; var height: Double = 600 }
struct Sketch { var strokes: [Stroke] }
struct Stroke: Identifiable { let id: UUID; var color: UInt32; var width: Double; var points: [Point] }
struct Point { var x, y, pressure: Double }
struct TextNote: Identifiable { let id: UUID; var x, y: Double; var z: Int; var text: String; var fontSize: Double; var color: UInt32 }
struct ImageNote: Identifiable { let id: UUID; var x, y: Double; var z: Int; var width, height: Double; var data: Data; var format: String }
struct Comment: Identifiable { let id: UUID; var x, y: Double; var z: Int; var authorPeerId: String; var authorName: String; var text: String; var createdAt: Date; var isResolved: Bool; var replyTo: UUID? = nil }
struct Connector: Identifiable { let id: UUID; var from: UUID; var to: UUID }
```

`texts`, `images`, `comments`, and `connectors` are forward-compat
additions: boards saved before they existed seed empty lists on
open (`BoardDocument.init(adopting:)`), so decoding old bytes
still succeeds. Image bytes live in the doc and ship through sync
— `ImageImport` does a downscale + JPEG/PNG re-encode on insert
to keep payloads manageable.

`TextNote.text` and `Comment.text` are plain Automerge strings,
so concurrent typing in the same note resolves last-write-wins —
fine for short labels and pin captions, but a known wart we can
promote to an Automerge `Text` type if shared editing in a single
note becomes a real workflow.

Design rules baked into this model:
- Strokes and points are append-only lists → concurrent drawing merges cleanly.
- Snapshot x/y/z are scalars → rearranging resolves as last-write-wins.
- Snapshots are editable across all peers — tap a snapshot to draw on it; the
  same merge semantics that protect the active sketch apply to each snapshot's
  strokes list. (Earlier drafts of this file called snapshots immutable; we
  changed that because cinematic planning routinely needs revisions of a beat
  after the initial sketch, and the doc model already supported it.)
- Always capture `pressure` even before rendering variable-width strokes.
- Batch pen points into a stroke; never write one Automerge change per pen point.

## Critical guardrails

- **Automerge / AutomergeRepo APIs: do NOT rely on training memory.** Both
  packages are pre-1.0. Before writing any call, check the current docs
  (https://automerge.org/automerge-swift,
  https://automerge.org/automerge-repo-swift) and the MeetingNotes sample
  (https://github.com/automerge/MeetingNotes). If unsure of a method, say
  so and verify against the actual checked-out source.
- Do not reinvent networking. Use `WebSocketProvider` from
  `automerge-repo-swift` and the off-the-shelf
  `@automerge/automerge-repo-sync-server` relay. Wrap every Repo / DocHandle
  / provider call behind our own type so a future package bump touches one
  place rather than the whole codebase.
- Keep the document model logic separate from SwiftUI views.
- Explain Automerge and CRDT/sync code as you write it — the author is learning this.

## Board assistant (agent/)

An AI peer that answers `@assistant` / `@claude` comments. It is
deliberately NOT a special integration: `agent/` is a headless Node
process that joins a board through the same relay with
`@automerge/automerge-repo` (`repo.find(<share token>)`), watches the
`comments` list, and appends reply comments. Collaboration semantics,
offline tolerance, and merge behavior extend to it with no new sync
code in the app.

- Replies carry `replyTo: <original comment id>` — dedupe is
  CRDT-native (the answered-marker lives in the doc itself), and the
  field doubles as future threading metadata. Old boards decode fine
  (optional field, absent → nil).
- Model calls go through `@anthropic-ai/sdk` in `agent/src/respond.js`
  (Claude Opus 4.8, adaptive thinking). `ASSISTANT_CANNED=1` skips the
  model for plumbing tests.
- **Cross-runtime schema contract:** the JS `next` API writes plain
  strings as Automerge Text objects, which Swift's `AutomergeDecoder`
  rejects for `String` fields — that would make the board fail to open
  in the app. Every string the agent writes must be `A.RawString`
  (rules live in `agent/src/schema.js`). Enforced by `npm test`
  (agent/) on the JS side and `flowTests/AgentInteropTests.swift` on
  the Swift side, which decodes fixture bytes from
  `agent/scripts/make-fixture.js`. Regenerate that fixture after any
  agent schema change.
- The model sees the actual drawings: `agent/src/render.js` renders
  the board to a PNG (SVG → resvg; mirrors FieldView geometry —
  elements centered at (x, y), frame strokes frame-local + clipped,
  connectors join frame centers, the asking pin ringed red) and it
  ships as a vision block alongside the text layout description
  (`describeBoard`). The active sketch's field position is per-device
  view state, so it renders as a separate labeled tile. Eyeball what
  the model sees: `node agent/scripts/render-preview.js <docId>`.

## Where we are

The MVP described above is shipped end-to-end against a local relay:
two or more devices open a shared board, co-edit the active sketch and
existing snapshot strokes, drop text/image notes, and rearrange the
spatial field — live, with presence (peer pill, live cursors, live
in-progress strokes) and offline tolerance via Automerge merge on
reconnect. Editor polish is the bulk of recent work: layered/cached
canvas for perf, pinch + cursor zoom, Figma-style comments, selection
+ delete + resize + connectors, right-click context menu, ESC /
background-tap to exit edit mode, share-board flow + identity sheet,
offline banner, undo/redo.

The remaining gaps to call v1 truly done are operational, not feature:
formal offline/reconnect testing across two real devices, behavior on
large boards and large image payloads through sync, and a non-localhost
relay story if peers should reach each other off-LAN.

## Phase roadmap

0. Headless document model + load/save + round-trip test. ✅
1. Single-player SwiftUI canvas (draw, capture snapshot, arrange) on iPad + Mac. ✅
2. Sync between two devices via `automerge-repo-swift` + local sync-server. ✅
3. Many people + presence channel (cursors, live strokes, peer pill) + share flow. ✅
4. Harden sync: explicit offline/reconnect tests on real devices, large-board and
   image-payload behavior, conflict cases on concurrent snapshot edits.
5. Hosted relay + board discovery beyond localhost share URLs; decide on light
   accounts vs. anonymous-with-share-link for v1.

## Build/run

Use the XcodeBuildMCP tools to build for the simulator and report errors. Note: you
cannot see SwiftUI previews or the running UI — the author verifies anything visual.
