//
//  AgentInteropTests.swift
//  flowTests
//
//  The Swift half of the cross-runtime schema contract with the board
//  assistant (agent/ in this repo — a headless JS peer that joins
//  boards through the sync relay and replies to @assistant comments).
//
//  The fixture bytes below were produced by `node agent/scripts/
//  make-fixture.js`: a board seeded with the Swift root shape, one
//  user comment, and one agent reply written through the agent's real
//  `makeReplyComment()` code path. The JS "next" API has one trap
//  that makes this test load-bearing: a plain JS string becomes an
//  Automerge Text OBJECT, which `AutomergeDecoder` rejects for Swift
//  `String` fields — the whole CanvasDoc decode would throw and the
//  board would fail to open. The agent guards this by wrapping every
//  string in RawString; this test is what keeps that guard honest.
//
//  Regenerate the fixture after any agent schema change:
//    cd agent && node scripts/make-fixture.js
//

import Testing
import Foundation
@testable import flow

struct AgentInteropTests {

    /// Output of agent/scripts/make-fixture.js (see header).
    private static let agentFixtureBase64 = """
        hW9Kgx+MtnAA7QQBEKHLELnceEx5l66Nw1veS4wBg+pHZvaKQFN81YQn9wjJmDcXFQuh5IOAiQ7+MjXbZsMHAQIDAhMDIwdAA0MCVgIMAQQCChEGEwcVwgEhAiMeNANCCFYiX80BgAECAgACAX4RC37gzcXSBgB+AAF/AAIHAAYWAAAGfwICBgkIChIACH8AABMAB34ACAATeQxhY3RpdmVTa2V0Y2gIY29tbWVudHMKY29ubmVjdG9ycwZpbWFnZXMJc25hcHNob3RzBXRleHRzB3N0cm9rZXMAAm0KYXV0aG9yTmFtZQxhdXRob3JQZWVySWQJY3JlYXRlZEF0AmlkCmlzUmVzb2x2ZWQEdGV4dAF4AXkBegphdXRob3JOYW1lDGF1dGhvclBlZXJJZAljcmVhdGVkQXQCaWQKaXNSZXNvbHZlZAdyZXBseVRvBHRleHQBeAF5AXocAHACBAF+fAN/BQp8fwN5CH57AgF4DH8DeQgBfXsCAQcCE38ABgICABMBCQB6RtYBacYEAYYHAoUBeBSWAbYCacYEAcYEpgcChQF/FI2OMU7EMBREEVzkX8AoicOSDkcGOq6AZJxhY2llr/ydjegibsVZqKgoaZYeJ8Bqy51ivkbzNXoP5sV02DkLsQWiKKfXj/e9LP8k2ixRz9bMVh5JGWbHyfhEjin1iCD4MKx7smGHaNagJ6QR8HPLczKJb84WParlqEGdt/87bOHxvAmjOEx/v31+7WVR69uroi7FqtF3GaeoMlglRXW90lLK+r5t9CnIOnh2HSIZT84zYiLuQzrGpDE/5L5bgt0Ehhi2lwvsZH+hp1Fd/AAcAAE=
        """

    private func loadFixture() throws -> BoardDocument {
        let data = try #require(Data(base64Encoded: Self.agentFixtureBase64
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")))
        // BoardDocument(data:) sanity-decodes the whole CanvasDoc on
        // load — if the agent wrote a scalar type Swift can't decode,
        // this line throws and the test fails right here.
        return try BoardDocument(data: data)
    }

    @Test func agentAuthoredBoardDecodes() throws {
        let canvas = try loadFixture().snapshot()

        #expect(canvas.comments.count == 2)

        let question = canvas.comments[0]
        #expect(question.authorName == "Maya")
        #expect(question.text.contains("@assistant"))
        #expect(question.replyTo == nil)

        let reply = canvas.comments[1]
        #expect(reply.authorPeerId == "sceneflow-assistant")
        #expect(reply.authorName == "Assistant")
        // JS Float64(120 + 36) must land as a Swift Double.
        #expect(reply.x == 156)
        #expect(reply.y == 376)
        // JS integer z must decode into Swift Int.
        #expect(reply.z == 3)
        #expect(reply.isResolved == false)
        // The threading link that drives the agent's dedupe.
        #expect(reply.replyTo == question.id)
        // JS Date -> Automerge timestamp -> Swift Date, sane value.
        #expect(reply.createdAt.timeIntervalSince1970 > 0)
    }

    /// After adopting agent-touched bytes, the app must be able to keep
    /// editing — the normal mutation path, not just read-only decode.
    @Test func swiftCanEditAgentTouchedBoard() throws {
        let board = try loadFixture()
        let original = try board.snapshot().comments[0]

        try board.addComment(Comment(
            id: UUID(), x: 10, y: 20, z: 5,
            authorPeerId: "device-peer-1", authorName: "Maya",
            text: "thanks!", createdAt: Date(), isResolved: false,
            replyTo: original.id))
        try board.setCommentResolved(id: original.id, resolved: true)

        let canvas = try board.snapshot()
        #expect(canvas.comments.count == 3)
        #expect(canvas.comments[0].isResolved)
        #expect(canvas.comments[2].replyTo == original.id)

        // And the whole thing still round-trips through save/load.
        let reloaded = try BoardDocument(data: board.save()).snapshot()
        #expect(reloaded.comments.count == 3)
    }

    /// Boards that predate `replyTo` (every comment written by the app
    /// so far) must keep decoding: absent key → nil.
    @Test func commentsWithoutReplyToStillDecode() throws {
        let board = try BoardDocument()
        try board.addComment(Comment(
            id: UUID(), x: 1, y: 2, z: 1,
            authorPeerId: "p", authorName: "n",
            text: "no threading here", createdAt: Date(), isResolved: false))
        let reloaded = try BoardDocument(data: board.save()).snapshot()
        #expect(reloaded.comments[0].replyTo == nil)
    }
}
