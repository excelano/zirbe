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
        flags: [String] = []
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
    }
}
