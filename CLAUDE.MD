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
- **Sync server:** a thin relay (Automerge's existing JS sync server). It forwards
  opaque change blobs; it does not understand the document.
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
├── snapshots: [ Snapshot ]                 // the spatial field of captured frames
│     └── Snapshot { id, x, y, z, strokes }  // strokes are FROZEN at capture time
└── activeSketch
      └── strokes: [ Stroke ]                // the one live, co-edited drawing surface
            └── Stroke { id, color, width, points: [Point] }
                  └── Point { x, y, pressure }
```

Matching Swift domain types:

```swift
struct CanvasDoc { var snapshots: [Snapshot]; var activeSketch: Sketch }
struct Snapshot: Identifiable { let id: UUID; var x, y: Double; var z: Int; var strokes: [Stroke] }
struct Sketch { var strokes: [Stroke] }
struct Stroke: Identifiable { let id: UUID; var color: UInt32; var width: Double; var points: [Point] }
struct Point { var x, y, pressure: Double }
```

Design rules baked into this model:
- Strokes and points are append-only lists → concurrent drawing merges cleanly.
- Snapshot x/y/z are scalars → rearranging resolves as last-write-wins.
- Snapshots are immutable once captured (they stop growing the change history).
- Always capture `pressure` even before rendering variable-width strokes.
- Batch pen points into a stroke; never write one Automerge change per pen point.

## Critical guardrails

- **Automerge API: do NOT rely on training memory.** automerge-swift is pre-1.0 and
  niche. Before writing any Automerge call, check the current API docs
  (https://automerge.org/automerge-swift) and the MeetingNotes sample
  (https://github.com/automerge/MeetingNotes). If unsure of a method, say so and verify.
- Do not reinvent networking. When we reach sync, adapt MeetingNotes' WebSocket / P2P
  networking code rather than building from scratch. (`automerge-repo-swift` is
  experimental and unstable — prefer MeetingNotes' own networking.)
- Keep the document model logic separate from SwiftUI views.
- Explain Automerge and CRDT/sync code as you write it — the author is learning this.

## Where we are

Phase 0: the headless document model. No UI, no networking yet.

## Phase roadmap

0. Headless document model + load/save + round-trip test.
1. Single-player SwiftUI canvas (draw, capture snapshot, arrange) on iPad + Mac.
2. Sync between two devices (adapt MeetingNotes networking); test the offline/reconnect case.
3. Many people + presence channel + a sync-server hub.

## Build/run

Use the XcodeBuildMCP tools to build for the simulator and report errors. Note: you
cannot see SwiftUI previews or the running UI — the author verifies anything visual.
