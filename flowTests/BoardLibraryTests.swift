//
//  BoardLibraryTests.swift
//  flowTests
//
//  Exercises BoardLibrary's on-disk store. Each test gets its own
//  tmpdir as the library root so they're independent of each other
//  and of any production Application Support state.
//

import Testing
import Foundation
@testable import flow

@MainActor
struct BoardLibraryTests {

    /// Create a unique temp directory for one test's library to live in.
    /// Deleted on dealloc via the deferred cleanup in each test.
    private static func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    // MARK: - Basic CRUD

    @Test func createBoard_appearsInList() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try BoardLibrary(rootURL: root)
        #expect(library.boards.isEmpty)

        let summary = try library.createBoard(name: "Test")
        #expect(library.boards.count == 1)
        #expect(library.boards.first?.id == summary.id)
        #expect(library.boards.first?.name == "Test")
    }

    @Test func createdBoard_persistsAcrossLibraryReopen() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let createdId: UUID
        do {
            let library = try BoardLibrary(rootURL: root)
            let summary = try library.createBoard(name: "Persistent")
            createdId = summary.id
        }

        // Re-open the library at the same root — index should rehydrate.
        let reopened = try BoardLibrary(rootURL: root)
        #expect(reopened.boards.count == 1)
        #expect(reopened.boards.first?.id == createdId)
        #expect(reopened.boards.first?.name == "Persistent")
    }

    @Test func openBoard_returnsEmptyState_forFreshBoard() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try BoardLibrary(rootURL: root)
        let summary = try library.createBoard(name: "Fresh")
        let store = try library.openBoard(id: summary.id)
        #expect(store.canvas == CanvasDoc.empty)
    }

    @Test func openBoard_returnsCachedStore_onSecondCall() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try BoardLibrary(rootURL: root)
        let summary = try library.createBoard(name: "Cached")

        let first = try library.openBoard(id: summary.id)
        let second = try library.openBoard(id: summary.id)
        #expect(first === second,
                "openBoard must return the same instance so two views see the same state")
    }

    // MARK: - Save / reload round-trip via library

    /// Make edits through the store, force a save, reopen the library
    /// fresh, and confirm the edits came back. This is the end-to-end
    /// guarantee the user actually cares about — "what I drew is what
    /// I see when I come back."
    @Test func edits_roundTripThroughLibrary() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let summaryId: UUID
        do {
            let library = try BoardLibrary(rootURL: root)
            let summary = try library.createBoard(name: "Edits")
            summaryId = summary.id

            let store = try library.openBoard(id: summary.id)
            let handle = try store.beginStroke(color: 0xABCDEFFF, width: 3.0)
            try store.appendPoint(to: handle, Point(x: 7, y: 8, pressure: 0.4))
            try store.appendPoint(to: handle, Point(x: 9, y: 10, pressure: 0.6))
            try library.saveNow(id: summary.id)
        }

        let reopened = try BoardLibrary(rootURL: root)
        let store = try reopened.openBoard(id: summaryId)
        #expect(store.canvas.activeSketch.strokes.count == 1)
        #expect(store.canvas.activeSketch.strokes[0].color == 0xABCDEFFF)
        #expect(store.canvas.activeSketch.strokes[0].points.count == 2)
        #expect(store.canvas.activeSketch.strokes[0].points[1] ==
                Point(x: 9, y: 10, pressure: 0.6))
    }

    // MARK: - Rename / delete

    @Test func rename_updatesNameAndPersists() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try BoardLibrary(rootURL: root)
        let summary = try library.createBoard(name: "Old")
        try library.rename(id: summary.id, to: "New")
        #expect(library.boards.first?.name == "New")

        let reopened = try BoardLibrary(rootURL: root)
        #expect(reopened.boards.first?.name == "New")
    }

    @Test func deleteBoard_removesFromListAndDisk() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try BoardLibrary(rootURL: root)
        let summary = try library.createBoard(name: "Doomed")
        let boardFile = root.appendingPathComponent("\(summary.id.uuidString).automerge")
        #expect(FileManager.default.fileExists(atPath: boardFile.path))

        try library.deleteBoard(id: summary.id)
        #expect(library.boards.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: boardFile.path),
                "deleteBoard must remove the on-disk Automerge file")

        // And it should stay gone across a re-open.
        let reopened = try BoardLibrary(rootURL: root)
        #expect(reopened.boards.isEmpty)
    }

    @Test func openBoard_throwsForUnknownId() throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try BoardLibrary(rootURL: root)
        #expect(throws: BoardLibraryError.self) {
            try library.openBoard(id: UUID())
        }
    }
}
