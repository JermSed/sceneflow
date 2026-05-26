//
//  BoardDocument.swift
//  flow
//
//  Wraps an `Automerge.Document` so the rest of the app never has to talk
//  to the CRDT API directly. Two reasons we want this seam:
//
//   1. CLAUDE.md says automerge-swift is pre-1.0 and the API can shift.
//      Keeping every Automerge call inside this file means a future
//      version bump touches one place, not the whole codebase.
//
//   2. Views must stay free of CRDT concepts. They see a plain
//      `CanvasDoc` value; this type handles encode / decode / persist /
//      merge against the underlying `Automerge.Document`.
//
//  Phase 1 — fine-grained mutation API.
//
//  Phase 0 used `AutomergeEncoder.encode(wholeTree)` to seed and rewrite
//  the doc. That works for a round-trip test but defeats the CRDT: if
//  two clients both re-encode the whole tree after each edit, lists are
//  replaced wholesale and concurrent appends overwrite each other
//  instead of merging.
//
//  Phase 1 mutates the doc at *paths* using `Document.put` / `insert` /
//  `putObject` / `insertObject`. This is what makes the model's
//  "append-only lists merge cleanly" promise actually true on the wire.
//
//  Verified against automerge-swift 0.7.2 source (locally checked out
//  in DerivedData), not training memory:
//   • `Document.put(obj:, key:, value: ScalarValue)` for scalars on maps
//   • `Document.putObject(obj:, key:, ty: ObjType) -> ObjId` for nested
//     maps / lists on maps
//   • `Document.insertObject(obj:, index:, ty:) -> ObjId` for appending
//     a map / list at the end of a list (use `length(obj:)` as index)
//   • `Document.get(obj:, key:) -> Value?` returns `.Object(ObjId, ObjType)`
//     for containers — pattern match to extract the nested ObjId
//   • `ObjId.ROOT` is the document root
//   • `Document` already conforms to `ObservableObject` and emits both
//     `objectWillChange` and an `objectDidChange` Combine publisher
//
//  Note on identifiers (`UUID`): Automerge has no native UUID scalar.
//  We store them as `.String(uuid.uuidString)`. String equality is
//  stable across save / load round-trips and across peers.
//

import Foundation
import Automerge

/// Errors thrown when the underlying Automerge document doesn't match
/// the shape we expect. These should never fire in normal operation;
/// they're a guard against a corrupted or wrong-schema document.
enum BoardError: Error {
    case malformedDocument(String)
}

/// Opaque handle to an in-progress stroke. Returned by `beginStroke`
/// and passed to `appendPoint` so per-sample writes don't have to
/// re-walk the document tree on every pen event.
///
/// The handle wraps the Automerge `ObjId`s for the stroke's map and
/// its `points` list. Those ObjIds are stable for the life of the
/// document (Automerge never reassigns them), so the handle stays
/// valid as long as the stroke isn't deleted.
struct StrokeHandle: Sendable {
    fileprivate let strokeId: ObjId
    fileprivate let pointsId: ObjId
}

/// A board's collaborative document. Holds the live `Automerge.Document`
/// plus typed mutation methods for the rest of the app.
///
/// Thread safety: `Automerge.Document` is `@unchecked Sendable` and
/// guarded internally by a recursive lock, but a sequence of calls is
/// NOT atomic across the boundary. Treat a `BoardDocument` as owned
/// by one actor / thread at a time; `BoardStore` formalizes that with
/// `@MainActor`.
final class BoardDocument {

    /// The underlying CRDT. Exposed `internal` (not `private`) so
    /// `BoardStore` can subscribe to `objectDidChange` and future sync
    /// code can hand it to a Repo — but no view code should reach in.
    let doc: Automerge.Document

    // MARK: - Init

    /// Create a fresh board: an empty `snapshots` list and an empty
    /// `activeSketch.strokes` list, both reachable from `.ROOT`.
    init() throws {
        self.doc = Automerge.Document()
        try Self.seedRoot(in: doc)
    }

    /// Load a board from saved bytes (from disk, or eventually a sync peer).
    ///
    /// Decodes once at load time as a sanity check so a corrupt or
    /// wrong-schema file fails loudly here instead of mid-edit.
    init(data: Data) throws {
        self.doc = try Automerge.Document(data)
        _ = try AutomergeDecoder(doc: doc).decode(CanvasDoc.self)
    }

    /// Wrap an existing `Automerge.Document` — used when the document
    /// is owned by an `AutomergeRepo.Repo` and we want the Repo's
    /// sync to fold incoming changes into the same document our UI
    /// is observing. The caller is responsible for having seeded the
    /// root structure already (or for handing us a peer-fetched doc
    /// that already has it).
    ///
    /// If the doc looks empty (no `activeSketch` map yet), we seed it
    /// here. That makes this safe to call right after `repo.create()`
    /// returns a blank handle.
    init(adopting doc: Automerge.Document) throws {
        self.doc = doc
        if try doc.get(obj: .ROOT, key: "activeSketch") == nil {
            try Self.seedRoot(in: doc)
        } else {
            // Sanity-check that the existing tree decodes to our model.
            _ = try AutomergeDecoder(doc: doc).decode(CanvasDoc.self)
        }
    }

