// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A reaction (tapback) on a message, as shown to the reader: who reacted and
// with which emoji. Reactions are carried as real reply messages (see the
// `X-Zirbe-Reaction` header), threaded onto the message they answer; this is the
// aggregated, display-ready form the badge renders from.

import Foundation

/// One person's reaction to a message. Identity is the reactor plus the emoji,
/// so the same person switching emoji replaces their reaction rather than
/// stacking a second.
public struct Reaction: Sendable, Hashable, Identifiable {
    /// Who reacted.
    public var reactor: Participant
    /// The reaction emoji.
    public var emoji: String
    /// When the reaction was sent, for resolving the latest when a reactor's
    /// reaction appears more than once.
    public var date: Date?

    public init(reactor: Participant, emoji: String, date: Date? = nil) {
        self.reactor = reactor
        self.emoji = emoji
        self.date = date
    }

    public var id: String { "\(reactor.address)|\(emoji)" }
}
