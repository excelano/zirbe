// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The handles the composer carries while a draft is in play: a `DraftContext`
// that survives a save so a later edit, send, or discard acts on the same draft,
// and a `DraftEdit` that hands a saved draft's contents back to the composer when
// the user reopens it. Reply-drafts are out of scope for v1, so a draft is always
// a new conversation: there is no quote trailer to strip and no threading to
// restore.

import Foundation

/// Identifies a saved draft across the composer's lifetime. Held by the composer
/// from the first save onward (nil before then, for a brand-new compose), passed
/// back on each re-save so the edit replaces rather than stacks, and to the
/// delete on send or discard.
///
/// One Message-ID is the whole identity: it is shared by every save of the draft,
/// so the thread id and the server reconciliation key both follow from it.
public struct DraftContext: Sendable, Hashable {
    /// The Message-ID shared by every save of this draft.
    public let messageID: String

    public init(messageID: String) {
        self.messageID = messageID
    }

    /// The draft's thread and message id in the store (`mid:<messageID>`), used to
    /// route a Drafts-thread tap back to the composer and to resolve the server
    /// copy to replace or expunge.
    public var threadID: String { "mid:\(messageID)" }
}

/// A saved draft loaded back for editing: the composer-ready fields plus the
/// context to re-save or delete it. The attachments carry their bytes (refetched
/// from the server), so editing and re-saving preserves the files.
public struct DraftEdit: Sendable, Hashable {
    public let context: DraftContext
    public let to: [Participant]
    public let cc: [Participant]
    public let subject: String
    public let body: String
    public let attachments: [DraftAttachment]

    public init(
        context: DraftContext,
        to: [Participant],
        cc: [Participant],
        subject: String,
        body: String,
        attachments: [DraftAttachment]
    ) {
        self.context = context
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }
}
