// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The conversation screen's small decisions about a thread, as pure functions:
// note-to-self, the blockable sender, the user's locked reaction, and the
// message the Web View opens straight into.

import XCTest
@testable import ZirbeCore

final class ConversationRulesTests: XCTestCase {
    private let account = Account(emailAddress: "Me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    private let me = Participant(address: "me@x.com")
    private let pat = Participant(address: "pat@x.com", displayName: "Pat")
    private let sam = Participant(address: "sam@x.com", displayName: "Sam")

    private func message(_ id: String, from: Participant, to: [Participant], minutes: Int, hasHTML: Bool = false) -> Message {
        Message(
            messageID: id,
            subject: "Plan",
            from: from,
            to: to,
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            hasHTML: hasHTML
        )
    }

    private func reaction(_ emoji: String, on target: String, from: Participant, minutes: Int) -> Message {
        Message(
            messageID: "<r\(minutes)@x>",
            inReplyTo: target,
            from: from,
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            reaction: emoji
        )
    }

    private func thread(_ messages: [Message]) -> ZirbeCore.Thread {
        ZirbeCore.Thread(id: "t", subject: "Plan", messages: messages, participants: [], lastActivity: nil)
    }

    // MARK: Note to self

    func testAThreadOfTheUserAloneIsANoteToSelf() {
        let note = thread([message("<a@x>", from: me, to: [me], minutes: 0)])
        XCTAssertTrue(note.isNoteToSelf(as: account))
    }

    func testAThreadWithAnyoneElseIsNot() {
        let incoming = thread([message("<a@x>", from: pat, to: [me], minutes: 0)])
        XCTAssertFalse(incoming.isNoteToSelf(as: account))

        let outgoing = thread([message("<a@x>", from: me, to: [me, sam], minutes: 0)])
        XCTAssertFalse(outgoing.isNoteToSelf(as: account))
    }

    // MARK: Blockable sender

    func testTheMostRecentIncomingSenderIsBlockable() {
        let t = thread([
            message("<a@x>", from: pat, to: [me], minutes: 0),
            message("<b@x>", from: sam, to: [me], minutes: 5),
            message("<c@x>", from: me, to: [pat, sam], minutes: 10),
        ])
        XCTAssertEqual(t.blockableSender(as: account)?.address, "sam@x.com", "the user's own reply is skipped")
    }

    func testAThreadOfOnlyOwnMessagesHasNoOneToBlock() {
        let t = thread([
            message("<a@x>", from: me, to: [pat], minutes: 0),
            message("<b@x>", from: me, to: [me], minutes: 5),
        ])
        XCTAssertNil(t.blockableSender(as: account))
    }

    func testTheSummaryFallbackPicksTheFirstOtherParticipant() {
        let summary = ThreadSummary(
            id: "t", subject: "Plan", participants: [me, pat, sam], lastActivity: nil,
            isUnread: false, isFlagged: false, isPinned: false, messageCount: 3, preview: nil
        )
        XCTAssertEqual(summary.blockableSender(as: account)?.address, "pat@x.com")

        let alone = ThreadSummary(
            id: "t", subject: "Note", participants: [me], lastActivity: nil,
            isUnread: false, isFlagged: false, isPinned: false, messageCount: 1, preview: nil
        )
        XCTAssertNil(alone.blockableSender(as: account))
    }

    // MARK: Locked reaction

    func testOnlyTheUsersOwnSentReactionLocksThePicker() {
        let t = thread([
            message("<a@x>", from: pat, to: [me], minutes: 0),
            reaction("❤️", on: "<a@x>", from: sam, minutes: 1),
            reaction("👍", on: "<a@x>", from: me, minutes: 2),
        ])
        XCTAssertEqual(t.myReaction(on: "<a@x>", as: account), "👍")
        XCTAssertNil(t.myReaction(on: "<zzz@x>", as: account))
        XCTAssertNil(t.myReaction(on: String?.none, as: account))

        let theirs = thread([
            message("<a@x>", from: pat, to: [me], minutes: 0),
            reaction("❤️", on: "<a@x>", from: sam, minutes: 1),
        ])
        XCTAssertNil(theirs.myReaction(on: "<a@x>", as: account), "someone else's reaction doesn't lock mine")
    }

    // MARK: Copyable text

    func testCopyableTextIsTheVisibleBodyWithoutTheQuote() {
        var m = message("<a@x>", from: pat, to: [me], minutes: 0)
        m.bodyText = "Yes, noon works.\n\nOn Mon, Pat wrote:\n> Lunch?\n> Noon?"
        XCTAssertEqual(m.copyableText, "Yes, noon works.")

        m.bodyText = "  Plain reply  "
        XCTAssertEqual(m.copyableText, "Plain reply")
    }

    func testBubblesWithNothingToCopyOfferNothing() {
        var m = message("<a@x>", from: pat, to: [me], minutes: 0)
        m.bodyText = nil
        XCTAssertNil(m.copyableText, "a photo or voice message with no words")
        m.bodyText = " \n "
        XCTAssertNil(m.copyableText)
        m.bodyText = "On Mon, Pat wrote:\n> Lunch?"
        XCTAssertNil(m.copyableText, "nothing but a quote")
    }

    // MARK: Web View opener

    func testTheNewestMessageOpensInTheWebViewOnlyWhenItHasHTML() {
        let html = thread([
            message("<a@x>", from: pat, to: [me], minutes: 0),
            message("<b@x>", from: pat, to: [me], minutes: 5, hasHTML: true),
        ])
        XCTAssertEqual(html.latestHTMLMessage?.messageID, "<b@x>")

        let plain = thread([
            message("<a@x>", from: pat, to: [me], minutes: 0, hasHTML: true),
            message("<b@x>", from: pat, to: [me], minutes: 5),
        ])
        XCTAssertNil(plain.latestHTMLMessage, "an older HTML message doesn't open when the newest is plain")
    }

    func testATrailingReactionDoesNotHideTheHTMLMessage() {
        let t = thread([
            message("<a@x>", from: pat, to: [me], minutes: 0, hasHTML: true),
            reaction("👍", on: "<a@x>", from: sam, minutes: 1),
        ])
        XCTAssertEqual(t.latestHTMLMessage?.messageID, "<a@x>")
    }
}
