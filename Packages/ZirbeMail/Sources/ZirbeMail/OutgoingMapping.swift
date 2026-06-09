// Maps Zirbe's OutgoingMessage into SwiftMail's Email. The send-side counterpart
// to Mapping.swift; keeping the SwiftMail Email type behind this boundary is
// what lets the engine be replaced without touching the rest of the app.

import SwiftMail

extension Email {
    /// Build a SwiftMail email from an outgoing message, preserving the To/Cc
    /// split and the threading headers. The pre-generated Message-ID is set
    /// explicitly so the SMTP send and the Sent-folder copy agree; In-Reply-To
    /// and References go through as additional headers.
    init(_ outgoing: OutgoingMessage) {
        self.init(
            sender: EmailAddress(name: outgoing.from.name, address: outgoing.from.address),
            recipients: outgoing.to.map { EmailAddress(name: $0.name, address: $0.address) },
            ccRecipients: outgoing.cc.map { EmailAddress(name: $0.name, address: $0.address) },
            subject: outgoing.subject,
            textBody: outgoing.textBody
        )

        if let id = MessageID(outgoing.messageID) {
            self.messageID = id
        }

        var headers: [String: String] = [:]
        if let inReplyTo = outgoing.inReplyTo, !inReplyTo.isEmpty {
            headers["In-Reply-To"] = inReplyTo
        }
        if !outgoing.references.isEmpty {
            headers["References"] = outgoing.references.joined(separator: " ")
        }
        if !headers.isEmpty {
            self.additionalHeaders = headers
        }
    }
}