    /// Build the root shape with the low-level API rather than
    /// `AutomergeEncoder.encode(CanvasDoc.empty)`. Keeping seeding
    /// and editing on the same code path means there's one schema
    /// definition, not two that could drift.
    private static func seedRoot(in doc: Automerge.Document) throws {
        _ = try doc.putObject(obj: .ROOT, key: "snapshots", ty: .List)
        let sketchId = try doc.putObject(obj: .ROOT, key: "activeSketch", ty: .Map)
        _ = try doc.putObject(obj: sketchId, key: "strokes", ty: .List)
    }

    // MARK: - Snapshotting the Swift value

    /// Pull the whole current state out of the CRDT as a plain Swift
    /// value. Views and tests use this; they never see the doc itself.
    ///
    /// O(n) over the doc — fine for tests and for repainting after a
    /// merge, but not something to call inside a pen-input loop.
    func snapshot() throws -> CanvasDoc {
        try AutomergeDecoder(doc: doc).decode(CanvasDoc.self)
    }

    // MARK: - Persistence

    /// Serialize the full change history to a `Data` blob. Does NOT
    /// throw in automerge-swift 0.7.2.
    func save() -> Data {
        doc.save()
    }

    // MARK: - Sync (used in Phase 2)

    /// Fold another board's changes into this one. Automerge resolves
    /// conflicts per the rules baked into the document model:
    /// append-only lists merge by concatenation in causal order;
    /// scalars resolve last-write-wins.
    func merge(_ other: BoardDocument) throws {
        try doc.merge(other: other.doc)
    }

    // MARK: - Mutation API

    /// Start a new stroke on the live sketch. Returns a handle whose
    /// ObjIds are cached so subsequent `appendPoint` calls skip the
    /// tree walk — important because pen samples fire ~60–120Hz.
    @discardableResult
    func beginStroke(id: UUID = UUID(), color: UInt32, width: Double) throws -> StrokeHandle {
        let strokesList = try activeStrokesId()
        let endIndex = doc.length(obj: strokesList)
        let strokeMap = try doc.insertObject(obj: strokesList, index: endIndex, ty: .Map)
        try doc.put(obj: strokeMap, key: "id", value: .String(id.uuidString))
        try doc.put(obj: strokeMap, key: "color", value: .Uint(UInt64(color)))
        try doc.put(obj: strokeMap, key: "width", value: .F64(width))
        let pointsList = try doc.putObject(obj: strokeMap, key: "points", ty: .List)
        return StrokeHandle(strokeId: strokeMap, pointsId: pointsList)
    }

    /// Append a single pen sample to the stroke identified by `handle`.
    /// Hot path: keep this tight.
    ///
    /// Kept around for tests and any future "stream a stroke live"
    /// affordance (e.g. presence-channel hover-preview). Real drawing
    /// uses `commitStroke` so we only emit one Automerge change per
    /// stroke — see CLAUDE.md: *batch pen points into a stroke; never
    /// write one Automerge change per pen point.*
    func appendPoint(to handle: StrokeHandle, _ point: Point) throws {
        let endIndex = doc.length(obj: handle.pointsId)
        let pointMap = try doc.insertObject(obj: handle.pointsId, index: endIndex, ty: .Map)
        try doc.put(obj: pointMap, key: "x", value: .F64(point.x))
        try doc.put(obj: pointMap, key: "y", value: .F64(point.y))
        try doc.put(obj: pointMap, key: "pressure", value: .F64(point.pressure))
    }

    /// Write a finished stroke into the active sketch in one go.
    ///
    /// This is what real drawing uses. The whole stroke — id, color,
    /// width, and every point — becomes a single Automerge change.
    /// That keeps the change-log compact, keeps the SwiftUI render
    /// loop from re-decoding the entire doc per pen sample, and
    /// (under sync) keeps peers from being chatted at 60Hz.
    func commitStroke(_ stroke: Stroke) throws {
        let strokesList = try activeStrokesId()
        let endIndex = doc.length(obj: strokesList)
        try writeStroke(into: strokesList, at: endIndex, stroke: stroke)
    }

