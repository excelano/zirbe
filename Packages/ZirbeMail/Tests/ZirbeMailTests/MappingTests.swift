// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The read-side mapping from SwiftMail's models into Zirbe's envelope and
// mailbox values: the only code that sees SwiftMail's types. What matters is
// that every field the domain relies on survives the crossing, that the
// reaction header is read by its lowercased name (the parser lowercases custom
// header keys), and that a folder's role resolves from its special-use flags
// with INBOX recognized by name alone.

import XCTest
import SwiftMail
@testable import ZirbeMail

final class MappingTests: XCTestCase {
    // MARK: Envelopes

    func testEnvelopeCarriesEveryThreadingField() {
        let date = Date(timeIntervalSince1970: 1_000)
        let info = MessageInfo(
            sequenceNumber: SequenceNumber(3),
            uid: UID(42),
            subject: "Re: Plan",
            from: "Pat <pat@x.com>",
            to: ["me@x.com", "sam@x.com"],
            cc: ["cc@x.com"],
            date: date,
            messageId: MessageID("<b@x>"),
            inReplyTo: MessageID("<a@x>"),
            references: [MessageID("<root@x>")!, MessageID("<a@x>")!],
            flags: [.seen, .flagged, .custom("$Label1")]
        )

        let envelope = MailEnvelope(info)

        XCTAssertEqual(envelope.sequenceNumber, 3)
        XCTAssertEqual(envelope.uid, 42)
        XCTAssertEqual(envelope.subject, "Re: Plan")
        XCTAssertEqual(envelope.from, "Pat <pat@x.com>")
        XCTAssertEqual(envelope.to, ["me@x.com", "sam@x.com"])
        XCTAssertEqual(envelope.cc, ["cc@x.com"])
        XCTAssertEqual(envelope.date, date)
        XCTAssertEqual(envelope.messageID, "<b@x>")
        XCTAssertEqual(envelope.inReplyTo, "<a@x>")
        XCTAssertEqual(envelope.references, ["<root@x>", "<a@x>"])
        XCTAssertEqual(envelope.flags, ["seen", "flagged", "$Label1"])
        XCTAssertNil(envelope.reaction)
        XCTAssertEqual(envelope.id, "uid:42")
    }

    func testEnvelopeWithoutOptionalHeadersIsEmptyNotNil() {
        let envelope = MailEnvelope(MessageInfo(sequenceNumber: SequenceNumber(1)))

        XCTAssertNil(envelope.uid)
        XCTAssertNil(envelope.messageID)
        XCTAssertNil(envelope.inReplyTo)
        XCTAssertEqual(envelope.references, [])
        XCTAssertEqual(envelope.to, [])
        XCTAssertEqual(envelope.flags, [])
        XCTAssertEqual(envelope.id, "seq:1")
    }

    func testReactionHeaderIsReadByItsLowercasedName() {
        let reacting = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            additionalFields: [MailHeader.zirbeReaction.lowercased(): "👍"]
        )
        XCTAssertEqual(MailEnvelope(reacting).reaction, "👍")

        // The parser lowercases custom keys, so the canonical spelling never
        // arrives; a value under it would be a sign the assumption changed.
        let canonical = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            additionalFields: [MailHeader.zirbeReaction: "👍"]
        )
        XCTAssertNil(MailEnvelope(canonical).reaction)
    }

    // MARK: Mailboxes

    private func folder(_ name: String, _ attributes: Mailbox.Info.Attributes = [], delimiter: String? = "/") -> Mailbox.Info {
        Mailbox.Info(name: name, attributes: attributes, hierarchyDelimiter: delimiter)
    }

    func testRolesResolveFromSpecialUseAttributes() {
        XCTAssertEqual(MailboxSpecialUse(folder("Mail/Sent", .sent)), .sent)
        XCTAssertEqual(MailboxSpecialUse(folder("Entwürfe", .drafts)), .drafts)
        XCTAssertEqual(MailboxSpecialUse(folder("Deleted", .trash)), .trash)
        XCTAssertEqual(MailboxSpecialUse(folder("All Mail", .archive)), .archive)
        XCTAssertEqual(MailboxSpecialUse(folder("Spam", .junk)), .junk)
        XCTAssertEqual(MailboxSpecialUse(folder("Home", .inbox)), .inbox)
        XCTAssertNil(MailboxSpecialUse(folder("Projects")))
        XCTAssertNil(MailboxSpecialUse(folder("Projects", [.hasChildren, .marked])), "structural flags carry no role")
    }

    func testINBOXIsTheInboxByNameEvenWithoutTheAttribute() {
        XCTAssertEqual(MailboxSpecialUse(folder("INBOX")), .inbox)
        XCTAssertEqual(MailboxSpecialUse(folder("inbox")), .inbox)
        XCTAssertEqual(MailboxSpecialUse(folder("INBOX", .archive)), .inbox, "the name wins over a conflicting flag")
    }

    func testMailboxInfoCarriesSelectabilityAndDelimiter() {
        let container = MailboxInfo(folder("[Gmail]", .noSelect, delimiter: "/"))
        XCTAssertEqual(container.name, "[Gmail]")
        XCTAssertFalse(container.isSelectable)
        XCTAssertNil(container.specialUse)
        XCTAssertEqual(container.hierarchyDelimiter, "/")

        let dovecot = MailboxInfo(folder("INBOX.Sent", .sent, delimiter: "."))
        XCTAssertTrue(dovecot.isSelectable)
        XCTAssertEqual(dovecot.specialUse, .sent)
        XCTAssertEqual(dovecot.hierarchyDelimiter, ".")

        let flat = MailboxInfo(folder("Notes", delimiter: nil))
        XCTAssertNil(flat.hierarchyDelimiter)
    }
}
