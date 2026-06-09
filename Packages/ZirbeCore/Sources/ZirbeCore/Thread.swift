// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A conversation: an email thread shown like a named group chat. This is the
// product's core abstraction, the thing Spike got wrong by keying on person.

import Foundation

/// A conversation. Its identity is the thread root, its title is the subject,
/// its members are everyone on From/To/Cc across the messages, and its body is
/// the messages in time order, one bubble each.
public struct Thread: Sendable, Hashable, Identifiable {
    /// Stable thread identity, derived from the root message's `Message-ID`
    /// (even when that root message itself was never received).
    public var id: String
    /// The conversation title: the root subject with any `Re:`/`Fwd:` prefixes
    /// stripped, shown like the name of a group chat.
    public var subject: String
    /// Every message in the thread, oldest first.
    public var messages: [Message]
    /// Everyone who appears on From, To, or Cc across the thread, deduplicated.
    public var participants: [Participant]
    /// The most recent message date in the thread, for inbox sorting.
    public var lastActivity: Date?

    public init(
        id: String,
        subject: String,
        messages: [Message],
        participants: [Participant],
        lastActivity: Date?
    ) {
        self.id = id
        self.subject = subject
        self.messages = messages
        self.participants = participants
        self.lastActivity = lastActivity
    }

    /// A thread is unread if any of its messages is unread.
    public var isUnread: Bool { messages.contains { !$0.isSeen } }

    public var messageCount: Int { messages.count }
}

/// The inbox-row view of a thread: everything the conversation list shows,
/// without loading the messages. The store persists these fields directly so
/// the inbox is a cheap query; the full `Thread` (with messages) is loaded only
/// when a conversation is opened.
public struct ThreadSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var subject: String
    public var participants: [Participant]
    public var lastActivity: Date?
    public var isUnread: Bool
    public var messageCount: Int

    public init(
        id: String,
        subject: String,
        participants: [Participant],
        lastActivity: Date?,
        isUnread: Bool,
        messageCount: Int
    ) {
        self.id = id
        self.subject = subject
        self.participants = participants
        self.lastActivity = lastActivity
        self.isUnread = isUnread
        self.messageCount = messageCount
    }
}
