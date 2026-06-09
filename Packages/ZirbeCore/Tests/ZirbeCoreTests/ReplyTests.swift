import XCTest
@testable import ZirbeCore

final class ReplyTests: XCTestCase {
    private func account() -> Account {
        Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func participant(_ address: String, _ name: String? = nil) -> Participant {
        Participant(address: address, displayName: name)
    }

    private func message(
        id: String,
        from: String,
        to: [String] = [],
        cc: [String] = [],
        references: [String] = [],
        minutes: Int
    ) -> Message {
        Message(
            messageID: id,
            references: references,
            subject: "Plan",
            from: participant(from),
            to: to.map { participant($0) },
            cc: cc.map { participant($0) },
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: [.seen]
        )
    }

    private func thread(_ messages: [Message]) -> ZirbeCore.Thread {
        ZirbeCore.Thread(id: "mid:\(messages.first?.messageID ?? "?")", subject: "Plan",
                         messages: messages, participants: [], lastActivity: messages.last?.date)
    }

    // MARK: - Reply-all recipients

    func testReplyAllPreservesToCcSplitAndDropsSelf() {
        // Latest message: from p, to me + q, cc r. Reply-all should drop me,
        // keep p and q on To, keep r on Cc.
        let m = message(id: "<a@x>", from: "p@x.com", to: ["me@x.com", "q@x.com"], cc: ["r@x.com"], minutes: 0)
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread([m]), as: account())
        XCTAssertEqual(to.map(\.address), ["p@x.com", "q@x.com"])
        XCTAssertEqual(cc.map(\.address), ["r@x.com"])
    }

    func testReplyAllDedupesAcrossToAndCcWithToWinning() {
        // q is on both To and Cc; it should appear once, on To.
        let m = message(id: "<a@x>", from: "p@x.com", to: ["q@x.com"], cc: ["q@x.com", "r@x.com"], minutes: 0)
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread([m]), as: account())
        XCTAssertEqual(to.map(\.address), ["p@x.com", "q@x.com"])
        XCTAssertEqual(cc.map(\.address), ["r@x.com"])
    }

    func testReplyAllToNoteToSelfAddressesTheAccount() {
        // A message from the account to only itself: dropping self would leave no
        // one, so reply-all falls back to addressing the account, the way email
        // lets you reply to a note to self.
        let m = message(id: "<a@x>", from: "me@x.com", to: ["me@x.com"], minutes: 0)
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread([m]), as: account())
        XCTAssertEqual(to.map(\.address), ["me@x.com"])
        XCTAssertTrue(cc.isEmpty)
    }

    func testReplyAllDerivesFromMostRecentMessage() {
        // An earlier message had three recipients; the latest dropped one. The
        // reply should follow the latest, not re-add the dropped person.
        let first = message(id: "<a@x>", from: "p@x.com", to: ["me@x.com", "q@x.com"], cc: ["r@x.com"], minutes: 0)
        let latest = message(id: "<b@x>", from: "p@x.com", to: ["me@x.com"], references: ["<a@x>"], minutes: 1)
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread([first, latest]), as: account())
        XCTAssertEqual(to.map(\.address), ["p@x.com"])
        XCTAssertTrue(cc.isEmpty)
    }

    // MARK: - Threading headers, id, subject

    func testThreadingHeadersExtendChain() {
        let latest = message(id: "<b@x>", from: "p@x.com", references: ["<a@x>"], minutes: 1)
        let (inReplyTo, references) = ReplyBuilder.threadingHeaders(replyingTo: thread([latest]))
        XCTAssertEqual(inReplyTo, "<b@x>")
        XCTAssertEqual(references, ["<a@x>", "<b@x>"])
    }

    func testGeneratedMessageIDIsWellFormed() {
        let id = ReplyBuilder.generateMessageID(for: account())
        XCTAssertTrue(id.hasPrefix("<"))
        XCTAssertTrue(id.hasSuffix("@x.com>"))
        XCTAssertNotEqual(id, ReplyBuilder.generateMessageID(for: account())) // unique
    }

    func testReplySubjectAddsSingleRePrefix() {
        XCTAssertEqual(ReplyBuilder.replySubject(for: thread([message(id: "<a@x>", from: "p@x.com", minutes: 0)])), "Re: Plan")
    }

    // MARK: - Participant changes

    func testParticipantChangeReportsAddAndRemove() {
        // m1: p -> q, r.  m2: p -> q (r removed).  m3: p -> q, s (s added).
        let m1 = message(id: "<a@x>", from: "p@x.com", to: ["q@x.com", "r@x.com"], minutes: 0)
        let m2 = message(id: "<b@x>", from: "p@x.com", to: ["q@x.com"], references: ["<a@x>"], minutes: 1)
        let m3 = message(id: "<c@x>", from: "p@x.com", to: ["q@x.com", "s@x.com"], references: ["<a@x>", "<b@x>"], minutes: 2)

        let deltas = ParticipantChange.deltas(across: [m1, m2, m3], excluding: "me@x.com")
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(deltas[0].messageID, "mid:<b@x>")
        XCTAssertEqual(deltas[0].removed.map(\.address), ["r@x.com"])
        XCTAssertTrue(deltas[0].added.isEmpty)
        XCTAssertEqual(deltas[1].messageID, "mid:<c@x>")
        XCTAssertEqual(deltas[1].added.map(\.address), ["s@x.com"])
        XCTAssertTrue(deltas[1].removed.isEmpty)
    }

    func testParticipantChangeNeverReportsSelf() {
        // me drops off the second message; that must not surface as a change.
        let m1 = message(id: "<a@x>", from: "p@x.com", to: ["me@x.com", "q@x.com"], minutes: 0)
        let m2 = message(id: "<b@x>", from: "p@x.com", to: ["q@x.com"], references: ["<a@x>"], minutes: 1)
        let deltas = ParticipantChange.deltas(across: [m1, m2], excluding: "me@x.com")
        XCTAssertTrue(deltas.isEmpty)
    }

    func testParticipantChangeIgnoresStableMembership() {
        // Same people, addressing rearranged (q moves from To to Cc): no change.
        let m1 = message(id: "<a@x>", from: "p@x.com", to: ["q@x.com"], minutes: 0)
        let m2 = message(id: "<b@x>", from: "p@x.com", to: [], cc: ["q@x.com"], references: ["<a@x>"], minutes: 1)
        let deltas = ParticipantChange.deltas(across: [m1, m2], excluding: "me@x.com")
        XCTAssertTrue(deltas.isEmpty)
    }
}
