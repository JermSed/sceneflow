//
//  ShareLinkTests.swift
//  flowTests
//
//  The share-link format contract: whatever `ShareBoardSheet`
//  generates and whatever a human plausibly pastes must parse to the
//  same join target — and random text must never parse at all
//  (`DocumentId`'s base58check validation is the gate).
//

import Testing
import Foundation
@testable import flow

struct ShareLinkTests {

    /// A well-formed bs58 token, derived the same way the app does.
    private let token = BoardSummary.derivedDocumentIdString(from: UUID())

    @Test func fullShareURL_parses() throws {
        let payload = try #require(BoardShareLink.parse("sceneflow://board/\(token)"))
        #expect(payload.documentId.id == token)
        #expect(payload.senderName == nil)
    }

    @Test func shareURLWithName_carriesSenderName() throws {
        let payload = try #require(BoardShareLink.parse("sceneflow://board/\(token)?name=Act%20One"))
        #expect(payload.documentId.id == token)
        #expect(payload.senderName == "Act One")
    }

    @Test func sloppySingleSlashForm_parses() throws {
        let payload = try #require(BoardShareLink.parse("sceneflow:/board/\(token)"))
        #expect(payload.documentId.id == token)
    }

    @Test func bareToken_parses() throws {
        let payload = try #require(BoardShareLink.parse("  \(token)\n"))
        #expect(payload.documentId.id == token)
        #expect(payload.senderName == nil)
    }

    @Test func garbage_doesNotParse() {
        #expect(BoardShareLink.parse("") == nil)
        #expect(BoardShareLink.parse("hello world") == nil)
        #expect(BoardShareLink.parse("https://example.com/board/\(token)") == nil)
        #expect(BoardShareLink.parse("sceneflow://nope/\(token)") == nil)
        #expect(BoardShareLink.parse("sceneflow://board/not-a-real-token") == nil)
    }
}
