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
        bcc: [OutgoingAddress] = [OutgoingAddress(address: "secret@x.com", name: "Secret")]
    ) -> OutgoingMessage {
        OutgoingMessage(
            from: OutgoingAddress(address: "me@x.com", name: "Me"),
            to: to, cc: cc, bcc: bcc,
            subject: "Hello",
            textBody: "hi",
            messageID: "<id@x.com>"
        )
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
}
