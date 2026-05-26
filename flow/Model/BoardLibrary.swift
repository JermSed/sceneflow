//
//  BoardLibrary.swift
//  flow
//
//  Manages the on-disk list of boards AND owns the sync layer
//  (`AutomergeRepo.Repo` + `WebSocketProvider`).
//
//  Sceneflow is NOT a document-based app (no `DocumentGroup`, no
//  open/save dialogs) — boards live in our own library under
//  Application Support, and each board's Automerge document is
//  *also* registered with the Repo so it syncs to peers connected
//  through the relay.
//
//  Layout on disk:
//
//    <AppSupport>/Boards/
//        index.json                   ← ordered list of BoardSummary
//        <uuid>.automerge             ← Automerge change-history blob
//        ...
//
//  Sync model:
//
//   • One `Repo` per app instance (a global Automerge actor).
//   • One `WebSocketProvider` connected to the relay (default
//     `ws://localhost:3030`). Reconnects automatically on failure;
//     offline boards keep working locally.
//   • Each `BoardSummary.id` (UUID) round-trips to `DocumentId` via
//     `DocumentId(uuid)`. The bs58 form of `DocumentId` is what we
//     hand peers as a share token.
//   • Creating a board → `repo.create(id: docId)`; the Repo allocates
//     the underlying `Automerge.Document` and we adopt it via
//     `BoardStore(adopting:)` so sync messages mutate the same
//     reference the UI observes.
//   • Opening an existing local board → load bytes from disk, build
//     a `DocHandle(id:doc:)`, hand it to `repo.import(handle:)`. The
//     Repo will start advertising / sharing the doc once a peer
//     connects.
//   • Joining a board by `DocumentId` from a share link → `repo.find`
//     fetches the doc from a peer; we then persist it locally so it
//     survives the next launch even if the peer is gone.
//

import Foundation
import Combine
import SwiftUI
import Automerge
import AutomergeRepo

/// Metadata for a board shown in the library list — cheap to load
/// and keep in memory for many boards without touching the Automerge
/// docs themselves.
///
/// Two identifiers, doing different jobs:
///  - `id` (UUID) — the local handle. File names, dictionary keys,
///    `Identifiable` for SwiftUI lists. Stable across renames /
///    metadata changes.
///  - `documentIdString` (bs58 form of a `DocumentId`) — the sync
///    identity. What we put in share links and what we hand to the
///    Repo. For boards we create locally this is derived once from
///    `id` via `DocumentId(uuid).id`; for boards we joined via a
///    share link it's whatever the peer used.
///
/// The string form is stored (not the `DocumentId` struct) because
/// `DocumentId`'s byte data is `internal` to the package, so we
/// can't round-trip through it during `Codable`.
struct BoardSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    /// Optional in the JSON form so older indices (Phase 1, before
    /// sync existed) decode without migration. At runtime always
    /// use `documentIdString` / `documentId`, which fill in the
    /// default for legacy summaries.
    private var _documentIdString: String?

    init(id: UUID, name: String, createdAt: Date, updatedAt: Date,
         documentIdString: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self._documentIdString = documentIdString
    }

    /// bs58 sync identity. Falls back to `DocumentId(id).id` for
    /// locally-created boards that pre-date sync.
    var documentIdString: String {
        _documentIdString ?? Self.derivedDocumentIdString(from: id)
    }

    /// The sync-identity string a locally-created board would get
    /// for a given UUID. Exposed for tests so they don't have to
    /// import AutomergeRepo to construct expected values.
    static func derivedDocumentIdString(from id: UUID) -> String {
        DocumentId(id).id
    }

    /// The DocumentId we hand to `Repo`. Force-unwrapping is safe
    /// here because `documentIdString` is always either something
    /// we stored after `DocumentId(...).id` (well-formed by
    /// construction) or the default derived from a UUID (also
    /// well-formed). A failure here means the index file was
    /// corrupted out-of-band.
    var documentId: DocumentId {
        DocumentId(documentIdString)!
    }
}

enum BoardLibraryError: Error {
    case missingBoardFile(UUID)
    case unknownBoard(UUID)
}

@MainActor
final class BoardLibrary: ObservableObject {

    @Published private(set) var boards: [BoardSummary] = []

    /// Sync layer. We hold the Repo + WebSocketProvider for the
    /// app's lifetime; tearing them down only happens when the
    /// library itself is released.
    let repo: Repo
    let webSocket: WebSocketProvider

    /// Observable adapter around `webSocket` so views can show
    /// connection state without each holding their own Combine
    /// subscription.
    let syncStatus: SyncStatusObserver

    /// URL of the relay this library connects to. Default is the
    /// local Node.js sync-server in this repo; can be overridden
    /// (e.g. for tests, or to point at production).
    let relayURL: URL

    private let rootURL: URL
    private var openStores: [UUID: BoardStore] = [:]
    private var saveSubs: [UUID: AnyCancellable] = [:]
    private let saveDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(400)

    // MARK: - Init

    convenience init() throws {
        try self.init(rootURL: Self.defaultRootURL())
    }

