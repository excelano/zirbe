import XCTest
import ZirbeMail
@testable import ZirbeCore

/// The unit-testable core of the Drafts feature: the `OutgoingDraft.draft`
/// builder, the optimistic local copy it produces, and the `DraftContext` handle.
/// The save/delete/load round trip in `InboxModel` and `SyncService` talks to a
/// live IMAP server, so it is verified on device, matching the Keychain/session
/// pattern.
final class DraftTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 0)

    private func account() -> Account {
        Account(emailAddress: "me@x.com", displayName: "Me", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func participant(_ address: String, _ name: String? = nil) -> Participant {
        Participant(address: address, displayName: name)
    }

    // MARK: - The draft builder

    func testDraftCarriesSuppliedMessageIDAndNoThreadingHeaders() {
        let draft = OutgoingDraft.draft(
            from: account(),
            to: [participant("pat@x.com")],
            subject: "Half a thought",
            body: "to be continued",
            messageID: "<keep-me@x.com>",
            savedAt: savedAt
        )
        // The id is the one we passed, not a freshly generated one, so editing the
        // draft later updates one row rather than spawning a new thread.
        XCTAssertEqual(draft.messageID, "<keep-me@x.com>")
        XCTAssertNil(draft.inReplyTo)
        XCTAssertTrue(draft.references.isEmpty)
        XCTAssertEqual(draft.from.address, "me@x.com")
    }

    func testDraftKeepsBodyVerbatim() {
        // A draft is mid-composition: its leading/trailing whitespace is the
        // user's and must survive, unlike `new`, which trims for a send.
        let body = "\n\n  still typing  \n"
        let draft = OutgoingDraft.draft(
            from: account(),
            to: [],
            subject: "",
            body: body,
            messageID: "<m@x.com>",
            savedAt: savedAt
        )
        XCTAssertEqual(draft.body, body)
    }

    func testDraftAllowsEmptyEverything() {
        // No content guardrails: a blank draft is a valid thing to save.
        let draft = OutgoingDraft.draft(
            from: account(), to: [], subject: "", body: "",
            messageID: "<blank@x.com>", savedAt: savedAt
        )
        XCTAssertTrue(draft.to.isEmpty)
        XCTAssertEqual(draft.subject, "")
        XCTAssertEqual(draft.body, "")
    }

    func testDraftCarriesAttachmentBytesToWire() {
        let bytes = Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"
        let draft = OutgoingDraft.draft(
            from: account(),
            to: [participant("pat@x.com")],
            subject: "With a file",
            body: "see attached",
            attachments: [OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: bytes)],
            messageID: "<f@x.com>",
            savedAt: savedAt
        )
        XCTAssertEqual(draft.outgoingMessage.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(draft.outgoingMessage.attachments.first?.data, bytes)
    }

    // MARK: - The optimistic local copy

    func testDraftLocalMessageIsFlaggedDraftAndSeen() {
        let draft = OutgoingDraft.draft(
            from: account(), to: [participant("pat@x.com")],
            subject: "Hi", body: "yo", messageID: "<m@x.com>", savedAt: savedAt
        )
        let local = draft.draftLocalMessage(uid: 42)
        XCTAssertTrue(local.flags.contains(.draft))
        XCTAssertTrue(local.flags.contains(.seen))
        XCTAssertEqual(local.uid, 42)
        XCTAssertEqual(local.bodyText, "yo")
        XCTAssertEqual(local.messageID, "<m@x.com>")
    }

    func testDraftLocalMessageWithoutUIDHasNone() {
        // The server reported no UID (no UIDPLUS); the copy still files, and the
        // UID is learned on the next Drafts sync.
        let draft = OutgoingDraft.draft(
            from: account(), to: [], subject: "", body: "x",
            messageID: "<m@x.com>", savedAt: savedAt
        )
        XCTAssertNil(draft.draftLocalMessage(uid: nil).uid)
    }

    func testDraftLocalMessageAttachmentsAreUnopenableChips() {
        let draft = OutgoingDraft.draft(
            from: account(), to: [participant("pat@x.com")],
            subject: "Hi", body: "yo",
            attachments: [OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data())],
            messageID: "<m@x.com>", savedAt: savedAt
        )
        let local = draft.draftLocalMessage(uid: nil)
        // The chip names the file but stays un-openable (empty partID) until a
        // Drafts sync stamps a real part section.
        XCTAssertEqual(local.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(local.attachments.first?.partID, "")
    }

    // MARK: - The context handle

    func testDraftContextThreadIDIsDerivedFromMessageID() {
        let context = DraftContext(messageID: "<m@x.com>")
        // Must match Message.id and Threader's id for a standalone draft, so a
        // Drafts-thread tap and a re-save resolve to the same row.
        XCTAssertEqual(context.threadID, "mid:<m@x.com>")
    }

    func testDraftContextThreadIDMatchesItsLocalMessageID() {
        let draft = OutgoingDraft.draft(
            from: account(), to: [], subject: "", body: "x",
            messageID: "<m@x.com>", savedAt: savedAt
        )
        let context = DraftContext(messageID: draft.messageID)
        XCTAssertEqual(context.threadID, draft.draftLocalMessage(uid: nil).id)
    }
}
