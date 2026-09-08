// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The reply bar's draft: the typed text, the staged attachments, and the
// earlier message a swipe-to-reply aimed it at. Sending takes the whole draft
// out of the bar in one step, the way Messages clears the field on Send rather
// than after the round trip, and hands the caller a copy to send. If the send
// is refused before anything goes out, the copy is put back, but only into a
// bar the user hasn't started typing into since; new words are never overwritten.
//
// Generic over the attachment type because the app stages attachments with
// their own view identity; the rule doesn't care what they are.

import Foundation

public struct ReplyComposer<Attachment> {
    public var text: String
    public var attachments: [Attachment]
    /// The message this reply answers, or nil to reply into the thread as a whole.
    public var target: Message?

    public init(text: String = "", attachments: [Attachment] = [], target: Message? = nil) {
        self.text = text
        self.attachments = attachments
        self.target = target
    }

    /// Nothing to send: no text beyond whitespace and no files.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// Whether the bar has been left untouched since it was cleared.
    private var isUntouched: Bool {
        text.isEmpty && attachments.isEmpty
    }

    /// Clear the bar and return what was in it, to send.
    public mutating func take() -> ReplyComposer {
        let taken = self
        self = ReplyComposer()
        return taken
    }

    /// Put a taken draft back after a refused send. Refused, returning false, if
    /// the user has typed or attached anything since, so their new draft stands.
    @discardableResult
    public mutating func restore(_ draft: ReplyComposer) -> Bool {
        guard isUntouched else { return false }
        self = draft
        return true
    }
}
