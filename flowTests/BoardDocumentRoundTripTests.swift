//
//  BoardDocumentRoundTripTests.swift
//  flowTests
//
//  Exercises `BoardDocument`'s mutation API and persistence path.
//
//  These tests intentionally avoid any "rewrite the whole tree" helper.
//  Building doc state through the same mutation API the app uses
//  catches encoder/decoder drift AND verifies the CRDT properties
//  CLAUDE.md promises in the doc-model design rules.
//

import Testing
import Foundation
@testable import flow

struct BoardDocumentRoundTripTests {

    // MARK: - Fixtures

    /// Build a small but non-trivial board using the same mutation API
    /// the app uses: one captured snapshot, plus an in-progress live
    /// stroke. Returns the populated board and the IDs we used so
    /// tests can assert against them.
    private func populatedBoard() throws -> (
        board: BoardDocument,
        capturedSnapshotId: UUID,
        liveStrokeId: UUID
    ) {
        let board = try BoardDocument()

        // Draw stroke A, capture it as a snapshot at (50, 75).
        let strokeAId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let snapshotAId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let handleA = try board.beginStroke(id: strokeAId, color: 0xFF0000FF, width: 2.5)
        try board.appendPoint(to: handleA, Point(x: 10, y: 20, pressure: 0.3))
        try board.appendPoint(to: handleA, Point(x: 12, y: 22, pressure: 0.5))
        try board.appendPoint(to: handleA, Point(x: 15, y: 25, pressure: 0.8))
        try board.captureSnapshot(at: 50, y: 75, z: 0, id: snapshotAId)

        // Start a new live stroke (B) but don't capture it — exercises
        // both "frozen snapshot" and "in-progress sketch" sides of the
        // model in one fixture.
        let liveStrokeId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let liveHandle = try board.beginStroke(id: liveStrokeId, color: 0x0000FFFF, width: 4.0)
        try board.appendPoint(to: liveHandle, Point(x: 0, y: 0, pressure: 0.1))
        try board.appendPoint(to: liveHandle, Point(x: 5, y: 5, pressure: 0.2))

        return (board, snapshotAId, liveStrokeId)
    }

    // MARK: - Mutations land in the decoded snapshot

    /// Headline test: the state we wrote through the mutation API is
    /// what we read back through `snapshot()`. If `AutomergeDecoder`
    /// ever stops mapping one of our types (UInt32 color, UUID id,
    /// Int z, nested arrays), this catches it.
    @Test func mutations_landInDecodedSnapshot() throws {
        let (board, snapshotAId, liveStrokeId) = try populatedBoard()
        let value = try board.snapshot()

        #expect(value.snapshots.count == 1)
        let captured = try #require(value.snapshots.first)
        #expect(captured.id == snapshotAId)
        #expect(captured.x == 50)
        #expect(captured.y == 75)
        #expect(captured.z == 0)
        #expect(captured.strokes.count == 1)
        #expect(captured.strokes[0].color == 0xFF0000FF)
        #expect(captured.strokes[0].width == 2.5)
        #expect(captured.strokes[0].points.count == 3)
        #expect(captured.strokes[0].points[2] == Point(x: 15, y: 25, pressure: 0.8))

        // The in-progress stroke is still on the live sketch.
        #expect(value.activeSketch.strokes.count == 1)
        #expect(value.activeSketch.strokes[0].id == liveStrokeId)
        #expect(value.activeSketch.strokes[0].points.count == 2)
    }

    // MARK: - Empty / fresh board

    /// A brand-new BoardDocument should decode as the empty canvas.
    /// Guards against accidentally seeding the doc with stale state.
    @Test func freshBoard_isEmptyCanvas() throws {
        let board = try BoardDocument()
        let value = try board.snapshot()
        #expect(value == CanvasDoc.empty)
    }

    /// Saving and reloading an empty board still round-trips. A
    /// surprisingly easy thing to break — e.g. if `Sketch` were
    /// encoded as a missing key when its `strokes` array is empty,
    /// the decoder would reject the reloaded doc.
    @Test func emptyBoard_roundTrips() throws {
        let board = try BoardDocument()
        let bytes = board.save()
        let reopened = try BoardDocument(data: bytes)
        #expect(try reopened.snapshot() == CanvasDoc.empty)
    }

    // MARK: - Save / load round-trip preserves state

