// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The send-side mapping from Zirbe's OutgoingMessage into SwiftMail's Email. The
// load-bearing case is Bcc: the blind recipients must reach the SMTP envelope so
// they receive the mail, yet never appear in the serialized headers, or the
// blind copy stops being blind.

import XCTest
import SwiftMail
@testable import ZirbeMail

final class OutgoingMappingTests: XCTestCase {
    private func message(
        to: [OutgoingAddress] = [OutgoingAddress(address: "a@x.com", name: "A")],
        cc: [OutgoingAddress] = [OutgoingAddress(address: "b@x.com")],
        bcc: [OutgoingAddress] = [OutgoingAddress(address: "secret@x.com", name: "Secret")],
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [OutgoingAttachment] = [],
        headers: [String: String] = [:]
    ) -> OutgoingMessage {
        OutgoingMessage(
            from: OutgoingAddress(address: "me@x.com", name: "Me"),
            to: to, cc: cc, bcc: bcc,
            subject: "Hello",
            textBody: "hi",
            inReplyTo: inReplyTo,
            references: references,
            messageID: "<id@x.com>",
            attachments: attachments,
            headers: headers
        )
    }

    /// The serialized header block, the part a recipient's client reads.
    private func headerBlock(of email: Email) -> String {
        let content = email.constructContent()
        return content.components(separatedBy: "\r\n\r\n").first ?? content
    }

    func testBccMapsToEnvelopeRecipientsButNotHeaders() {
        let email = Email(message())

        // The blind recipients reach the RCPT TO envelope...
        XCTAssertEqual(email.bccRecipients.map(\.address), ["secret@x.com"])
        XCTAssertFalse(email.recipients.map(\.address).contains("secret@x.com"))
        XCTAssertFalse(email.ccRecipients.map(\.address).contains("secret@x.com"))

        // ...but are absent from the serialized message: no Bcc header, and the
        // blind address appears nowhere in the headers a recipient would read.
        let content = email.constructContent()
        let headerBlock = content.components(separatedBy: "\r\n\r\n").first ?? content
        XCTAssertFalse(headerBlock.lowercased().contains("bcc:"))
        XCTAssertFalse(headerBlock.contains("secret@x.com"))
        // The visible recipients still serialize as To and Cc.
        XCTAssertTrue(headerBlock.contains("a@x.com"))
        XCTAssertTrue(headerBlock.contains("b@x.com"))
    }

    func testNoBccLeavesEnvelopeWithJustToAndCc() {
        let email = Email(message(bcc: []))
        XCTAssertTrue(email.bccRecipients.isEmpty)
        XCTAssertEqual(email.allRecipients.map(\.address), ["a@x.com", "b@x.com"])
    }

    func testThePregeneratedMessageIDIsTheOneOnTheWire() {
        let email = Email(message())
        XCTAssertEqual(email.messageID?.description, "<id@x.com>")
        XCTAssertTrue(headerBlock(of: email).contains("<id@x.com>"), "the SMTP send and the Sent copy must agree")
    }

    func testThreadingHeadersRideAsAdditionalHeaders() {
        let email = Email(message(inReplyTo: "<a@x>", references: ["<root@x>", "<a@x>"]))

        XCTAssertEqual(email.additionalHeaders?["In-Reply-To"], "<a@x>")
        XCTAssertEqual(email.additionalHeaders?["References"], "<root@x> <a@x>")
    }

    func testAMessageWithNoThreadingOrCustomHeadersAddsNone() {
        let email = Email(message())
        XCTAssertNil(email.additionalHeaders)
        XCTAssertNil(email.attachments)
    }

    func testControlCharactersInReceivedMessageIDsCannotInjectHeaders() {
        // A crafted In-Reply-To carrying CR/LF would otherwise start a new header
        // line in this outgoing reply, since additional headers are written verbatim.
        let email = Email(message(
            inReplyTo: "<a@x>\r\nBcc: victim@x.com",
            references: ["<r@x>\n", "\t<s@x>"]
        ))

        XCTAssertEqual(email.additionalHeaders?["In-Reply-To"], "<a@x> Bcc: victim@x.com")
        XCTAssertEqual(email.additionalHeaders?["References"], "<r@x> <s@x>")
        let headers = headerBlock(of: email)
        XCTAssertFalse(headers.contains("\r\nBcc:"), "the injected line never becomes a header of its own")
    }

    func testEmptyThreadingValuesAreOmitted() {
        let email = Email(message(inReplyTo: "", references: []))
        XCTAssertNil(email.additionalHeaders?["In-Reply-To"])
        XCTAssertNil(email.additionalHeaders?["References"])
    }

    func testCustomHeadersRideAlongAndThreadingWinsACollision() {
        let email = Email(message(
            inReplyTo: "<a@x>",
            headers: [MailHeader.zirbeReaction: "👍", "In-Reply-To": "<forged@x>"]
        ))

        XCTAssertEqual(email.additionalHeaders?[MailHeader.zirbeReaction], "👍")
        XCTAssertEqual(email.additionalHeaders?["In-Reply-To"], "<a@x>")
    }

    func testAttachmentsKeepTheirNamesTypesAndBytes() {
        let bytes = Data([0x25, 0x50, 0x44, 0x46])
        let email = Email(message(attachments: [
            OutgoingAttachment(filename: "q.pdf", mimeType: "application/pdf", data: bytes),
            OutgoingAttachment(filename: "memo.m4a", mimeType: "audio/mp4", data: Data([1, 2])),
        ]))

        let attached = email.attachments ?? []
        XCTAssertEqual(attached.map(\.filename), ["q.pdf", "memo.m4a"])
        XCTAssertEqual(attached.map(\.mimeType), ["application/pdf", "audio/mp4"])
        XCTAssertEqual(attached.first?.data, bytes)
    }

    func testSenderAndRecipientNamesSurvive() {
        let email = Email(message())
        XCTAssertEqual(email.sender.name, "Me")
        XCTAssertEqual(email.sender.address, "me@x.com")
        XCTAssertEqual(email.recipients.first?.name, "A")
        XCTAssertNil(email.ccRecipients.first?.name)
    }
}
