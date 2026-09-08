// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Small decisions the conversation screen makes about a thread, kept here as
// pure functions so they can be tested without a view: whether the thread is
// the user talking to themselves, who a Block Sender action would block, which
// reaction of the user's is already sent and so locked, and whether the newest
// message is one the Web View can open straight into.

import Foundation

extension Thread {
    /// Whether this conversation is just the user talking to themselves, so the
    /// header reads "Note to self" and isn't editable. True when reply-all lands
    /// on the account alone.
    public func isNoteToSelf(as account: Account) -> Bool {
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: self, as: account)
        return cc.isEmpty && to.count == 1 && to.first?.address == account.emailAddress.lowercased()
    }

    /// The sender a Block Sender action would block: the most recent message not
    /// from the account. Nil when every message is the user's own, so the menu
    /// hides the item; a summary-level fallback covers a thread not yet loaded.
    public func blockableSender(as account: Account) -> Participant? {
        let me = account.emailAddress.lowercased()
        return messages.last { ($0.from?.address.lowercased() ?? me) != me }?.from
    }

    /// The emoji the user has already sent as a reaction to a message, if any. A
    /// sent reaction is final, so this is what locks the picker for that message.
    public func myReaction(on messageID: String?, as account: Account) -> String? {
        let me = account.emailAddress.lowercased()
        return reactions(forMessageID: messageID).first { $0.reactor.address.lowercased() == me }?.emoji
    }

    /// The newest chat message when it carries HTML, for opening the conversation
    /// straight into the Web View. Reactions are badges, not messages, so a
    /// trailing reaction doesn't hide the HTML message before it.
    public var latestHTMLMessage: Message? {
        guard let latest = conversationMessages.last, latest.hasHTML else { return nil }
        return latest
    }
}

extension Message {
    /// The text Copy puts on the clipboard: what the reader sees in the bubble,
    /// the folded body without the quoted history under it. Nil when there is
    /// nothing to copy (a photo or voice message sent with no words, or a body
    /// that folds to nothing but a quote), so the menu hides the item.
    public var copyableText: String? {
        guard let body = bodyText?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        let visible = QuotedText.fold(body).visible
        return visible.isEmpty ? nil : visible
    }
}

extension ThreadSummary {
    /// The sender a Block Sender action would block when only the summary is
    /// known: the first participant other than the account. Nil for a thread of
    /// the user alone.
    public func blockableSender(as account: Account) -> Participant? {
        let me = account.emailAddress.lowercased()
        return participants.first { $0.address.lowercased() != me }
    }
}
