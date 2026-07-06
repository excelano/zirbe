// Maps Zirbe's OutgoingMessage into SwiftMail's Email. The send-side counterpart
// to Mapping.swift; keeping the SwiftMail Email type behind this boundary is
// what lets the engine be replaced without touching the rest of the app.

import SwiftMail

extension Email {
    /// Build a SwiftMail email from an outgoing message, preserving the To/Cc/Bcc
    /// split and the threading headers. The pre-generated Message-ID is set
    /// explicitly so the SMTP send and the Sent-folder copy agree; In-Reply-To
    /// and References go through as additional headers. Bcc maps to SwiftMail's
    /// `bccRecipients`, which reaches the RCPT TO envelope but is left out of the
    /// serialized headers, so the blind copy stays blind.
    init(_ outgoing: OutgoingMessage) {
        self.init(
            sender: EmailAddress(name: outgoing.from.name, address: outgoing.from.address),
            recipients: outgoing.to.map { EmailAddress(name: $0.name, address: $0.address) },
            ccRecipients: outgoing.cc.map { EmailAddress(name: $0.name, address: $0.address) },
            bccRecipients: outgoing.bcc.map { EmailAddress(name: $0.name, address: $0.address) },
            subject: outgoing.subject,
            textBody: outgoing.textBody,
            attachments: outgoing.attachments.isEmpty ? nil : outgoing.attachments.map {
                Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
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
        // Any Zirbe-specific headers (a reaction marker) ride alongside the
        // threading ones. The threading fields win a key collision, but the two
        // sets don't overlap.
        headers.merge(outgoing.headers) { threading, _ in threading }
        if !headers.isEmpty {
            self.additionalHeaders = headers
        }
    }
}
