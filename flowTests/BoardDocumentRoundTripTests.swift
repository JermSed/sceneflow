//
//  BoardDocumentRoundTripTests.swift
//  flowTests
//
//  Phase 0 acceptance test.
//
//  Build a populated `CanvasDoc`, encode it through `BoardDocument`,
//  save() to bytes, reload from those bytes, decode back to a Swift
//  value, and assert it matches the original. If this passes we know
//  the document model + Automerge Codable mapping + persistence path
//  all line up end-to-end.
//

import Testing
import Foundation
@testable import flow

struct BoardDocumentRoundTripTests {

    /// A small but non-trivial canvas: two snapshots in the spatial
    /// field, plus a live sketch with one in-progress stroke. Enough
    /// shape to exercise nested arrays and every scalar type in the doc.
    private func sampleCanvas() -> CanvasDoc {
        let strokeA = Stroke(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            color: 0xFF0000FF, // opaque red, packed RRGGBBAA
            width: 2.5,
            points: [
                Point(x: 10, y: 20, pressure: 0.3),
                Point(x: 12, y: 22, pressure: 0.5),
                Point(x: 15, y: 25, pressure: 0.8),
            ]
        )
        let strokeB = Stroke(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            color: 0x00FF00FF,
            width: 1.0,
            points: [
                Point(x: 100, y: 100, pressure: 1.0),
            ]
        )
        let liveStroke = Stroke(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            color: 0x0000FFFF,
            width: 4.0,
            points: [
                Point(x: 0, y: 0, pressure: 0.1),
                Point(x: 5, y: 5, pressure: 0.2),
            ]
        )

        return CanvasDoc(
            snapshots: [
                Snapshot(
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    x: 50, y: 75, z: 0,
                    strokes: [strokeA]
                ),
                Snapshot(
                    id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    x: 200, y: 80, z: 1,
                    strokes: [strokeA, strokeB]
                ),
            ],
            activeSketch: Sketch(strokes: [liveStroke])
        )
    }

    /// The headline test: encode → save → load → decode preserves the
    /// document. If automerge-swift's Codable bridge ever stops mapping
    /// one of our types correctly (UInt32 color, UUID id, Int z, nested
    /// arrays), this is what catches it.
    @Test func encodeSaveLoadDecode_preservesCanvas() throws {
        let original = sampleCanvas()

        let board = try BoardDocument()
        try board.replace(with: original)

        let bytes = board.save()
        #expect(!bytes.isEmpty, "save() should produce a non-empty Automerge blob")

        let reopened = try BoardDocument(data: bytes)
        let restored = try reopened.snapshot()

        #expect(restored == original)
    }

    /// A brand-new BoardDocument should decode as the empty canvas.
    /// Guards against accidentally seeding the doc with stale state.
    @Test func freshBoard_isEmptyCanvas() throws {
        let board = try BoardDocument()
        let value = try board.snapshot()
        #expect(value == CanvasDoc.empty)
    }

    /// Saving and reloading an empty board should still round-trip — a
    /// surprisingly easy way to break the model (e.g. if `Sketch` is
    /// encoded as a missing key when its `strokes` array is empty).
    @Test func emptyBoard_roundTrips() throws {
        let board = try BoardDocument()
        let bytes = board.save()
        let reopened = try BoardDocument(data: bytes)
        #expect(try reopened.snapshot() == CanvasDoc.empty)
    }

    /// `Document.merge(other:)` is the call Phase 2 sync will lean on.
    /// We don't exercise true concurrent edits yet (no fine-grained
    /// mutation API in Phase 0), but we can at least confirm that
    /// merging a fork of the same doc is a no-op and doesn't throw.
    @Test func mergingAFork_isNoOp() throws {
        let board = try BoardDocument()
        try board.replace(with: sampleCanvas())

        let forkBytes = board.save()
        let fork = try BoardDocument(data: forkBytes)

        try board.merge(fork)
        #expect(try board.snapshot() == sampleCanvas())
    }
}
