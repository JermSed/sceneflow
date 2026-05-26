//
//  BoardStore.swift
//  flow
//
//  The SwiftUI-facing wrapper around `BoardDocument`. Views observe
//  this; they never touch the Automerge document directly.
//
//  Why a separate type, not "just use BoardDocument"?
//
//   • `Automerge.Document` is already `ObservableObject`, but exposing
//     it to views would leak CRDT concepts (ObjIds, ScalarValue,
//     change-hash heads) into the UI layer. CLAUDE.md is explicit:
//     "Keep the document model logic separate from SwiftUI views."
//
//   • Views want a plain `CanvasDoc` value to render. `BoardStore`
//     republishes a fresh snapshot every time the underlying doc
//     changes — locally OR via a future sync merge.
//
//  Performance note:
//
//   Re-decoding the entire `CanvasDoc` on every pen point is O(n) over
//   the doc. At Phase 1 with one client and a handful of strokes that's
//   fine — measured: the round-trip test populates a small doc and
//   completes in <100ms. If the canvas grows large (thousands of
//   points), the right fix is to subscribe to `doc.objectDidChange`,
//   diff against `doc.heads()`, and apply patches to the published
//   `CanvasDoc` rather than re-snapshotting. Hold that optimization
//   until a profile shows it's needed; premature work here would
//   couple the store to Automerge's patch shape.
//

import Foundation
import Combine
import Automerge

/// SwiftUI-observable wrapper around a `BoardDocument`. Owns the
/// document, exposes the current state as `canvas`, and forwards
/// mutation calls to the underlying CRDT.
///
/// `@MainActor` so SwiftUI can read `canvas` without warnings and so
/// the (not-individually-atomic) sequence of Automerge calls inside
/// each mutation runs on a single thread.
@MainActor
final class BoardStore: ObservableObject {

    /// The current state of the board. Refreshed after every local
    /// mutation and (in Phase 2) after every merged sync change.
    @Published private(set) var canvas: CanvasDoc

    private let board: BoardDocument
    private var changeSink: AnyCancellable?

    // MARK: - Init

    /// Open an empty board. Throws only if Automerge can't allocate
    /// the seed structures, which in practice means OOM.
    init() throws {
        let board = try BoardDocument()
        self.board = board
        self.canvas = try board.snapshot()
        subscribeToDocChanges()
    }

    /// Open a board from saved bytes.
    init(data: Data) throws {
        let board = try BoardDocument(data: data)
        self.board = board
        self.canvas = try board.snapshot()
        subscribeToDocChanges()
    }

    /// Wrap an `Automerge.Document` that is owned by a Repo (so that
    /// sync messages coming in over the network update the same doc
    /// the UI observes). The board is adopted in-place and seeded if
    /// the root tree isn't already there.
    init(adopting doc: Automerge.Document) throws {
        let board = try BoardDocument(adopting: doc)
        self.board = board
        self.canvas = try board.snapshot()
        subscribeToDocChanges()
    }

    /// Subscribe to the Automerge doc's "did change" publisher so that
    /// non-local edits (Phase 2 sync merges) also trigger a republish.
    /// Local mutations also fire this, which is harmless — we just
    /// re-snapshot once more.
    private func subscribeToDocChanges() {
        changeSink = board.doc.objectDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.refresh()
            }
    }

    private func refresh() {
        // Decode failure here would mean the doc went into a state the
        // model can't represent. Surface it loudly rather than silently
        // showing stale UI — easier to debug.
        do {
            canvas = try board.snapshot()
        } catch {
            assertionFailure("BoardStore failed to snapshot: \(error)")
        }
    }

    // MARK: - Persistence

    /// Bytes for the full change history. Caller is responsible for
    /// writing them somewhere durable. Phase 1 callers: a small disk
    /// store under app support. Phase 2: also the sync transport.
    func save() -> Data {
        board.save()
    }

    // MARK: - Mutation passthroughs

    /// Start a new stroke. The returned handle is what the gesture
    /// recognizer holds onto for the duration of one finger-down /
    /// pencil-down → up cycle.
    func beginStroke(id: UUID = UUID(), color: UInt32, width: Double) throws -> StrokeHandle {
        try board.beginStroke(id: id, color: color, width: width)
    }

    /// Append a pen sample to an in-progress stroke.
    func appendPoint(to handle: StrokeHandle, _ point: Point) throws {
        try board.appendPoint(to: handle, point)
    }

    /// Freeze the live sketch into a snapshot at `(x, y, z)` and
    /// clear the sketch surface.
    @discardableResult
    func captureSnapshot(at x: Double, y: Double, z: Int, id: UUID = UUID()) throws -> UUID {
        try board.captureSnapshot(at: x, y: y, z: z, id: id)
    }

    /// Drag a placed snapshot to a new field coordinate.
    func moveSnapshot(id: UUID, to x: Double, y: Double) throws {
        try board.moveSnapshot(id: id, to: x, y: y)
    }
}
