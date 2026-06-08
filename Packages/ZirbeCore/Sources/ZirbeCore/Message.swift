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
    public var date: Date?
    public var flags: Set<Flag>

    public init(
        messageID: String? = nil,
        uid: UInt32? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String? = nil,
        from: Participant? = nil,
        to: [Participant] = [],
        date: Date? = nil,
        flags: Set<Flag> = []
    ) {
        self.messageID = messageID
        self.uid = uid
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.flags = flags
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
