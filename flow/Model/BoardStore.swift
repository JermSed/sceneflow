//
//  BoardStore.swift
//  flow
//
//  The SwiftUI-facing wrapper around `BoardDocument`. Views observe
//  this; they never touch the Automerge document directly.
//
//  Owns the local undo / redo stack for this board. The stack is
//  intentionally LOCAL — every push happens here when the user
//  initiates a mutation. Edits that arrive via doc sync from a
//  peer don't go through these methods, so they don't pollute
//  the local history. That matches what feels right in a
//  collaborative tool: "undo" undoes what *I* did, not what we
//  collectively did.
//
//  Performance note (carried over from earlier): re-decoding the
//  entire `CanvasDoc` on every change is O(n) over the doc. For
//  Phase-1 sizes that's fine. The right fix when it stops being
//  fine is patch-based incremental updates — keep that out until
//  a profile says so.
//

import Foundation
import Combine
import Automerge

/// One undoable user-initiated mutation. Each variant carries
/// enough state to inverse-apply: a removed stroke remembers its
/// content so it can be re-added; a captured snapshot remembers
/// the strokes that were cleared from the active sketch so undo
/// can restore them.
///
/// Concurrency note: these actions are applied locally without
/// any CRDT-awareness. Peers see an undo as a normal forward
/// operation (a delete, a re-add, a re-capture), and their own
/// undo histories are independent of ours.
enum UndoableAction: Sendable {
    case strokeAdded(Stroke)
    case strokeRemoved(Stroke)
    case snapshotCaptured(snapshot: Snapshot, restoredStrokes: [Stroke])
    case snapshotMoved(id: UUID, from: CGPoint, to: CGPoint)
}

@MainActor
final class BoardStore: ObservableObject {

    @Published private(set) var canvas: CanvasDoc

    /// True when there's an action available to undo. Bound by
    /// toolbar buttons to disable/enable themselves.
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    private let board: BoardDocument
    private var changeSink: AnyCancellable?

    private var undoStack: [UndoableAction] = []
    private var redoStack: [UndoableAction] = []
    /// Cap to keep memory bounded on long sessions. 100 is plenty
    /// for individual stroke-grain undo; beyond that the user is
    /// arguably looking for "clear board" rather than "undo".
    private let maxStackDepth = 100

    // MARK: - Init

    init() throws {
        let board = try BoardDocument()
        self.board = board
        self.canvas = try board.snapshot()
        subscribeToDocChanges()
    }

    init(data: Data) throws {
        let board = try BoardDocument(data: data)
        self.board = board
        self.canvas = try board.snapshot()
        subscribeToDocChanges()
    }

    /// Wrap an `Automerge.Document` owned by a Repo (so sync
    /// updates land in the same doc the UI is observing).
    init(adopting doc: Automerge.Document) throws {
        let board = try BoardDocument(adopting: doc)
        self.board = board
        self.canvas = try board.snapshot()
        subscribeToDocChanges()
    }

    private func subscribeToDocChanges() {
        changeSink = board.doc.objectDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
    }

    private func refresh() {
        do {
            canvas = try board.snapshot()
        } catch {
            assertionFailure("BoardStore failed to snapshot: \(error)")
        }
    }

    // MARK: - Persistence

    func save() -> Data { board.save() }

    // MARK: - Mutations (local; each pushes onto undo stack)

    func beginStroke(id: UUID = UUID(), color: UInt32, width: Double) throws -> StrokeHandle {
        // Live point-by-point streaming uses begin/append. We
        // don't push undo entries for those — only the finished
        // stroke (via `commitStroke`) goes on the stack.
        try board.beginStroke(id: id, color: color, width: width)
    }

    func appendPoint(to handle: StrokeHandle, _ point: Point) throws {
        try board.appendPoint(to: handle, point)
    }

    func commitStroke(_ stroke: Stroke) throws {
        try board.commitStroke(stroke)
        push(.strokeAdded(stroke))
    }

    func removeActiveStroke(id: UUID) throws {
        // Capture the stroke before deleting so undo can put it
        // back exactly as it was.
        let removed = canvas.activeSketch.strokes.first(where: { $0.id == id })
        try board.removeActiveStroke(id: id)
        if let removed { push(.strokeRemoved(removed)) }
    }

    @discardableResult
    func captureSnapshot(at x: Double, y: Double, z: Int, id: UUID = UUID()) throws -> UUID {
        // Remember the strokes that will get cleared from the
        // active sketch — without them, undoing a capture would
        // leave the user staring at an empty board.
        let restored = canvas.activeSketch.strokes
        let snapId = try board.captureSnapshot(at: x, y: y, z: z, id: id)
        let snap = Snapshot(id: snapId, x: x, y: y, z: z, strokes: restored)
        push(.snapshotCaptured(snapshot: snap, restoredStrokes: restored))
        return snapId
    }

    func moveSnapshot(id: UUID, to x: Double, y: Double) throws {
        let from = canvas.snapshots.first(where: { $0.id == id })
            .map { CGPoint(x: $0.x, y: $0.y) }
        try board.moveSnapshot(id: id, to: x, y: y)
        if let from {
            push(.snapshotMoved(id: id, from: from, to: CGPoint(x: x, y: y)))
        }
    }

    // MARK: - Undo / redo

    func undo() {
        guard let action = undoStack.popLast() else { return }
        applyInverse(of: action)
        redoStack.append(action)
        updateStackFlags()
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        apply(action)
        undoStack.append(action)
        updateStackFlags()
    }

    /// Push a user-initiated action onto the undo stack. Any
    /// pending redo history is discarded — once the user takes a
    /// new action after undoing, the previously-undone branch is
    /// gone (standard editor behavior).
    private func push(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > maxStackDepth {
            undoStack.removeFirst(undoStack.count - maxStackDepth)
        }
        redoStack.removeAll()
        updateStackFlags()
    }

    private func updateStackFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Re-apply the original mutation (used by `redo`).
    private func apply(_ action: UndoableAction) {
        do {
            switch action {
            case .strokeAdded(let stroke):
                try board.commitStroke(stroke)
            case .strokeRemoved(let stroke):
                try board.removeActiveStroke(id: stroke.id)
            case .snapshotCaptured(let snapshot, _):
                // The restored strokes are already in the active
                // sketch (we undid the capture by putting them
                // back). Capturing again with the same id moves
                // them into the snapshot, just like the first time.
                _ = try board.captureSnapshot(
                    at: snapshot.x, y: snapshot.y, z: snapshot.z, id: snapshot.id)
            case .snapshotMoved(let id, _, let to):
                try board.moveSnapshot(id: id, to: to.x, y: to.y)
            }
        } catch {
            assertionFailure("redo failed: \(error)")
        }
    }

    /// Apply the inverse of a user action (used by `undo`).
    private func applyInverse(of action: UndoableAction) {
        do {
            switch action {
            case .strokeAdded(let stroke):
                try board.removeActiveStroke(id: stroke.id)
            case .strokeRemoved(let stroke):
                try board.commitStroke(stroke)
            case .snapshotCaptured(let snapshot, let restored):
                try board.removeSnapshot(id: snapshot.id)
                for stroke in restored {
                    try board.commitStroke(stroke)
                }
            case .snapshotMoved(let id, let from, _):
                try board.moveSnapshot(id: id, to: from.x, y: from.y)
            }
        } catch {
            assertionFailure("undo failed: \(error)")
        }
    }
}
