//
//  BoardLibrary.swift
//  flow
//
//  Manages the on-disk list of boards. Sceneflow is NOT a document-based
//  app (no `DocumentGroup`, no open/save dialogs) — boards live in our
//  own little library under Application Support, and the user picks
//  one to enter from the root board list. CLAUDE.md is explicit on
//  this point: "we manage our own list of boards and persistence."
//
//  Layout on disk:
//
//    <AppSupport>/Boards/
//        index.json                   ← ordered list of BoardSummary
//        <uuid>.automerge             ← Automerge change-history blob
//        <uuid>.automerge
//        ...
//
//  Why a separate `index.json` instead of inferring the list from
//  files on disk? Two reasons:
//   1. Order: we want to preserve the user's preferred ordering
//      (e.g. most-recently-opened first) without renaming files.
//   2. Metadata: name + createdAt + updatedAt without having to open
//      every Automerge doc just to render a list row.
//
//  Why aren't names + timestamps in the Automerge doc itself? They
//  could be — but right now they're board-library concerns, not
//  collaborative state. If we later decide collaborators should see
//  board renames, we move `name` into the doc. Easy migration.
//
//  Auto-save: each opened board's `BoardStore` is subscribed to via
//  Combine; any change to `canvas` schedules a debounced write of the
//  Automerge bytes to disk. The debounce window is small enough that
//  a crash loses at most a few hundred ms of edits but large enough
//  that a flurry of pen events writes once at the end.
//

import Foundation
import Combine
import SwiftUI

/// Metadata for a board shown in the library list — cheap to load and
/// keep in memory for many boards without touching the Automerge docs
/// themselves.
struct BoardSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

/// Errors thrown by the library when the file system is misbehaving
/// or the index file is corrupt.
enum BoardLibraryError: Error {
    case missingBoardFile(UUID)
    case unknownBoard(UUID)
}

/// The app's library of boards. Owns the directory under Application
/// Support, the index file, and the auto-save subscriptions for any
/// boards that are currently open.
///
/// `@MainActor` because views read `boards` directly and all file I/O
/// happens on the main run loop's debounce schedule. (File writes are
/// small Automerge blobs — a few KB to a few hundred KB even for
/// non-trivial boards — so blocking the main thread is fine at this
/// scale. If we later see UI hitches on save we'll move the write to
/// a background queue.)
@MainActor
final class BoardLibrary: ObservableObject {

    /// Ordered list of all boards the user has. The order here is what
    /// the UI shows; mutations to this array bump `objectWillChange`
    /// via `@Published`.
    @Published private(set) var boards: [BoardSummary] = []

    /// Root directory we own. Production uses Application Support;
    /// tests inject a tmpdir.
    private let rootURL: URL

    /// Boards currently open in memory. Caching here means tapping in
    /// and out of a board doesn't lose unsaved local edits and doesn't
    /// re-allocate the Automerge document.
    private var openStores: [UUID: BoardStore] = [:]

    /// Active auto-save sinks, one per open board. Kept alive by this
    /// dictionary; deinit / deleteBoard tears them down.
    private var saveSubs: [UUID: AnyCancellable] = [:]

    /// How long to wait after the last change before flushing bytes to
    /// disk. Tuned for "user puts the pencil down" — small enough that
    /// power loss costs little, big enough that one stroke = one write.
    private let saveDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(400)

    // MARK: - Init

    /// Open (or create) the default library under
    /// `<AppSupport>/Boards/`.
    convenience init() throws {
        try self.init(rootURL: Self.defaultRootURL())
    }

    /// Open (or create) a library rooted at `rootURL`. Used by tests
    /// to direct the library at a tmpdir.
    init(rootURL: URL) throws {
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        try loadIndex()
    }

    // MARK: - Paths

