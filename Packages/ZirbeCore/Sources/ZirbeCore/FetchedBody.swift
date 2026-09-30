// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// What a body fetch yields for one message, on its way into the store: the
// display text, whether an HTML alternative exists, the user-facing
// attachments, and the calendar invitation when the message carries one.

import Foundation

public struct FetchedBody: Sendable, Hashable {
    public var text: String
    public var hasHTML: Bool
    public var attachments: [MessageAttachment]
    public var invite: Invite?

    public init(text: String, hasHTML: Bool, attachments: [MessageAttachment] = [], invite: Invite? = nil) {
        self.text = text
        self.hasHTML = hasHTML
        self.attachments = attachments
        self.invite = invite
    }
}
