import XCTest
import ZirbeMail
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

    func testReplyCarriesAttachmentBytesToWire() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        let draft = OutgoingDraft.reply(
            to: thread(), as: account(),
            to: [participant("pat@x.com")], cc: [],
            body: "see attached",
            attachments: [OutgoingAttachment(filename: "shot.png", mimeType: "image/png", data: bytes)],
            sentAt: sentAt
        )
        XCTAssertEqual(draft.outgoingMessage.attachments.map(\.filename), ["shot.png"])
        XCTAssertEqual(draft.outgoingMessage.attachments.first?.data, bytes)
        XCTAssertEqual(draft.localMessage.attachments.first?.partID, "")
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

    func testNewCarriesAttachmentBytesToWire() {
        let bytes = Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"
        let draft = OutgoingDraft.new(
            from: account(), to: [participant("pat@x.com")], subject: "Hello", body: "hi",
            attachments: [OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: bytes)],
            sentAt: sentAt
        )
        XCTAssertEqual(draft.outgoingMessage.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(draft.outgoingMessage.attachments.first?.data, bytes)
        // The optimistic bubble names the file but can't re-open it yet (empty partID).
        XCTAssertEqual(draft.localMessage.attachments.first?.partID, "")
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

    // MARK: - Forward

    private func forwardDraft(
        note: String = "FYI",
        attachments: [OutgoingAttachment] = []
    ) -> OutgoingDraft {
        let t = thread()
        return OutgoingDraft.forward(
            message: t.messages[0],
            subject: ReplyBuilder.forwardSubject(for: t),
            as: account(),
            to: [participant("new@x.com", "New")], cc: [],
            note: note,
            attachments: attachments,
            sentAt: sentAt, locale: posix, timeZone: gmt
        )
    }

    func testForwardStartsANewConversationUnderFwdSubject() {
        let draft = forwardDraft()
        // A forward goes to fresh recipients, so it carries no threading headers
        // and won't slot back into the source thread.
        XCTAssertNil(draft.inReplyTo)
        XCTAssertTrue(draft.references.isEmpty)
        XCTAssertEqual(draft.subject, "Fwd: Plan")
        XCTAssertEqual(draft.to.map(\.address), ["new@x.com"])
        XCTAssertEqual(draft.from.address, "me@x.com")
    }

    func testForwardBodyCarriesNoteThenForwardedBlock() {
        let draft = forwardDraft(note: "Take a look")
        XCTAssertTrue(draft.body.hasPrefix("Take a look"))
        XCTAssertTrue(draft.body.contains("Begin forwarded message:"))
        XCTAssertTrue(draft.body.contains("From: Pat <pat@x.com>"))
        XCTAssertTrue(draft.body.contains("Subject: Plan"))
        // The original body rides whole, not `> `-quoted the way a reply does.
        XCTAssertTrue(draft.body.contains("the question"))
        XCTAssertFalse(draft.body.contains("> the question"))
    }

    func testForwardWithEmptyNoteOmitsTheNote() {
        let draft = forwardDraft(note: "   ")
        XCTAssertTrue(draft.body.hasPrefix("Begin forwarded message:"))
    }

    func testForwardCarriesAttachmentBytesToWire() {
        let bytes = Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"
        let draft = forwardDraft(attachments: [
            OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: bytes)
        ])
        XCTAssertEqual(draft.outgoingMessage.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(draft.outgoingMessage.attachments.first?.data, bytes)
    }

    func testForwardLocalCopyShowsUnopenableChips() {
        let draft = forwardDraft(attachments: [
            OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data())
        ])
        // The optimistic bubble names the file but can't re-open it until the Sent
        // re-sync stamps a real part section, signaled by an empty partID.
        XCTAssertEqual(draft.localMessage.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(draft.localMessage.attachments.first?.partID, "")
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
