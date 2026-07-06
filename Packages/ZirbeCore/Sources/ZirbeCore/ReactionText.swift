// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The readable body of a reaction message. A reaction rides as a real reply
// carrying an X-Zirbe-Reaction header, so a receiving Zirbe shows a badge and
// hides the bubble. Every other client has no idea about the header and shows
// the body instead, so the body is written to read as a short, sensible line
// ("Reacted 👍 to '…'") rather than an empty message, the way an iMessage
// tapback degrades to a readable line over SMS.

import Foundation

public enum ReactionText {
    /// The body to send with a reaction to `target`, carrying `emoji`. Names a
    /// short excerpt of what was reacted to so the line stands on its own for a
    /// reader whose client doesn't render the reaction as a badge.
    public static func body(emoji: String, target: Message) -> String {
        let excerpt = excerpt(of: target)
        return excerpt.isEmpty ? "Reacted \(emoji)" : "Reacted \(emoji) to \u{201C}\(excerpt)\u{201D}"
    }

    /// A short, single-line excerpt of the reacted-to message: its body glance
    /// when one is cached, else its subject, capped so the line stays brief.
    private static func excerpt(of message: Message, limit: Int = 40) -> String {
        let body = message.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let body, !body.isEmpty {
            base = QuotedText.snippet(body)
        } else {
            base = message.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard base.count > limit else { return base }
        return base.prefix(limit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