    init(
        rootURL: URL,
        relayURL: URL = URL(string: "ws://localhost:3030")!
    ) throws {
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        self.relayURL = relayURL

        // `SharePolicy.agreeable` shares any doc we know about with
        // any peer that asks. That's what we want — the relay (which
        // has the opposite policy and only relays) decides who
        // actually sees what by routing connections.
        self.repo = Repo(sharePolicy: SharePolicy.agreeable)
        self.webSocket = WebSocketProvider(
            .init(reconnectOnError: true, loggingAt: .errorOnly))
        self.syncStatus = SyncStatusObserver(provider: self.webSocket)

        try loadIndex()
        startSync()
    }

    /// Kick off the network adapter + relay connection in the
    /// background. We don't await on this in init because:
    ///   • If the relay is down (common in tests, dev, planes), we
    ///     still want the library usable — local-only boards work
    ///     without any network at all.
    ///   • Repo calls cross actor boundaries; we just queue the
    ///     setup and let it run.
    private func startSync() {
        let repo = self.repo
        let webSocket = self.webSocket
        let relayURL = self.relayURL
        Task.detached {
            await repo.addNetworkAdapter(adapter: webSocket)
            do {
                try await webSocket.connect(to: relayURL)
            } catch {
                // Don't crash — the provider will retry per its
                // reconnectOnError config. We just log loudly so it
                // shows up in console while debugging.
                print("BoardLibrary: initial connect to \(relayURL) failed: \(error)")
            }
        }
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

    /// Create a new empty board, register it with the Repo for
    /// sync, and persist its initial bytes.
    @discardableResult
    func createBoard(name: String) async throws -> BoardSummary {
        let now = Date()
        let summary = BoardSummary(
            id: UUID(), name: name, createdAt: now, updatedAt: now)

        // Repo allocates the underlying Document; we adopt it so the
        // store's `objectDidChange` subscription sees both local
        // edits and incoming sync messages.
        let handle = try await repo.create(id: summary.documentId)
        let store = try BoardStore(adopting: handle.doc)

        try store.save().write(to: boardURL(id: summary.id), options: .atomic)
        boards.insert(summary, at: 0)
        try writeIndex()
        openStores[summary.id] = store
        startAutoSave(for: summary.id, store: store)
        return summary
    }

    /// Open a previously-created board. Reads the Automerge bytes
    /// from disk, hands them to the Repo for sync registration,
    /// and caches the resulting store.
    func openBoard(id: UUID) async throws -> BoardStore {
        if let cached = openStores[id] { return cached }
        guard let summary = boards.first(where: { $0.id == id }) else {
            throw BoardLibraryError.unknownBoard(id)
        }
        let url = boardURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BoardLibraryError.missingBoardFile(id)
        }
        let data = try Data(contentsOf: url)
        let doc = try Automerge.Document(data)
        // Use the board's stored documentId (not DocumentId(id)) so
        // boards joined via a share link register under the peer's
        // identity, not a UUID-derived stranger.
        let handle = DocHandle(id: summary.documentId, doc: doc)
        _ = try await repo.import(handle: handle)

        let store = try BoardStore(adopting: doc)
        openStores[id] = store
        startAutoSave(for: id, store: store)
        return store
    }

    /// Join a board shared by a peer. We don't have local bytes
    /// yet, so we ask the Repo to `find` it across connected
    /// peers. Once it arrives, we persist its bytes so the board
    /// works offline next launch.
    ///
    /// The new local `BoardSummary` gets a fresh UUID (for file
    /// naming etc.) plus the bs58 `documentIdString` from the share
    /// link, so the peer's identity is preserved without us having
    /// to derive a UUID from it.
    @discardableResult
    func joinBoard(documentId: DocumentId, name: String) async throws -> BoardSummary {
        // If we already have it locally (matched by sync identity),
        // just re-open it instead of creating a duplicate row.
        let docIdString = documentId.id
        if let existing = boards.first(where: { $0.documentIdString == docIdString }) {
            _ = try await openBoard(id: existing.id)
            return existing
        }

        let handle = try await repo.find(id: documentId)
        let now = Date()
        let summary = BoardSummary(
            id: UUID(), name: name,
            createdAt: now, updatedAt: now,
            documentIdString: docIdString)

        let store = try BoardStore(adopting: handle.doc)
        try store.save().write(to: boardURL(id: summary.id), options: .atomic)
        boards.insert(summary, at: 0)
        try writeIndex()
        openStores[summary.id] = store
        startAutoSave(for: summary.id, store: store)
        return summary
    }

    /// Delete a board everywhere we know about it. Idempotent.
    func deleteBoard(id: UUID) throws {
        openStores.removeValue(forKey: id)
        saveSubs.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: boardURL(id: id))
        boards.removeAll { $0.id == id }
        try writeIndex()
        // Note: we don't remove the doc from the Repo here. The Repo's
        // `delete(id:)` is async and would also tell peers to forget
        // it — possibly too aggressive for a local delete. Revisit
        // when we add an explicit "leave board" affordance.
    }

    func rename(id: UUID, to newName: String) throws {
        guard let idx = boards.firstIndex(where: { $0.id == id }) else {
            throw BoardLibraryError.unknownBoard(id)
        }
        boards[idx].name = newName
        boards[idx].updatedAt = Date()
        try writeIndex()
    }

    /// Synchronous write of the current bytes for a board. Useful
    /// for tests and for scene-lifecycle hooks ("app backgrounding —
    /// flush everything now").
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
