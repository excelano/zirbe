// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A person on a message's From/To/Cc. The domain layer's parsed view of the
// raw address strings the mail engine surfaces.

import Foundation

/// One participant in a conversation: an email address and an optional display
/// name. Identity is the lowercased address, so the same person is one member
/// no matter how their name is capitalized or formatted across messages.
public struct Participant: Sendable, Hashable, Codable, Identifiable {
    /// The address, lowercased for stable identity. Email addresses are treated
    /// case-insensitively in practice, which is what users expect.
    public var address: String
    /// The human name, if the header carried one. Never lowercased.
    public var displayName: String?

    public init(address: String, displayName: String? = nil) {
        self.address = address.lowercased()
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public var id: String { address }

    /// What to show in the UI: the display name when we have one, else the
    /// bare address.
    public var label: String { displayName ?? address }
}
