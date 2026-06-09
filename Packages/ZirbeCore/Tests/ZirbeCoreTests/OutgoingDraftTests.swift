import XCTest
@testable import ZirbeCore

final class OutgoingDraftTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let gmt = TimeZone(identifier: "GMT")!
    private let sentAt = Date(timeIntervalSince1970: 0)

    private func account() -> Account {
        Account(emailAddress: "me@x.com", displayName: "Me", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func participant(_ address: String, _ name: String? = nil) -> Participant {
        Participant(address: address, displayName: name)
    }

    private func thread() -> ZirbeCore.Thread {
        let m = Message(
            messageID: "<a@x>",
            references: ["<root@x>"],
            subject: "Plan",
            from: participant("pat@x.com", "Pat"),
            to: [participant("me@x.com")],
            cc: [participant("cc@x.com")],
            date: Date(timeIntervalSince1970: 0),
            flags: [.seen],
            bodyText: "the question"
        )
        return ZirbeCore.Thread(id: "mid:<a@x>", subject: "Plan", messages: [m],
                                participants: [], lastActivity: m.date)
    }

    // MARK: - Reply

    func testReplyCarriesThreadingSubjectAndTrailer() {
        let draft = OutgoingDraft.reply(
            to: thread(), as: account(),
            to: [participant("pat@x.com", "Pat")], cc: [participant("cc@x.com")],
            body: "My answer.", sentAt: sentAt, locale: posix, timeZone: gmt
        )
        XCTAssertEqual(draft.subject, "Re: Plan")
        XCTAssertEqual(draft.inReplyTo, "<a@x>")
        XCTAssertEqual(draft.references, ["<root@x>", "<a@x>"])
        XCTAssertTrue(draft.body.hasPrefix("My answer."))
        XCTAssertTrue(draft.body.contains("On Jan 1, 1970, at 12:00 AM, Pat <pat@x.com> wrote:"))
        XCTAssertTrue(draft.body.contains("> the question"))
    }

    func testReplyFromIsTheAccount() {
        let draft = OutgoingDraft.reply(
            to: thread(), as: account(),
            to: [participant("pat@x.com")], cc: [],
            body: "ok", sentAt: sentAt
        )
        XCTAssertEqual(draft.from.address, "me@x.com")
        XCTAssertEqual(draft.from.displayName, "Me")
    }

    // MARK: - New

    func testNewHasNoThreadingHeaders() {
        let draft = OutgoingDraft.new(
            from: account(), to: [participant("pat@x.com")], subject: "Hello", body: "hi", sentAt: sentAt
        )
        XCTAssertNil(draft.inReplyTo)
        XCTAssertTrue(draft.references.isEmpty)
        XCTAssertEqual(draft.subject, "Hello")
    }

    func testGeneratedMessageIDIsWellFormedAndShared() {
        let draft = OutgoingDraft.new(
            from: account(), to: [participant("pat@x.com")], subject: "Hello", body: "hi", sentAt: sentAt
        )
        XCTAssertTrue(draft.messageID.hasPrefix("<"))
        XCTAssertTrue(draft.messageID.hasSuffix("@x.com>"))
        // The wire form, the local copy, and the draft all carry one id, so a
        // retry and the later Sent re-sync collapse to a single row.
        XCTAssertEqual(draft.outgoingMessage.messageID, draft.messageID)
        XCTAssertEqual(draft.localMessage.messageID, draft.messageID)
    }

    // MARK: - Mapping to the wire and the local copy

    func testOutgoingMessagePreservesToCcSplit() {
        let draft = OutgoingDraft.new(
            from: account(),
            to: [participant("a@x.com", "A")], cc: [participant("b@x.com")],
            subject: "Hi", body: "yo", sentAt: sentAt
        )
        let wire = draft.outgoingMessage
        XCTAssertEqual(wire.to.map(\.address), ["a@x.com"])
        XCTAssertEqual(wire.to.first?.name, "A")
        XCTAssertEqual(wire.cc.map(\.address), ["b@x.com"])
    }

    func testLocalMessageIsSeenAndCarriesBody() {
        let draft = OutgoingDraft.new(
            from: account(), to: [participant("a@x.com")], subject: "Hi", body: "the body", sentAt: sentAt
        )
        let local = draft.localMessage
        XCTAssertTrue(local.isSeen)
        XCTAssertEqual(local.bodyText, "the body")
        XCTAssertEqual(local.date, sentAt)
        XCTAssertEqual(local.from?.address, "me@x.com")
    }
}
