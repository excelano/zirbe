// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A single email, the domain layer's parsed view of one message. Carries the
// RFC 5322 threading headers the JWZ pass needs, plus the fields the UI shows.

import Foundation

/// One message in a conversation. Built from a `MailEnvelope` (see the
/// `MailEnvelope` initializer in MessageMapping); the threading headers decide
/// which `Thread` it lands in, the rest is for display.
public struct Message: Sendable, Hashable, Identifiable {
    /// The message's own `Message-ID`. Absent on messages that arrived without
    /// one (rare, but it happens); identity then falls back to the UID.
    public var messageID: String?
    /// The server UID within its mailbox, when known.
    public var uid: UInt32?
    /// `In-Reply-To`: the single message this one answers.
    public var inReplyTo: String?
    /// `References`: the thread's ancestry chain, oldest first.
    public var references: [String]
    public var subject: String?
    public var from: Participant?
    public var to: [Participant]
    public var cc: [Participant]
    public var date: Date?
    public var flags: Set<Flag>
    /// The message's readable text body, when it has been fetched. Nil until the
    /// conversation is opened; bodies load lazily and are then cached in the
    /// store, so this is populated for messages in a conversation the user has
    /// viewed and nil for inbox rows that have only been synced as headers.
    public var bodyText: String?
    /// Whether the message carries an HTML alternative, so the UI can offer the
    /// Web View. Set when the body is fetched; false for header-only rows and for
    /// plain-text-only mail.
    public var hasHTML: Bool

    public init(
        messageID: String? = nil,
        uid: UInt32? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String? = nil,
        from: Participant? = nil,
        to: [Participant] = [],
        cc: [Participant] = [],
        date: Date? = nil,
        flags: Set<Flag> = [],
        bodyText: String? = nil,
        hasHTML: Bool = false
    ) {
        self.messageID = messageID
        self.uid = uid
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.flags = flags
        self.bodyText = bodyText
        self.hasHTML = hasHTML
    }

    /// Whether the message has been read.
    public var isSeen: Bool { flags.contains(.seen) }

    /// Stable identity for lists and storage: the Message-ID when present, then
    /// the UID, then a content-derived fallback for the rare header-less case.
    public var id: String {
        if let messageID, !messageID.isEmpty { return "mid:\(messageID)" }
        if let uid { return "uid:\(uid)" }
        return "anon:\(subject ?? "")|\(date?.timeIntervalSince1970 ?? 0)|\(from?.address ?? "")"
    }
}

extension Sequence where Element == Message {
    /// Messages oldest first. Messages without a date sort to the end, with a
    /// stable id tiebreak so ordering is deterministic.
    func chronological() -> [Message] {
        sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }
}
