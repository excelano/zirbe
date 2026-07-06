import XCTest
import ZirbeMail
@testable import ZirbeCore

/// Reactions (tapbacks): the outgoing draft shape, the thread-level aggregation
/// that turns reaction messages into badges, the readable degrade body, and the
/// store filtering that keeps a reaction out of the unread and new-mail counts.
final class ReactionTests: XCTestCase {
    private func account() -> Account {
        Account(emailAddress: "me@x.com", displayName: "Me", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func participant(_ address: String, _ name: String? = nil) -> Participant {
        Participant(address: address, displayName: name)
    }

    /// A one-message thread whose lone message is from Pat, addressed to me and
    /// Cc'd to a third party, so a reaction's reply-all lands the way a reply's
    /// would.
    private func thread(bodyText: String = "the question") -> ZirbeCore.Thread {
        let m = Message(
            messageID: "<a@x>",
            references: ["<root@x>"],
            subject: "Plan",
            from: participant("pat@x.com", "Pat"),
            to: [participant("me@x.com")],
            cc: [participant("cc@x.com")],
            date: Date(timeIntervalSince1970: 0),
            flags: [.seen],
            bodyText: bodyText
        )
        return ZirbeCore.Thread(id: "mid:<a@x>", subject: "Plan", messages: [m],
                                participants: [], lastActivity: m.date)
    }

    private func reactionMessage(
        id: String, target: String, emoji: String, from: String, at seconds: TimeInterval, seen: Bool = false
    ) -> Message {
        Message(
            messageID: id,
            inReplyTo: target,
            from: participant(from),
            date: Date(timeIntervalSince1970: seconds),
            flags: seen ? [.seen] : [],
            reaction: emoji
        )
    }

    // MARK: - Outgoing draft

    func testReactionThreadsOntoTheTargetMessage() {
        let t = thread()
        let draft = OutgoingDraft.reaction(to: t.messages[0], in: t, as: account(), emoji: "👍")
        // In-Reply-To points at the reacted-to message specifically, and References
        // extends its chain, so the reaction slots beneath it in the thread.
        XCTAssertEqual(draft.inReplyTo, "<a@x>")
        XCTAssertEqual(draft.references, ["<root@x>", "<a@x>"])
        XCTAssertEqual(draft.subject, "Re: Plan")
        XCTAssertEqual(draft.reaction, "👍")
        XCTAssertEqual(draft.from.address, "me@x.com")
    }

    func testReactionRecipientsAreReplyAllLessSelf() {
        let t = thread()
        let draft = OutgoingDraft.reaction(to: t.messages[0], in: t, as: account(), emoji: "❤️")
        // Everyone on the thread but me, so a group sees the reaction.
        XCTAssertEqual(draft.to.map(\.address), ["pat@x.com"])
        XCTAssertEqual(draft.cc.map(\.address), ["cc@x.com"])
    }

    func testReactionCarriesHeaderOnWireAndEmojiOnLocalCopy() {
        let t = thread()
        let draft = OutgoingDraft.reaction(to: t.messages[0], in: t, as: account(), emoji: "😂")
        // The emoji rides out as the X-Zirbe-Reaction header for a receiving Zirbe.
        XCTAssertEqual(draft.outgoingMessage.headers[MailHeader.zirbeReaction], "😂")
        // And is stamped on the optimistic local copy so the badge shows at once.
        XCTAssertEqual(draft.localMessage.reaction, "😂")
        XCTAssertTrue(draft.localMessage.isReaction)
    }

    func testReactionBodyDegradesReadablyForOtherClients() {
        let t = thread(bodyText: "the question")
        let draft = OutgoingDraft.reaction(to: t.messages[0], in: t, as: account(), emoji: "👍")
        // A client that ignores the header still shows a sensible line.
        XCTAssertTrue(draft.body.hasPrefix("Reacted 👍 to "))
        XCTAssertTrue(draft.body.contains("the question"))
    }

    func testEnvelopeReactionHeaderMapsIntoTheMessage() {
        let env = MailEnvelope(
            uid: 5, subject: "Re: Plan", from: "sam@x.com",
            messageID: "<r@x>", inReplyTo: "<a@x>", reaction: "👍"
        )
        let m = Message(env)
        XCTAssertEqual(m.reaction, "👍")
        XCTAssertTrue(m.isReaction)
        XCTAssertEqual(m.inReplyTo, "<a@x>")
    }

    // MARK: - Degrade body

    func testDegradeBodyFallsBackToSubjectThenBare() {
        let noBody = Message(messageID: "<b@x>", subject: "Lunch", from: participant("p@x.com"), bodyText: nil)
        XCTAssertEqual(ReactionText.body(emoji: "👍", target: noBody), "Reacted 👍 to \u{201C}Lunch\u{201D}")

        let nothing = Message(messageID: "<c@x>", subject: nil, from: participant("p@x.com"), bodyText: nil)
        XCTAssertEqual(ReactionText.body(emoji: "👍", target: nothing), "Reacted 👍")
    }

    func testDegradeBodyTruncatesALongExcerpt() {
        let long = "This is a really long message body that should be truncated for the reaction excerpt line"
        let m = Message(messageID: "<d@x>", from: participant("p@x.com"), bodyText: long)
        let body = ReactionText.body(emoji: "❤️", target: m)
        XCTAssertTrue(body.hasSuffix("\u{2026}\u{201D}")) // ends with an ellipsis inside the closing quote
        XCTAssertLessThan(body.count, long.count)
    }

    // MARK: - Thread aggregation

    func testReactionsGroupByTargetAndLatestPerReactorWins() {
        var t = thread()
        t.messages.append(reactionMessage(id: "<r1@x>", target: "<a@x>", emoji: "👍", from: "pat@x.com", at: 10))
        t.messages.append(reactionMessage(id: "<r2@x>", target: "<a@x>", emoji: "❤️", from: "sam@x.com", at: 20))
        // Pat changes their reaction; the later one supersedes.
        t.messages.append(reactionMessage(id: "<r3@x>", target: "<a@x>", emoji: "😂", from: "pat@x.com", at: 30))

        let reactions = t.reactions(forMessageID: "<a@x>")
        XCTAssertEqual(reactions.count, 2)
        let byPerson = Dictionary(uniqueKeysWithValues: reactions.map { ($0.reactor.address, $0.emoji) })
        XCTAssertEqual(byPerson["pat@x.com"], "😂") // latest wins, not stacked
        XCTAssertEqual(byPerson["sam@x.com"], "❤️")
    }

    func testReactionsAreExcludedFromBubblesUnreadAndCount() {
        var t = thread() // the one base message is seen
        t.messages.append(reactionMessage(id: "<r1@x>", target: "<a@x>", emoji: "👍", from: "pat@x.com", at: 10))

        // The bubble stream and the count are the chat messages only.
        XCTAssertEqual(t.conversationMessages.map(\.messageID), ["<a@x>"])
        XCTAssertEqual(t.messageCount, 1)
        // An unseen reaction must not bold the thread.
        XCTAssertFalse(t.isUnread)
    }

    // MARK: - Store round-trip and filtering

    func testStorePersistsReactionAndKeepsItOutOfArrivalsAndUnread() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let base = Message(
            messageID: "<a@x>", uid: 1, subject: "Plan",
            from: participant("pat@x.com"), date: Date(timeIntervalSince1970: 0), flags: []
        )
        let reaction = reactionMessage(id: "<r1@x>", target: "<a@x>", emoji: "👍", from: "sam@x.com", at: 60)
        var withUID = reaction
        withUID.uid = 2
        try await store.save([base, withUID], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        // The reaction round-trips its emoji and threads onto the base as a badge.
        let loaded = try await store.thread(id: "mid:<a@x>")
        XCTAssertEqual(loaded?.reactions(forMessageID: "<a@x>").first?.emoji, "👍")
        XCTAssertEqual(loaded?.conversationMessages.count, 1)

        // New-mail and unread counts see the base message but never the reaction.
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertEqual(arrivals.map(\.subject), ["Plan"])
        let unread = try await store.unreadCounts(accountID: acct.id)
        XCTAssertEqual(unread["INBOX"], 1)
    }
}
