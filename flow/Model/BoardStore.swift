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
    case strokeAdded(Stroke, target: EditTarget)
    case strokeRemoved(Stroke, target: EditTarget)
    case snapshotCaptured(snapshot: Snapshot, restoredStrokes: [Stroke])
    case snapshotMoved(id: UUID, from: CGPoint, to: CGPoint)
    case textAdded(TextNote)
    case textRemoved(TextNote)
    case textMoved(id: UUID, from: CGPoint, to: CGPoint)
    /// Old + new versions captured at the moment the user
    /// committed an edit — used by undo/redo to swap them back.
    case textEdited(id: UUID, oldText: String, newText: String)
    case imageAdded(ImageNote)
    case imageRemoved(ImageNote)
    case imageMoved(id: UUID, from: CGPoint, to: CGPoint)
    case commentAdded(Comment)
    case commentRemoved(Comment)
    case commentMoved(id: UUID, from: CGPoint, to: CGPoint)
    case commentTextEdited(id: UUID, oldText: String, newText: String)
    case commentResolutionToggled(id: UUID, oldValue: Bool, newValue: Bool)
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

    /// When true, `refresh()` short-circuits — used to suppress
    /// the canvas re-decode during batched operations like
    /// `captureSnapshot` that fire thousands of Automerge changes
    /// in quick succession. A single explicit `refresh()` runs
    /// after the batch.
    private var suppressRefresh = false

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
        // Throttle the doc → canvas re-decode at ~60Hz. The
        // underlying publisher fires once per Automerge mutation;
        // for a captureSnapshot that's tens of thousands of
        // changes in a single tick, and re-decoding the full
        // CanvasDoc each time would crater the main thread.
        // 60Hz matches typical screen refresh — finer granularity
        // wouldn't be visible anyway. `latest: true` ensures the
        // most recent state is what we publish, not an arbitrary
        // earlier one.
        changeSink = board.doc.objectDidChange
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard !suppressRefresh else { return }
        do {
            canvas = try board.snapshot()
        } catch {
            assertionFailure("BoardStore failed to snapshot: \(error)")
        }
    }

    /// Run a closure that's going to fire many Automerge changes
    /// without letting each one re-decode the doc. One refresh
    /// runs at the end, syncing `canvas` to the final state.
    /// Used by `captureSnapshot` where a single user action
    /// produces tens of thousands of writes.
    private func withBatchedRefresh<T>(_ work: () throws -> T) rethrows -> T {
        suppressRefresh = true
        let result: T
        do {
            result = try work()
        } catch {
            suppressRefresh = false
            refresh()
            throw error
        }
        suppressRefresh = false
        refresh()
        return result
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

    func commitStroke(_ stroke: Stroke, to target: EditTarget = .activeSketch) throws {
        switch target {
        case .activeSketch:
            try board.commitStroke(stroke)
        case .snapshot(let snapshotId):
            try board.commitStrokeToSnapshot(snapshotId: snapshotId, stroke: stroke)
        }
        // Refresh immediately so the local user sees the stroke
        // land on the next frame instead of waiting for the
        // throttled subscription. The throttle is there to bound
        // batch-mutation cost; single user actions can afford a
        // synchronous decode.
        refresh()
        push(.strokeAdded(stroke, target: target))
    }

    func removeStroke(id: UUID, from target: EditTarget = .activeSketch) throws {
        // Capture the stroke before deleting so undo can put it
        // back exactly as it was.
        let removed = strokes(in: target).first(where: { $0.id == id })
        switch target {
        case .activeSketch:
            try board.removeActiveStroke(id: id)
        case .snapshot(let snapshotId):
            try board.removeStrokeFromSnapshot(snapshotId: snapshotId, strokeId: id)
        }
        refresh()
        if let removed { push(.strokeRemoved(removed, target: target)) }
    }

    /// Back-compat shim — callers that still pass no target erase
    /// from the active sketch.
    func removeActiveStroke(id: UUID) throws {
        try removeStroke(id: id, from: .activeSketch)
    }

    /// Current strokes for a given target. View code uses this so
    /// CanvasView can switch between rendering the active sketch
    /// and rendering a snapshot's interior with the same code.
    func strokes(in target: EditTarget) -> [Stroke] {
        switch target {
        case .activeSketch:
            return canvas.activeSketch.strokes
        case .snapshot(let id):
            return canvas.snapshots.first(where: { $0.id == id })?.strokes ?? []
        }
    }

    @discardableResult
    func captureSnapshot(at x: Double, y: Double, z: Int, id: UUID = UUID()) throws -> UUID {
        // Remember the strokes that will get cleared from the
        // active sketch — without them, undoing a capture would
        // leave the user staring at an empty board.
        let restored = canvas.activeSketch.strokes
        // Batch the writes. captureSnapshot fires one Automerge
        // change per scalar field per point per stroke — easily
        // 20k events for a dense sketch — and without batching
        // each one would round-trip through Combine and decode
        // the full doc.
        let snapId = try withBatchedRefresh {
            try board.captureSnapshotUsing(
                strokes: restored,
                at: x, y: y, z: z, id: id)
        }
        let snap = Snapshot(id: snapId, x: x, y: y, z: z, strokes: restored)
        push(.snapshotCaptured(snapshot: snap, restoredStrokes: restored))
        return snapId
    }

    // MARK: - Text notes

    @discardableResult
    func addText(at x: Double, y: Double, text: String = "") throws -> TextNote {
        let note = TextNote(
            id: UUID(),
            x: x, y: y,
            z: canvas.texts.count,
            text: text,
            fontSize: 16,
            color: 0x111111FF)
        try board.addText(note)
        refresh()
        push(.textAdded(note))
        return note
    }

    func updateText(id: UUID, to newText: String) throws {
        guard let old = canvas.texts.first(where: { $0.id == id }) else { return }
        guard old.text != newText else { return }
        try board.updateText(id: id, text: newText)
        refresh()
        push(.textEdited(id: id, oldText: old.text, newText: newText))
    }

    func moveText(id: UUID, to x: Double, y: Double) throws {
        let from = canvas.texts.first(where: { $0.id == id })
            .map { CGPoint(x: $0.x, y: $0.y) }
        try board.moveText(id: id, to: x, y: y)
        refresh()
        if let from {
            push(.textMoved(id: id, from: from, to: CGPoint(x: x, y: y)))
        }
    }

    func removeText(id: UUID) throws {
        let removed = canvas.texts.first(where: { $0.id == id })
        try board.removeText(id: id)
        refresh()
        if let removed { push(.textRemoved(removed)) }
    }

    // MARK: - Image notes

    @discardableResult
    func addImage(_ note: ImageNote) throws -> ImageNote {
        try board.addImage(note)
        refresh()
        push(.imageAdded(note))
        return note
    }

    func moveImage(id: UUID, to x: Double, y: Double) throws {
        let from = canvas.images.first(where: { $0.id == id })
            .map { CGPoint(x: $0.x, y: $0.y) }
        try board.moveImage(id: id, to: x, y: y)
        refresh()
        if let from {
            push(.imageMoved(id: id, from: from, to: CGPoint(x: x, y: y)))
        }
    }

    func removeImage(id: UUID) throws {
        let removed = canvas.images.first(where: { $0.id == id })
        try board.removeImage(id: id)
        refresh()
        if let removed { push(.imageRemoved(removed)) }
    }

    // MARK: - Comments

    @discardableResult
    func addComment(at x: Double, y: Double,
                    authorPeerId: String, authorName: String,
                    text: String = "") throws -> Comment {
        let comment = Comment(
            id: UUID(),
            x: x, y: y,
            z: canvas.comments.count,
            authorPeerId: authorPeerId,
            authorName: authorName,
            text: text,
            createdAt: .now,
            isResolved: false)
        try board.addComment(comment)
        refresh()
        push(.commentAdded(comment))
        return comment
    }

    func updateCommentText(id: UUID, to newText: String) throws {
        guard let old = canvas.comments.first(where: { $0.id == id }) else { return }
        guard old.text != newText else { return }
        try board.updateCommentText(id: id, text: newText)
        refresh()
        push(.commentTextEdited(id: id, oldText: old.text, newText: newText))
    }

    func toggleCommentResolution(id: UUID) throws {
        guard let comment = canvas.comments.first(where: { $0.id == id }) else { return }
        let newValue = !comment.isResolved
        try board.setCommentResolved(id: id, resolved: newValue)
        refresh()
        push(.commentResolutionToggled(id: id, oldValue: comment.isResolved, newValue: newValue))
    }

    func moveComment(id: UUID, to x: Double, y: Double) throws {
        let from = canvas.comments.first(where: { $0.id == id })
            .map { CGPoint(x: $0.x, y: $0.y) }
        try board.moveComment(id: id, to: x, y: y)
        refresh()
        if let from {
            push(.commentMoved(id: id, from: from, to: CGPoint(x: x, y: y)))
        }
    }

    func removeComment(id: UUID) throws {
        let removed = canvas.comments.first(where: { $0.id == id })
        try board.removeComment(id: id)
        refresh()
        if let removed { push(.commentRemoved(removed)) }
    }

    func moveSnapshot(id: UUID, to x: Double, y: Double) throws {
        let from = canvas.snapshots.first(where: { $0.id == id })
            .map { CGPoint(x: $0.x, y: $0.y) }
        try board.moveSnapshot(id: id, to: x, y: y)
        // Synchronous refresh — without it the throttled
        // subscription holds the canvas update for up to 16ms
        // after the drag ends, and the snapshot briefly renders
        // at its OLD position (the draggingOffset already
        // cleared in the caller). That single-frame snap-back
        // reads as "I lost the snapshot."
        refresh()
        if let from {
            push(.snapshotMoved(id: id, from: from, to: CGPoint(x: x, y: y)))
        }
    }

    // MARK: - Undo / redo

    func undo() {
        guard let action = undoStack.popLast() else { return }
        applyInverse(of: action)
        refresh()   // immediate feedback, same reasoning as user mutations
        redoStack.append(action)
        updateStackFlags()
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        apply(action)
        refresh()
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
            case .strokeAdded(let stroke, let target):
                try doCommit(stroke, to: target)
            case .strokeRemoved(let stroke, let target):
                try doRemove(strokeId: stroke.id, from: target)
            case .snapshotCaptured(let snapshot, _):
                // The restored strokes are already in the active
                // sketch (we undid the capture by putting them
                // back). Capturing again with the same id moves
                // them into the snapshot, just like the first time.
                _ = try board.captureSnapshot(
                    at: snapshot.x, y: snapshot.y, z: snapshot.z, id: snapshot.id)
            case .snapshotMoved(let id, _, let to):
                try board.moveSnapshot(id: id, to: to.x, y: to.y)
            case .textAdded(let note):
                try board.addText(note)
            case .textRemoved(let note):
                try board.removeText(id: note.id)
            case .textMoved(let id, _, let to):
                try board.moveText(id: id, to: to.x, y: to.y)
            case .textEdited(let id, _, let newText):
                try board.updateText(id: id, text: newText)
            case .imageAdded(let note):
                try board.addImage(note)
            case .imageRemoved(let note):
                try board.removeImage(id: note.id)
            case .imageMoved(let id, _, let to):
                try board.moveImage(id: id, to: to.x, y: to.y)
            case .commentAdded(let comment):
                try board.addComment(comment)
            case .commentRemoved(let comment):
                try board.removeComment(id: comment.id)
            case .commentMoved(let id, _, let to):
                try board.moveComment(id: id, to: to.x, y: to.y)
            case .commentTextEdited(let id, _, let newText):
                try board.updateCommentText(id: id, text: newText)
            case .commentResolutionToggled(let id, _, let newValue):
                try board.setCommentResolved(id: id, resolved: newValue)
            }
        } catch {
            assertionFailure("redo failed: \(error)")
        }
    }

    /// Apply the inverse of a user action (used by `undo`).
    private func applyInverse(of action: UndoableAction) {
        do {
            switch action {
            case .strokeAdded(let stroke, let target):
                try doRemove(strokeId: stroke.id, from: target)
            case .strokeRemoved(let stroke, let target):
                try doCommit(stroke, to: target)
            case .snapshotCaptured(let snapshot, let restored):
                try board.removeSnapshot(id: snapshot.id)
                for stroke in restored {
                    try board.commitStroke(stroke)
                }
            case .snapshotMoved(let id, let from, _):
                try board.moveSnapshot(id: id, to: from.x, y: from.y)
            case .textAdded(let note):
                try board.removeText(id: note.id)
            case .textRemoved(let note):
                try board.addText(note)
            case .textMoved(let id, let from, _):
                try board.moveText(id: id, to: from.x, y: from.y)
            case .textEdited(let id, let oldText, _):
                try board.updateText(id: id, text: oldText)
            case .imageAdded(let note):
                try board.removeImage(id: note.id)
            case .imageRemoved(let note):
                try board.addImage(note)
            case .imageMoved(let id, let from, _):
                try board.moveImage(id: id, to: from.x, y: from.y)
            case .commentAdded(let comment):
                try board.removeComment(id: comment.id)
            case .commentRemoved(let comment):
                try board.addComment(comment)
            case .commentMoved(let id, let from, _):
                try board.moveComment(id: id, to: from.x, y: from.y)
            case .commentTextEdited(let id, let oldText, _):
                try board.updateCommentText(id: id, text: oldText)
            case .commentResolutionToggled(let id, let oldValue, _):
                try board.setCommentResolved(id: id, resolved: oldValue)
            }
        } catch {
            assertionFailure("undo failed: \(error)")
        }
    }

    /// Pure-doc commit (no undo push) — used by undo/redo paths.
    private func doCommit(_ stroke: Stroke, to target: EditTarget) throws {
        switch target {
        case .activeSketch:
            try board.commitStroke(stroke)
        case .snapshot(let id):
            try board.commitStrokeToSnapshot(snapshotId: id, stroke: stroke)
        }
    }

    /// Pure-doc remove (no undo push) — used by undo/redo paths.
    private func doRemove(strokeId: UUID, from target: EditTarget) throws {
        switch target {
        case .activeSketch:
            try board.removeActiveStroke(id: strokeId)
        case .snapshot(let id):
            try board.removeStrokeFromSnapshot(snapshotId: id, strokeId: strokeId)
        }
    }
}