    /// Freeze the live sketch into a new snapshot placed at `(x, y, z)`
    /// in the spatial field, then clear the live sketch so the next
    /// stroke starts on a blank canvas.
    ///
    /// Concurrent-capture semantics: if two clients capture at the
    /// same time, both snapshots get appended (list CRDT) and the
    /// live sketch ends up cleared (each delete is a delete on the
    /// same items). The visible result is "both captures happened,
    /// next stroke starts clean" — which is what users would expect.
    @discardableResult
    func captureSnapshot(at x: Double, y: Double, z: Int, id: UUID = UUID()) throws -> UUID {
        // Read the active strokes as a Swift value. We then re-serialize
        // them into a fresh snapshot map. We do NOT just move ObjIds:
        // the snapshot must be an independent copy so future edits to
        // the live sketch don't mutate the captured frame.
        let active = try snapshot().activeSketch.strokes

        let snapshotsList = try snapshotsListId()
        let endIndex = doc.length(obj: snapshotsList)
        let snapshotMap = try doc.insertObject(obj: snapshotsList, index: endIndex, ty: .Map)
        try doc.put(obj: snapshotMap, key: "id", value: .String(id.uuidString))
        try doc.put(obj: snapshotMap, key: "x", value: .F64(x))
        try doc.put(obj: snapshotMap, key: "y", value: .F64(y))
        try doc.put(obj: snapshotMap, key: "z", value: .Int(Int64(z)))
        let snapshotStrokes = try doc.putObject(obj: snapshotMap, key: "strokes", ty: .List)
        for (i, stroke) in active.enumerated() {
            try writeStroke(into: snapshotStrokes, at: UInt64(i), stroke: stroke)
        }

        // Clear the live sketch. `splice` with delete = length and no
        // values is the one-call way to empty a list.
        let activeStrokes = try activeStrokesId()
        let activeLength = doc.length(obj: activeStrokes)
        if activeLength > 0 {
            try doc.splice(obj: activeStrokes,
                           start: 0,
                           delete: Int64(activeLength),
                           values: [])
        }

        return id
    }

    /// Reposition a snapshot in the spatial field. Last-write-wins on
    /// `x` and `y` — exactly what we want for drag-to-move.
    func moveSnapshot(id: UUID, to x: Double, y: Double) throws {
        let snapshotsList = try snapshotsListId()
        let count = doc.length(obj: snapshotsList)
        let target = id.uuidString
        for i in 0..<count {
            guard case let .Object(snapMap, .Map) = try doc.get(obj: snapshotsList, index: i)
            else { continue }
            guard case let .Scalar(.String(idString)) = try doc.get(obj: snapMap, key: "id")
            else { continue }
            if idString == target {
                try doc.put(obj: snapMap, key: "x", value: .F64(x))
                try doc.put(obj: snapMap, key: "y", value: .F64(y))
                return
            }
        }
        throw BoardError.malformedDocument("moveSnapshot: no snapshot with id \(target)")
    }

    // MARK: - Internal helpers

    /// Write a `Stroke` value into an existing strokes list at `index`.
    /// Used by `captureSnapshot` to copy active strokes into a frame.
    private func writeStroke(into listId: ObjId, at index: UInt64, stroke: Stroke) throws {
        let strokeMap = try doc.insertObject(obj: listId, index: index, ty: .Map)
        try doc.put(obj: strokeMap, key: "id", value: .String(stroke.id.uuidString))
        try doc.put(obj: strokeMap, key: "color", value: .Uint(UInt64(stroke.color)))
        try doc.put(obj: strokeMap, key: "width", value: .F64(stroke.width))
        let pointsList = try doc.putObject(obj: strokeMap, key: "points", ty: .List)
        for (j, point) in stroke.points.enumerated() {
            let pointMap = try doc.insertObject(obj: pointsList, index: UInt64(j), ty: .Map)
            try doc.put(obj: pointMap, key: "x", value: .F64(point.x))
            try doc.put(obj: pointMap, key: "y", value: .F64(point.y))
            try doc.put(obj: pointMap, key: "pressure", value: .F64(point.pressure))
        }
    }

    /// Resolve `root.activeSketch.strokes` to its ObjId. Looked up
    /// fresh on each `beginStroke` rather than cached: cheap (two
    /// `get` calls) and avoids stale ObjIds if a future code path
    /// ever replaces the root tree (e.g. loading a different doc
    /// into the same wrapper).
    private func activeStrokesId() throws -> ObjId {
        guard case let .Object(sketchId, .Map) = try doc.get(obj: .ROOT, key: "activeSketch")
        else { throw BoardError.malformedDocument("root.activeSketch is not a map") }
        guard case let .Object(strokesId, .List) = try doc.get(obj: sketchId, key: "strokes")
        else { throw BoardError.malformedDocument("activeSketch.strokes is not a list") }
        return strokesId
    }

    /// Resolve `root.snapshots` to its ObjId.
    private func snapshotsListId() throws -> ObjId {
        guard case let .Object(id, .List) = try doc.get(obj: .ROOT, key: "snapshots")
        else { throw BoardError.malformedDocument("root.snapshots is not a list") }
        return id
    }
}
