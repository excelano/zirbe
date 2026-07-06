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

    /// A thread is unread if any of its chat messages is unread. Reactions are
    /// excluded: a tapback landing on your message shouldn't bold the thread, the
    /// way a reaction is a lightweight acknowledgement rather than new mail.
    public var isUnread: Bool { messages.contains { !$0.isSeen && !$0.isReaction } }

    /// A thread is flagged if any of its messages is flagged, mirroring how
    /// unread reads across the thread.
    public var isFlagged: Bool { messages.contains(where: \.isFlagged) }

    /// The count of chat messages, excluding reactions, since a reaction is a
    /// badge on a message rather than a message in its own right.
    public var messageCount: Int { conversationMessages.count }

    /// The messages shown as chat bubbles: every message that isn't a reaction,
    /// in the thread's existing oldest-first order.
    public var conversationMessages: [Message] {
        messages.filter { !$0.isReaction }
    }

    /// The reactions on each message, keyed by the target message's `Message-ID`
    /// (the id a reaction names in its `In-Reply-To`). At most one reaction per
    /// reactor per message: when a reactor's reaction appears more than once, the
    /// latest by date wins, so a change replaces rather than stacks.
    public var reactionsByTarget: [String: [Reaction]] {
        var byReactor: [String: [String: Reaction]] = [:]
        for message in messages {
            guard let emoji = message.reaction,
                  let target = message.inReplyTo, !target.isEmpty,
                  let from = message.from
            else { continue }
            let candidate = Reaction(reactor: from, emoji: emoji, date: message.date)
            if let existing = byReactor[target]?[from.address],
               (existing.date ?? .distantPast) >= (message.date ?? .distantPast) {
                continue
            }
            byReactor[target, default: [:]][from.address] = candidate
        }
        return byReactor.mapValues { Array($0.values) }
    }

    /// The reactions on one message, by its `Message-ID`, or an empty list when it
    /// has none.
    public func reactions(forMessageID messageID: String?) -> [Reaction] {
        guard let messageID, !messageID.isEmpty else { return [] }
        return reactionsByTarget[messageID] ?? []
    }
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
    /// Whether the thread is flagged, for the triage marker on the inbox row.
    public var isFlagged: Bool
    public var messageCount: Int
    /// A one-line preview of the thread's most recent message, shown under the
    /// participants in the inbox row. Nil until the latest message's body has
    /// been fetched (the sync backfills it), or when that body reduces to nothing
    /// worth showing.
    public var preview: String?

    public init(
        id: String,
        subject: String,
        participants: [Participant],
        lastActivity: Date?,
        isUnread: Bool,
        isFlagged: Bool = false,
        messageCount: Int,
        preview: String? = nil
    ) {
        self.id = id
        self.subject = subject
        self.participants = participants
        self.lastActivity = lastActivity
        self.isUnread = isUnread
        self.isFlagged = isFlagged
        self.messageCount = messageCount
        self.preview = preview
    }
}