    private static func defaultRootURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return appSupport.appendingPathComponent("Boards", isDirectory: true)
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    private func boardURL(id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).automerge")
    }

    // MARK: - Index I/O

    /// Read the index file. If it doesn't exist (first launch), start
    /// with an empty list — that's not an error.
    private func loadIndex() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            boards = []
            return
        }
        let data = try Data(contentsOf: indexURL)
        boards = try JSONDecoder.iso.decode([BoardSummary].self, from: data)
    }

    private func writeIndex() throws {
        let data = try JSONEncoder.iso.encode(boards)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - CRUD

    /// Create a new empty board and persist it. Returns the summary
    /// so the caller can navigate straight into it.
    @discardableResult
    func createBoard(name: String) throws -> BoardSummary {
        let now = Date()
        let summary = BoardSummary(
            id: UUID(), name: name, createdAt: now, updatedAt: now)
        let store = try BoardStore()
        try store.save().write(to: boardURL(id: summary.id), options: .atomic)
        boards.insert(summary, at: 0)
        try writeIndex()
        openStores[summary.id] = store
        startAutoSave(for: summary.id, store: store)
        return summary
    }

    /// Open a board, loading its Automerge bytes if not already in
    /// memory. The returned store is cached — repeated calls return
    /// the same instance, so two views observing the same board see
    /// the same state.
    func openBoard(id: UUID) throws -> BoardStore {
        if let cached = openStores[id] { return cached }
        guard boards.contains(where: { $0.id == id }) else {
            throw BoardLibraryError.unknownBoard(id)
        }
        let url = boardURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BoardLibraryError.missingBoardFile(id)
        }
        let data = try Data(contentsOf: url)
        let store = try BoardStore(data: data)
        openStores[id] = store
        startAutoSave(for: id, store: store)
        return store
    }

    /// Delete a board and its file. Idempotent — deleting a missing
    /// board is not an error (the on-disk file might have been
    /// removed externally, e.g. by Files.app).
    func deleteBoard(id: UUID) throws {
        openStores.removeValue(forKey: id)
        saveSubs.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: boardURL(id: id))
        boards.removeAll { $0.id == id }
        try writeIndex()
    }

    /// Rename a board. Pure metadata change; doesn't touch the
    /// Automerge doc (see file header for why).
    func rename(id: UUID, to newName: String) throws {
        guard let idx = boards.firstIndex(where: { $0.id == id }) else {
            throw BoardLibraryError.unknownBoard(id)
        }
        boards[idx].name = newName
        boards[idx].updatedAt = Date()
        try writeIndex()
    }

    /// Force a synchronous write of the current bytes for `id`. Used
    /// by tests and (in the future) by scene-lifecycle hooks like
    /// "app moving to background — flush everything now."
    func saveNow(id: UUID) throws {
        guard let store = openStores[id] else {
            throw BoardLibraryError.unknownBoard(id)
        }
        try store.save().write(to: boardURL(id: id), options: .atomic)
        if let idx = boards.firstIndex(where: { $0.id == id }) {
            boards[idx].updatedAt = Date()
            try writeIndex()
        }
    }

    // MARK: - Auto-save

    /// Wire a Combine sink that writes the store's bytes to disk a
    /// short time after the last change. Multiple changes inside the
    /// debounce window coalesce into one write.
    ///
    /// `.dropFirst()` skips the initial seed value the `@Published`
    /// emits on subscription — without it we'd write the doc on every
    /// open, which is wasteful and confuses test assertions.
    private func startAutoSave(for id: UUID, store: BoardStore) {
        saveSubs[id] = store.$canvas
            .dropFirst()
            .debounce(for: saveDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                do {
                    try store.save().write(
                        to: self.boardURL(id: id),
                        options: .atomic)
                    if let idx = self.boards.firstIndex(where: { $0.id == id }) {
                        self.boards[idx].updatedAt = Date()
                        try? self.writeIndex()
                    }
                } catch {
                    assertionFailure("BoardLibrary autosave failed: \(error)")
                }
            }
    }
}

// MARK: - JSON coders

/// ISO-8601 dates so the index file is human-readable and round-trips
/// across timezones / launches without losing precision.
private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
