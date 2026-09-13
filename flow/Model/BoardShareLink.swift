//
//  ShareLink.swift
//  flow
//
//  Parsing for board share links. Exactly one place understands the
//  `sceneflow://board/<documentId>?name=<title>` format, so the OS
//  URL-scheme handler (flowApp) and the paste-to-join sheet
//  (BoardListView) can never drift apart on what counts as valid.
//
//  Tolerant of the shapes people actually paste:
//   • sceneflow://board/<id>?name=Title   — what ShareBoardSheet generates
//   • sceneflow:/board/<id>               — sloppy re-paste (host folds into path)
//   • <id>                                — the bare bs58 token
//  Surrounding whitespace/newlines are trimmed first.
//
//  Validity is delegated to `DocumentId(String)`, which base58check-
//  decodes and requires 16 bytes — so random pasted text can't
//  produce a "valid" join target.
//

import Foundation
import AutomergeRepo

enum BoardShareLink {

    /// What a share link carries: the sync identity to join, plus
    /// (optionally) the sharer's board title so the joined-side row
    /// can read "<title> - shared" instead of an anonymous name.
    struct Payload: Equatable {
        let documentId: DocumentId
        let senderName: String?
    }

    /// Parse pasted text or a routed URL string into a join payload.
    /// Returns nil when the text can't be a board share link.
    static func parse(_ text: String) -> Payload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bare token: just the bs58 DocumentId, no URL dressing.
        if let docId = DocumentId(trimmed) {
            return Payload(documentId: docId, senderName: nil)
        }

        guard let url = URL(string: trimmed), url.scheme == "sceneflow" else {
            return nil
        }
        // Two shapes: `sceneflow://board/<id>` puts "board" in the
        // host; `sceneflow:/board/<id>` folds it into the path.
        let path = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2, path[0] == "board", let docId = DocumentId(path[1]) else {
            return nil
        }

        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "name" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Payload(
            documentId: docId,
            senderName: (name?.isEmpty == false) ? name : nil)
    }
}
