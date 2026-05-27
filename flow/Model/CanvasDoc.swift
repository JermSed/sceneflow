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

/// A typed text note placed anywhere on the spatial field.
/// Like a Figma text element — z lets users order them, color
/// matches the same `0xRRGGBBAA` pack as strokes.
///
/// Concurrent edits to `text` resolve last-write-wins under
/// Automerge. That's fine for short labels but if two peers
/// type in the same note simultaneously one set of characters
/// will lose. We can promote `text` to an Automerge Text type
/// later if that becomes a real problem.
struct TextNote: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var x: Double
    var y: Double
    var z: Int
    var text: String
    var fontSize: Double
    var color: UInt32
}

/// A pasted / dropped image placed anywhere on the spatial
/// field. Bytes live in the Automerge doc so they sync to peers
/// just like strokes — convenient, but pricey for big images.
/// We compress on insert (`ImageNote.compressedData(from:)`) to
/// keep the doc bounded.
///
/// `format` is a hint for decoding; we always store either
/// "png" or "jpeg" and resolve to platform image types at render.
struct ImageNote: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var x: Double
    var y: Double
    var z: Int
    var width: Double
    var height: Double
    var data: Data
    var format: String   // "png" | "jpeg"
}

/// The root of a board's Automerge document.
///
/// New top-level lists (`texts`, `images`) default to empty so
/// boards saved before they existed still decode. The on-disk
/// adopt path also seeds the underlying Automerge lists when
/// they're absent — see `BoardDocument.init(adopting:)`.
struct CanvasDoc: Codable, Hashable, Sendable {
    var snapshots: [Snapshot]
    var activeSketch: Sketch
    var texts: [TextNote] = []
    var images: [ImageNote] = []

    static let empty = CanvasDoc(
        snapshots: [],
        activeSketch: .empty,
        texts: [],
        images: [])
}