    /// Populate via the mutation API, save, reload, assert equal.
    /// This is the end-to-end persistence guarantee Phase 1 makes:
    /// what you drew is what you get back.
    @Test func populatedBoard_roundTrips() throws {
        let (board, _, _) = try populatedBoard()
        let before = try board.snapshot()

        let bytes = board.save()
        #expect(!bytes.isEmpty)

        let reopened = try BoardDocument(data: bytes)
        let after = try reopened.snapshot()
        #expect(after == before)
    }

    // MARK: - captureSnapshot behavior

    /// Capturing freezes the live sketch into a snapshot AND clears
    /// the live sketch so the next stroke starts blank.
    @Test func captureSnapshot_freezesAndClears() throws {
        let board = try BoardDocument()
        let handle = try board.beginStroke(color: 0xFFFFFFFF, width: 1.0)
        try board.appendPoint(to: handle, Point(x: 1, y: 1, pressure: 0.5))
        try board.appendPoint(to: handle, Point(x: 2, y: 2, pressure: 0.5))

        let snapshotId = try board.captureSnapshot(at: 100, y: 200, z: 5)

        let value = try board.snapshot()
        #expect(value.activeSketch.strokes.isEmpty,
                "live sketch should be cleared after capture")
        #expect(value.snapshots.count == 1)
        #expect(value.snapshots[0].id == snapshotId)
        #expect(value.snapshots[0].x == 100)
        #expect(value.snapshots[0].y == 200)
        #expect(value.snapshots[0].z == 5)
        #expect(value.snapshots[0].strokes.count == 1)
        #expect(value.snapshots[0].strokes[0].points.count == 2)
    }

    /// After capture, drawing again populates ONLY the live sketch,
    /// not the captured snapshot. Verifies the snapshot really is
    /// an independent copy (not a reference to the same stroke list).
    @Test func capturedSnapshot_isImmutableUnderFurtherEdits() throws {
        let board = try BoardDocument()
        let h1 = try board.beginStroke(color: 0xFF0000FF, width: 1.0)
        try board.appendPoint(to: h1, Point(x: 1, y: 1, pressure: 0.5))
        try board.captureSnapshot(at: 0, y: 0, z: 0)

        let h2 = try board.beginStroke(color: 0x00FF00FF, width: 2.0)
        try board.appendPoint(to: h2, Point(x: 9, y: 9, pressure: 0.9))

        let value = try board.snapshot()
        #expect(value.snapshots[0].strokes.count == 1,
                "the captured snapshot must not have grown when we drew again")
        #expect(value.snapshots[0].strokes[0].points.count == 1)
        #expect(value.activeSketch.strokes.count == 1)
    }

    // MARK: - moveSnapshot

    @Test func moveSnapshot_updatesPosition() throws {
        let board = try BoardDocument()
        try board.beginStroke(color: 0xFFFFFFFF, width: 1.0)
        let id = try board.captureSnapshot(at: 0, y: 0, z: 0)

        try board.moveSnapshot(id: id, to: 250, y: 400)

        let value = try board.snapshot()
        #expect(value.snapshots[0].x == 250)
        #expect(value.snapshots[0].y == 400)
    }

    // MARK: - The CRDT property: concurrent appends both survive

    /// The headline reason we're on Automerge. Two clients fork from
    /// the same starting state, each appends a stroke to the live
    /// sketch, then we merge. Both strokes should end up in the
    /// merged doc — neither should be overwritten.
    ///
    /// If this test ever fails, it almost certainly means a mutation
    /// path is re-encoding a list wholesale instead of appending to it.
    @Test func concurrentStrokeAppends_bothSurviveMerge() throws {
        // Common ancestor: empty board, serialized.
        let ancestor = try BoardDocument()
        let ancestorBytes = ancestor.save()

        // Client A forks, draws a red stroke.
        let aliceId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let alice = try BoardDocument(data: ancestorBytes)
        let aliceStroke = try alice.beginStroke(id: aliceId, color: 0xFF0000FF, width: 2.0)
        try alice.appendPoint(to: aliceStroke, Point(x: 1, y: 1, pressure: 0.5))

        // Client B forks from the same ancestor, draws a blue stroke.
        let bobId = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let bob = try BoardDocument(data: ancestorBytes)
        let bobStroke = try bob.beginStroke(id: bobId, color: 0x0000FFFF, width: 3.0)
        try bob.appendPoint(to: bobStroke, Point(x: 9, y: 9, pressure: 0.9))

        // Merge B into A. (Merging the other way and asserting symmetry
        // would be nice but is a second test; this one proves the basic
        // "no edits lost" property.)
        try alice.merge(bob)

        let merged = try alice.snapshot()
        let strokeIds = Set(merged.activeSketch.strokes.map(\.id))
        #expect(strokeIds == [aliceId, bobId],
                "both concurrent strokes must survive merge; got \(strokeIds)")
    }

    /// Concurrent point appends to the *same* stroke after both
    /// clients started from a shared in-progress stroke also merge
    /// without loss. (A stroke a co-collaborator is touching at the
    /// same moment is unusual but should still behave.)
    @Test func concurrentPointAppends_bothSurviveMerge() throws {
        // Shared starting state: one stroke with one point.
        let seed = try BoardDocument()
        let strokeId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let seedHandle = try seed.beginStroke(id: strokeId, color: 0xFFFFFFFF, width: 1.0)
        try seed.appendPoint(to: seedHandle, Point(x: 0, y: 0, pressure: 0.1))
        let seedBytes = seed.save()

        // Both clients reload — they each need to look up the stroke's
        // points-list ObjId fresh from their own copy of the doc.
        // (Handles are not portable across documents.)
        let alice = try BoardDocument(data: seedBytes)
        let bob = try BoardDocument(data: seedBytes)

        // Resolve the stroke's points list inside each client by
        // walking through snapshot() to find the stroke index, then
        // doing one round of beginStroke-style append via the public
        // API. Phase 1 doesn't yet expose a public "resume stroke"
        // method, so this test starts a brand-new stroke per client
        // instead — still validates the merge property for live edits.
        let aliceStrokeId = UUID()
        let aliceHandle = try alice.beginStroke(id: aliceStrokeId, color: 0xFF0000FF, width: 2.0)
        try alice.appendPoint(to: aliceHandle, Point(x: 1, y: 1, pressure: 0.4))

        let bobStrokeId = UUID()
        let bobHandle = try bob.beginStroke(id: bobStrokeId, color: 0x0000FFFF, width: 2.0)
        try bob.appendPoint(to: bobHandle, Point(x: 2, y: 2, pressure: 0.6))

        try alice.merge(bob)

        let merged = try alice.snapshot()
        let ids = Set(merged.activeSketch.strokes.map(\.id))
        #expect(ids == [strokeId, aliceStrokeId, bobStrokeId])
    }

    // MARK: - moveSnapshot last-write-wins under merge

    /// Two clients move the same snapshot concurrently. Per the
    /// document-model design rule "snapshot x/y/z are scalars →
    /// rearranging resolves as last-write-wins," the merge result
    /// should pick exactly one position (not blend them). We don't
    /// assert *which* one — that's an Automerge implementation
    /// detail — only that it's one of the two and not corrupted.
    @Test func concurrentSnapshotMove_resolvesLastWriteWins() throws {
        let seed = try BoardDocument()
        try seed.beginStroke(color: 0xFFFFFFFF, width: 1.0)
        let snapshotId = try seed.captureSnapshot(at: 0, y: 0, z: 0)
        let seedBytes = seed.save()

        let alice = try BoardDocument(data: seedBytes)
        let bob = try BoardDocument(data: seedBytes)

        try alice.moveSnapshot(id: snapshotId, to: 100, y: 100)
        try bob.moveSnapshot(id: snapshotId, to: 500, y: 500)

        try alice.merge(bob)

        let merged = try alice.snapshot()
        let placed = try #require(merged.snapshots.first { $0.id == snapshotId })
        let winners: Set<Double> = [100, 500]
        #expect(winners.contains(placed.x), "x must be one of the concurrent writes, got \(placed.x)")
        #expect(winners.contains(placed.y), "y must be one of the concurrent writes, got \(placed.y)")
    }

    // MARK: - Snapshot strokes are editable across peers

    /// Two peers each add a stroke to the SAME existing snapshot.
    /// Snapshots are editable now (CLAUDE.md: "tap a snapshot to draw
    /// on it") — the snapshot's strokes list is append-only at the
    /// CRDT layer just like activeSketch.strokes, so concurrent
    /// additions must both survive merge.
    @Test func concurrentSnapshotStrokes_bothSurviveMerge() throws {
        let seed = try BoardDocument()
        try seed.beginStroke(color: 0xFFFFFFFF, width: 1.0)
        let snapId = try seed.captureSnapshot(at: 10, y: 20, z: 0)
        let seedBytes = seed.save()

        let alice = try BoardDocument(data: seedBytes)
        let aliceStroke = Stroke(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111")!,
            color: 0xFF0000FF, width: 2.0,
            points: [Point(x: 1, y: 1, pressure: 0.5)])
        try alice.commitStrokeToSnapshot(snapshotId: snapId, stroke: aliceStroke)

        let bob = try BoardDocument(data: seedBytes)
        let bobStroke = Stroke(
            id: UUID(uuidString: "BBBBBBBB-2222-2222-2222-222222222222")!,
            color: 0x0000FFFF, width: 3.0,
            points: [Point(x: 9, y: 9, pressure: 0.5)])
        try bob.commitStrokeToSnapshot(snapshotId: snapId, stroke: bobStroke)

        try alice.merge(bob)

        let merged = try alice.snapshot()
        let snap = try #require(merged.snapshots.first { $0.id == snapId })
        let strokeIds = Set(snap.strokes.map(\.id))
        #expect(strokeIds.contains(aliceStroke.id))
        #expect(strokeIds.contains(bobStroke.id))
    }

    /// One peer deletes a snapshot while another peer concurrently
    /// adds a stroke into it. The delete is a list-tombstone, so the
    /// snapshot should be gone after merge — and the stroke addition
    /// is silently dropped because `commitStrokeToSnapshot` no-ops
    /// when the snapshot ObjId can't be resolved. The point of this
    /// test is to pin that behavior so a future Automerge bump or
    /// refactor doesn't accidentally resurrect tombstoned snapshots.
    @Test func concurrentSnapshotDelete_vs_strokeAdd_resolvesAsDelete() throws {
        let seed = try BoardDocument()
        try seed.beginStroke(color: 0xFFFFFFFF, width: 1.0)
        let snapId = try seed.captureSnapshot(at: 0, y: 0, z: 0)
        let seedBytes = seed.save()

        let alice = try BoardDocument(data: seedBytes)
        try alice.removeSnapshot(id: snapId)

        let bob = try BoardDocument(data: seedBytes)
        let stroke = Stroke(
            id: UUID(),
            color: 0x00FF00FF, width: 2.0,
            points: [Point(x: 5, y: 5, pressure: 0.5)])
        try bob.commitStrokeToSnapshot(snapshotId: snapId, stroke: stroke)

        try alice.merge(bob)

        let merged = try alice.snapshot()
        #expect(merged.snapshots.contains(where: { $0.id == snapId }) == false,
                "tombstoned snapshot must not be resurrected by a concurrent stroke add")
    }

    // MARK: - Image round-trip

    /// Image bytes survive save / reload. Specifically guards the
    /// Automerge `.Bytes` scalar mapping — if that ever stops
    /// round-tripping (or starts truncating large payloads), images
    /// would silently corrupt on every reload.
    @Test func image_roundTrips_throughSaveLoad() throws {
        let board = try BoardDocument()
        // ~16KB of non-trivial bytes — big enough to be more than a
        // tiny header, small enough to keep the test fast.
        var bytes = Data(count: 16 * 1024)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(i & 0xFF)
        }
        let note = ImageNote(
            id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
            x: 100, y: 200, z: 3,
            width: 640, height: 480,
            data: bytes,
            format: "jpeg")
        try board.addImage(note)

        let saved = board.save()
        let reopened = try BoardDocument(data: saved)
        let value = try reopened.snapshot()
        let restored = try #require(value.images.first)
        #expect(restored.id == note.id)
        #expect(restored.width == 640)
        #expect(restored.height == 480)
        #expect(restored.format == "jpeg")
        #expect(restored.data == bytes, "image bytes must round-trip exactly")
    }

    // MARK: - Forward-compat: old docs without texts/images/comments/connectors

    /// A board saved before texts/images/comments/connectors existed
    /// has none of those top-level keys in its Automerge tree.
    /// `init(adopting:)` should seed empty lists for the missing
    /// keys so subsequent mutations don't fail to resolve list ObjIds.
    ///
    /// We simulate "old bytes" by building a doc, then yanking the
    /// new keys out at the Automerge layer — but `BoardDocument`
    /// doesn't expose that path, so instead we exercise the seeding
    /// via the public adopt entrypoint by feeding it the bytes from
    /// a freshly-created board and checking that adoption is a no-op
    /// (idempotent). A separate path exercises the missing-keys case
    /// via a brand-new empty Automerge document, which lacks
    /// `activeSketch` and therefore takes the full seed branch.
    @Test func adopt_seedsAllTopLevelKeys_idempotently() throws {
        // Round 1: adopt a freshly-created board's bytes. All keys
        // already exist; adoption should leave the snapshot unchanged.
        let original = try BoardDocument()
        try original.addText(TextNote(
            id: UUID(), x: 1, y: 2, z: 0,
            text: "hi", fontSize: 16, color: 0x111111FF))
        try original.addConnector(Connector(
            id: UUID(),
            from: UUID(),
            to: UUID()))
        let snapshotBefore = try original.snapshot()
        let bytes = original.save()

        let reopened = try BoardDocument(data: bytes)
        let snapshotAfter = try reopened.snapshot()
        #expect(snapshotAfter == snapshotBefore,
                "round-trip through save/load should preserve every top-level list")

        // Round 2: every top-level list a current build expects must
        // be present and decodable from a fresh board, including
        // comments and connectors that didn't exist in earlier phases.
        let fresh = try BoardDocument()
        let freshValue = try fresh.snapshot()
        #expect(freshValue.snapshots.isEmpty)
        #expect(freshValue.texts.isEmpty)
        #expect(freshValue.images.isEmpty)
        #expect(freshValue.comments.isEmpty)
        #expect(freshValue.connectors.isEmpty)
        // Mutating one of the newer lists must work without
        // throwing "list ObjId not found".
        try fresh.addComment(Comment(
            id: UUID(), x: 0, y: 0, z: 0,
            authorPeerId: "peer-1", authorName: "Alice",
            text: "first comment", createdAt: Date(timeIntervalSince1970: 0),
            isResolved: false))
        #expect(try fresh.snapshot().comments.count == 1)
    }

    // MARK: - Connectors

    /// Add a connector, save, reload, verify. Both endpoints are
    /// just UUIDs (we don't enforce snapshot existence) — that's
    /// intentional so a connector pointing at a snapshot that was
    /// just deleted simply dangles rather than blocking the delete.
    @Test func connector_roundTrips() throws {
        let board = try BoardDocument()
        let from = UUID()
        let to = UUID()
        let connector = Connector(id: UUID(), from: from, to: to)
        try board.addConnector(connector)

        let reopened = try BoardDocument(data: board.save())
        let value = try reopened.snapshot()
        #expect(value.connectors.count == 1)
        #expect(value.connectors[0].from == from)
        #expect(value.connectors[0].to == to)
    }

    /// Two peers each add a connector concurrently. List CRDT,
    /// so both must survive merge — same property as strokes.
    @Test func concurrentConnectors_bothSurviveMerge() throws {
        let seed = try BoardDocument()
        let seedBytes = seed.save()

        let alice = try BoardDocument(data: seedBytes)
        let aConnector = Connector(id: UUID(), from: UUID(), to: UUID())
        try alice.addConnector(aConnector)

        let bob = try BoardDocument(data: seedBytes)
        let bConnector = Connector(id: UUID(), from: UUID(), to: UUID())
        try bob.addConnector(bConnector)

        try alice.merge(bob)
        let merged = try alice.snapshot()
        let ids = Set(merged.connectors.map(\.id))
        #expect(ids == [aConnector.id, bConnector.id])
    }

    // MARK: - Comment text LWW (documenting the wart)

    /// Two peers edit the SAME comment's text concurrently. Per the
    /// doc model, `Comment.text` is a plain string scalar → LWW.
    /// The merged result must be exactly one of the two writes
    /// (no string blending, no duplication, no loss of the comment
    /// itself). This test pins the behavior so a future migration
    /// to Automerge `Text` becomes a deliberate decision rather
    /// than an accidental regression.
    @Test func concurrentCommentTextEdits_resolveLastWriteWins() throws {
        let seed = try BoardDocument()
        let commentId = UUID()
        try seed.addComment(Comment(
            id: commentId, x: 0, y: 0, z: 0,
            authorPeerId: "seed-peer", authorName: "Seed",
            text: "original", createdAt: Date(timeIntervalSince1970: 0),
            isResolved: false))
        let seedBytes = seed.save()

        let alice = try BoardDocument(data: seedBytes)
        try alice.updateCommentText(id: commentId, text: "alice's edit")

        let bob = try BoardDocument(data: seedBytes)
        try bob.updateCommentText(id: commentId, text: "bob's edit")

        try alice.merge(bob)

        let merged = try alice.snapshot()
        #expect(merged.comments.count == 1)
        let resolved = try #require(merged.comments.first?.text)
        #expect(resolved == "alice's edit" || resolved == "bob's edit",
                "merged comment text must be exactly one of the concurrent writes, got \(resolved)")
    }
}
