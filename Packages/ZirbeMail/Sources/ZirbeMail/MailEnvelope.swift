// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Zirbe-owned value types for the mail layer. These deliberately do not expose
// any SwiftMail type, so the engine behind ZirbeMail can be replaced without
// touching the rest of the app.

import Foundation

/// Where and how to reach a mail server.
public struct MailServerConfig: Sendable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 993) {
        self.host = host
        self.port = port
    }
}

/// A snapshot of a mailbox used to reconcile the local cache against the server:
/// its UID-validity (a generation marker the server bumps when it renumbers) and
/// the full set of UIDs it currently holds. A cached message whose UID is absent
/// here was deleted on the server and should be pruned locally.
public struct MailboxState: Sendable, Hashable {
    /// The server's UIDVALIDITY for the mailbox. When this changes, every UID the
    /// server ever issued is invalidated and the whole cache must be rebuilt.
    public var uidValidity: UInt32
    /// Every UID the mailbox holds right now.
    public var uids: Set<UInt32>

    public init(uidValidity: UInt32, uids: Set<UInt32>) {
        self.uidValidity = uidValidity
        self.uids = uids
    }
}

/// One user-facing attachment, resolved for display and on-demand opening: the
/// name to show, the MIME type the UI picks an icon from, and the MIME part
/// identifier the bytes are fetched by. The bytes themselves are not carried
/// here; this is the metadata extracted from the message's MIME structure during
/// the body fetch, and the `partID` lets the byte fetch target the right part
/// when the chip is tapped. "User-facing" means the cid join already dropped the
/// inline parts the body references (signature logos, embedded images), so only
/// real attachments remain.
public struct AttachmentInfo: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    /// The IMAP body section of this part (e.g. "2" or "3.1"), so its bytes can
    /// be fetched on demand. Stable for the message's lifetime on the server.
    public var partID: String

    public init(filename: String, mimeType: String, partID: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.partID = partID
    }
}

/// A fetched message body: the readable text the bubble shows, whether the
/// message also carries an HTML alternative, and its user-facing attachments.
/// `hasHTML` is what gates the Web View control, so it is recorded even when the
/// plain text won as the display body, because the richer HTML is still there to
/// open on demand. The attachments come free with the same fetch (read off the
/// MIME structure, no extra round trip).
public struct MessageBody: Sendable, Hashable {
    public var text: String
    public var hasHTML: Bool
    public var attachments: [AttachmentInfo]

    public init(text: String, hasHTML: Bool, attachments: [AttachmentInfo] = []) {
        self.text = text
        self.hasHTML = hasHTML
        self.attachments = attachments
    }
}

/// A message's envelope, including the RFC 5322 threading headers that decide
/// which conversation a message belongs to. `from`/`to` are raw header strings
/// for now; parsing into participants belongs to the domain layer.
public struct MailEnvelope: Sendable, Hashable, Identifiable {
    public var sequenceNumber: UInt32?
    public var uid: UInt32?
    public var subject: String?
    public var from: String?
    public var to: [String]
    public var cc: [String]
    public var date: Date?
    /// The message's own `Message-ID`.
    public var messageID: String?
    /// `In-Reply-To`: the single message this one answers.
    public var inReplyTo: String?
    /// `References`: the full ancestry chain of the thread.
    public var references: [String]
    public var flags: [String]
    /// The `X-Zirbe-Reaction` header value when present: this message reacts to
    /// the one named by `inReplyTo`, with this emoji. Nil for ordinary mail
    /// (including reactions from clients that don't set the header). Read off the
    /// full header block the fetch already pulls, so it needs no extra round trip.
    public var reaction: String?

    /// Stable identity for SwiftUI lists: the UID when present, else the
    /// Message-ID, else the sequence number.
    public var id: String {
        if let uid { return "uid:\(uid)" }
        if let messageID { return "mid:\(messageID)" }
        return "seq:\(sequenceNumber.map(String.init) ?? "?")"
    }

    public init(
        sequenceNumber: UInt32? = nil,
        uid: UInt32? = nil,
        subject: String? = nil,
        from: String? = nil,
        to: [String] = [],
        cc: [String] = [],
        date: Date? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        flags: [String] = [],
        reaction: String? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.flags = flags
        self.reaction = reaction
    }
}
