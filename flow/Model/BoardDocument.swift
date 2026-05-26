//
//  BoardDocument.swift
//  flow
//
//  Phase 0 — wraps an `Automerge.Document` so the rest of the app never
//  has to talk to the CRDT API directly. Two reasons we want this seam:
//
//   1. CLAUDE.md says automerge-swift is pre-1.0 and the API can shift.
//      Keeping every Automerge call inside this file means a future
//      version bump touches one place, not the whole codebase.
//
//   2. Views must stay free of CRDT concepts. They see a plain
//      `CanvasDoc` value; this type handles encode / decode / persist /
//      merge against the underlying `Automerge.Document`.
//
//  How automerge-swift's Codable bridge works (verified against
//  automerge-swift 0.7.2):
//   • You build an `AutomergeEncoder(doc:)` and call `encode(swiftValue)`.
//     The encoder walks the Codable tree and writes each struct as an
//     Automerge map and each Swift array as an Automerge list.
//   • The reverse is `AutomergeDecoder(doc:).decode(SomeType.self)`.
//   • `Document.save()` returns a `Data` blob (does NOT throw). The blob
//     is the full compressed change history, suitable for writing to disk.
//   • `Document(_ bytes: Data)` is the load entry point — throws if the
//     bytes aren't a valid Automerge document.
//   • `Document.merge(other:)` folds another doc's changes in. This is
//     what we'll use in Phase 2 when sync arrives; harmless to expose now.
//
//  Note on identifiers (`UUID`): Automerge doesn't have a native UUID
//  scalar. `Codable` encodes `UUID` as a string, which is fine — string
//  equality is stable across save / load round-trips.
//

import Foundation
import Automerge

/// A board's collaborative document. Holds the live `Automerge.Document`
/// plus convenience methods for the rest of the app.
///
/// Thread safety: `Automerge.Document` is `@unchecked Sendable` and
/// guarded internally by a recursive lock, but the encoder / decoder
/// operations are NOT individually atomic across multiple calls. Treat a
/// `BoardDocument` as owned by one actor / thread at a time; we'll
/// formalize that with `@MainActor` or a dedicated actor when we wire it
/// into the app in Phase 1.
final class BoardDocument {

    /// The underlying CRDT. Exposed `internal` (not `private`) so future
    /// sync code can hand it to a Repo or call `save()` directly — but no
    /// view code should reach in here.
    let doc: Automerge.Document

    // MARK: - Init

    /// Create a fresh board containing an empty `CanvasDoc` at the root.
    init() throws {
        self.doc = Automerge.Document()
        try AutomergeEncoder(doc: doc).encode(CanvasDoc.empty)
    }

    /// Load a board from saved bytes (e.g. from disk or a sync peer).
    ///
    /// Throws if the bytes aren't a valid Automerge document or if the
    /// document's root doesn't decode as a `CanvasDoc`. We decode once
    /// here as a sanity check so a corrupted file fails loudly at load
    /// time instead of mid-edit.
    init(data: Data) throws {
        self.doc = try Automerge.Document(data)
        _ = try AutomergeDecoder(doc: doc).decode(CanvasDoc.self)
    }

    // MARK: - Snapshot the Swift value

    /// Pull the current state out of the CRDT as a plain Swift value.
    /// Views and tests use this; they never see the Automerge doc itself.
    func snapshot() throws -> CanvasDoc {
        try AutomergeDecoder(doc: doc).decode(CanvasDoc.self)
    }

    /// Overwrite the entire document tree with `value`. Phase 0 only —
    /// real editing in Phase 1+ will mutate the doc at finer-grained
    /// paths so concurrent edits actually merge (re-encoding the whole
    /// tree would defeat the CRDT).
    func replace(with value: CanvasDoc) throws {
        try AutomergeEncoder(doc: doc).encode(value)
    }

    // MARK: - Persistence

    /// Serialize the full change history to a `Data` blob. Note: does
    /// NOT throw in automerge-swift 0.7.2.
    func save() -> Data {
        doc.save()
    }

    // MARK: - Sync (used in Phase 2)

    /// Fold another board's changes into this one. Automerge handles the
    /// conflict resolution per the rules baked into the document model
    /// (append-only lists merge by concatenation in causal order;
    /// scalars resolve last-write-wins).
    func merge(_ other: BoardDocument) throws {
        try doc.merge(other: other.doc)
    }
}
