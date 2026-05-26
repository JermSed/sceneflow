//
//  BoardLibraryTests.swift
//  flowTests
//
//  Exercises BoardLibrary's on-disk store and Repo integration.
//  Each test gets its own tmpdir as the library root so they're
//  independent of each other and of any production Application
//  Support state.
//
//  These tests point the library at a relay URL that no one is
//  listening on (ws://127.0.0.1:1). That's intentional: we want
//  to verify the library behaves correctly when the network layer
//  is unavailable, which is the same code path as "user is offline".
//  The WebSocketProvider retries quietly in the background; the
//  local-only flows here don't depend on it succeeding.
//

import Testing
import Foundation
@testable import flow

@MainActor
struct BoardLibraryTests {

    /// A relay URL that nothing will ever answer on, so tests never
    /// accidentally race with a real sync server.
    private static let offlineRelay = URL(string: "ws://127.0.0.1:1")!

    private static func makeTempRoot() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeLibrary(rootURL: URL) throws -> BoardLibrary {
        try BoardLibrary(rootURL: rootURL, relayURL: offlineRelay)
    }

    // MARK: - Basic CRUD

    @Test func createBoard_appearsInList() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try Self.makeLibrary(rootURL: root)
        #expect(library.boards.isEmpty)

        let summary = try await library.createBoard(name: "Test")
        #expect(library.boards.count == 1)
        #expect(library.boards.first?.id == summary.id)
        #expect(library.boards.first?.name == "Test")
    }

    @Test func createdBoard_persistsAcrossLibraryReopen() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let createdId: UUID
        do {
            let library = try Self.makeLibrary(rootURL: root)
            let summary = try await library.createBoard(name: "Persistent")
            createdId = summary.id
        }

        let reopened = try Self.makeLibrary(rootURL: root)
        #expect(reopened.boards.count == 1)
        #expect(reopened.boards.first?.id == createdId)
        #expect(reopened.boards.first?.name == "Persistent")
    }

    @Test func openBoard_returnsEmptyState_forFreshBoard() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try Self.makeLibrary(rootURL: root)
        let summary = try await library.createBoard(name: "Fresh")
        let store = try await library.openBoard(id: summary.id)
        #expect(store.canvas == CanvasDoc.empty)
    }

    @Test func openBoard_returnsCachedStore_onSecondCall() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try Self.makeLibrary(rootURL: root)
        let summary = try await library.createBoard(name: "Cached")

        let first = try await library.openBoard(id: summary.id)
        let second = try await library.openBoard(id: summary.id)
        #expect(first === second,
                "openBoard must return the same instance so two views see the same state")
    }

    // MARK: - Save / reload round-trip via library

    @Test func edits_roundTripThroughLibrary() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let summaryId: UUID
        do {
            let library = try Self.makeLibrary(rootURL: root)
            let summary = try await library.createBoard(name: "Edits")
            summaryId = summary.id

            let store = try await library.openBoard(id: summary.id)
            let handle = try store.beginStroke(color: 0xABCDEFFF, width: 3.0)
            try store.appendPoint(to: handle, Point(x: 7, y: 8, pressure: 0.4))
            try store.appendPoint(to: handle, Point(x: 9, y: 10, pressure: 0.6))
            try library.saveNow(id: summary.id)
        }

        let reopened = try Self.makeLibrary(rootURL: root)
        let store = try await reopened.openBoard(id: summaryId)
        #expect(store.canvas.activeSketch.strokes.count == 1)
        #expect(store.canvas.activeSketch.strokes[0].color == 0xABCDEFFF)
        #expect(store.canvas.activeSketch.strokes[0].points.count == 2)
        #expect(store.canvas.activeSketch.strokes[0].points[1] ==
                Point(x: 9, y: 10, pressure: 0.6))
    }

    // MARK: - Rename / delete

    @Test func rename_updatesNameAndPersists() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try Self.makeLibrary(rootURL: root)
        let summary = try await library.createBoard(name: "Old")
        try library.rename(id: summary.id, to: "New")
        #expect(library.boards.first?.name == "New")

        let reopened = try Self.makeLibrary(rootURL: root)
        #expect(reopened.boards.first?.name == "New")
    }

    @Test func deleteBoard_removesFromListAndDisk() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try Self.makeLibrary(rootURL: root)
        let summary = try await library.createBoard(name: "Doomed")
        let boardFile = root.appendingPathComponent("\(summary.id.uuidString).automerge")
        #expect(FileManager.default.fileExists(atPath: boardFile.path))

        try library.deleteBoard(id: summary.id)
        #expect(library.boards.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: boardFile.path),
                "deleteBoard must remove the on-disk Automerge file")

        let reopened = try Self.makeLibrary(rootURL: root)
        #expect(reopened.boards.isEmpty)
    }

    @Test func openBoard_throwsForUnknownId() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try Self.makeLibrary(rootURL: root)
        await #expect(throws: BoardLibraryError.self) {
            try await library.openBoard(id: UUID())
        }
    }

    // MARK: - DocumentId derivation

    /// For locally-created boards (no explicit `documentIdString`),
    /// the sync identity is `DocumentId(id).id`. Two summaries with
    /// the same UUID must produce the same DocumentId string — that
    /// stability is what lets the same board reload into the same
    /// `DocHandle` across launches.
    @Test func boardSummary_documentId_isStableForLocalBoards() {
        let uuid = UUID()
        let a = BoardSummary(
            id: uuid, name: "a", createdAt: .now, updatedAt: .now)
        let b = BoardSummary(
            id: uuid, name: "b", createdAt: .now, updatedAt: .now)
        #expect(a.documentIdString == b.documentIdString)
        #expect(a.documentIdString == BoardSummary.derivedDocumentIdString(from: uuid))
    }

    /// Joined boards (with an explicit peer-supplied documentIdString)
    /// keep that string verbatim — we don't accidentally re-derive
    /// from the local UUID.
    @Test func boardSummary_documentId_preservesJoinedPeerIdentity() {
        let localId = UUID()
        let peerSuppliedDocId = BoardSummary
            .derivedDocumentIdString(from: UUID())   // a different UUID
        let summary = BoardSummary(
            id: localId, name: "joined",
            createdAt: .now, updatedAt: .now,
            documentIdString: peerSuppliedDocId)
        #expect(summary.documentIdString == peerSuppliedDocId)
        #expect(summary.documentIdString
                != BoardSummary.derivedDocumentIdString(from: localId),
                "peer-supplied DocumentId must not be overwritten by local-UUID-derived form")
    }
}
