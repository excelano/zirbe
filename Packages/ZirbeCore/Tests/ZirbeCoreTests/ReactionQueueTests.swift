// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The reaction undo window: a reaction is pending at once, sent only after the
// window, and can be toggled off, replaced, undone, or flushed early. Runs with
// a short window so a real timer is exercised without slowing the suite.

import XCTest
@testable import ZirbeCore

@MainActor
final class ReactionQueueTests: XCTestCase {
    private var queue: ReactionQueue!
    private var committed: [(emoji: String, messageID: String)] = []

    override func setUp() {
        queue = ReactionQueue(undoWindow: .milliseconds(40))
        committed = []
        queue.onCommit = { [unowned self] emoji, id in committed.append((emoji, id)) }
    }

    /// Wait for the timers to run: comfortably past the window.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    func testAReactionIsPendingAtOnceAndSentAfterTheWindow() async {
        queue.react("👍", to: "<a@x>")

        XCTAssertEqual(queue.pendingEmoji(for: "<a@x>"), "👍")
        XCTAssertTrue(committed.isEmpty, "nothing goes out inside the window")

        await settle()
        XCTAssertNil(queue.pendingEmoji(for: "<a@x>"))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(committed.map(\.emoji), ["👍"])
        XCTAssertEqual(committed.map(\.messageID), ["<a@x>"])
    }

    func testTappingThePendingEmojiAgainTakesItBack() async {
        queue.react("👍", to: "<a@x>")
        queue.react("👍", to: "<a@x>")

        XCTAssertNil(queue.pendingEmoji(for: "<a@x>"))
        await settle()
        XCTAssertTrue(committed.isEmpty)
    }

    func testADifferentEmojiReplacesThePendingOneAndOnlyItIsSent() async {
        queue.react("👍", to: "<a@x>")
        queue.react("❤️", to: "<a@x>")

        XCTAssertEqual(queue.pendingEmoji(for: "<a@x>"), "❤️")
        await settle()
        XCTAssertEqual(committed.map(\.emoji), ["❤️"])
    }

    func testUndoInsideTheWindowSendsNothing() async {
        queue.react("👍", to: "<a@x>")
        queue.undo("<a@x>")

        XCTAssertNil(queue.pendingEmoji(for: "<a@x>"))
        await settle()
        XCTAssertTrue(committed.isEmpty)
    }

    func testFlushSendsEveryPendingReactionNow() async {
        queue.react("👍", to: "<a@x>")
        queue.react("😂", to: "<b@x>")

        queue.flush()
        XCTAssertTrue(queue.isEmpty)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(Set(committed.map(\.messageID)), ["<a@x>", "<b@x>"])
        await settle()
        XCTAssertEqual(committed.count, 2, "the cancelled timers don't send a second time")
    }

    func testEachMessageKeepsItsOwnReaction() {
        queue.react("👍", to: "<a@x>")
        queue.react("👎", to: "<b@x>")

        XCTAssertEqual(queue.pendingEmoji(for: "<a@x>"), "👍")
        XCTAssertEqual(queue.pendingEmoji(for: "<b@x>"), "👎")
        XCTAssertNil(queue.pendingEmoji(for: nil), "a bubble without a Message-ID has nothing pending")
    }

    func testAQueueWithoutAHandlerDropsTheCommitQuietly() async {
        queue.onCommit = nil
        queue.react("👍", to: "<a@x>")

        await settle()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(committed.isEmpty)
    }
}
