//
//  CanvasDoc.swift
//  flow
//
//  Phase 0 — the headless document model.
//
//  This is the Swift mirror of the Automerge document tree described in
//  CLAUDE.md. Everything here is a plain `Codable` value type so the
//  `AutomergeEncoder` / `AutomergeDecoder` pair in automerge-swift can map
//  it into / out of a CRDT document automatically.
//
//  Design rules (from CLAUDE.md):
//   • `strokes` and `points` are append-only lists → concurrent drawing
//     merges cleanly when Automerge syncs lists.
//   • `Snapshot.x` / `y` / `z` are plain scalars → rearranging a snapshot
//     in the spatial field resolves as last-write-wins, which is exactly
//     what we want (the most recent placement sticks).
//   • Snapshots are immutable once captured. Nothing in this type prevents
//     mutation, but capture flows should never edit a `Snapshot.strokes`
//     after the snapshot is added to `CanvasDoc.snapshots`.
//   • `pressure` is always captured even before we render variable-width
//     strokes — cheaper to record now than to migrate the doc later.
//

import Foundation

/// A single pen sample. `pressure` is 0…1 (or whatever the input device
/// reports); store it even when rendering ignores it, so future variable-
/// width rendering doesn't require a doc migration.
struct Point: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var pressure: Double
}

/// One continuous pen stroke. `points` is append-only at the Automerge
/// layer — that's what makes concurrent drawing merge cleanly.
///
/// `color` is packed as 0xRRGGBBAA so it survives as a single Automerge
/// scalar. `UInt32` round-trips through automerge-swift as a `Uint` scalar.
struct Stroke: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var color: UInt32
    var width: Double
    var points: [Point]
}

/// The one live, co-edited drawing surface. There is exactly one of these
/// per board (at `root.activeSketch`).
struct Sketch: Codable, Hashable, Sendable {
    var strokes: [Stroke]

    static let empty = Sketch(strokes: [])
}

/// A frozen frame captured from the live sketch and placed in the spatial
/// field. `x` / `y` position it on the field; `z` is a draw-order index so
/// users can bring-to-front / send-to-back without fighting Automerge over
/// list ordering.
struct Snapshot: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var x: Double
    var y: Double
    var z: Int
    var strokes: [Stroke]
}

/// The root of a board's Automerge document.
struct CanvasDoc: Codable, Hashable, Sendable {
    var snapshots: [Snapshot]
    var activeSketch: Sketch

    static let empty = CanvasDoc(snapshots: [], activeSketch: .empty)
}
