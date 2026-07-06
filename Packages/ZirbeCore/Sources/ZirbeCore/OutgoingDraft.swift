// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A composed message ready to send: the domain layer's view of an outgoing mail,
// in ZirbeCore's own vocabulary (Participant, Message). It knows how to produce
// the two things the send path needs from one source of truth: the ZirbeMail
// OutgoingMessage that goes over SMTP and into the Sent folder, and the local
// Message inserted optimistically so the bubble appears the instant we send.
//
// Both carry the same Message-ID, generated once when the draft is built, so the
// optimistic copy and the eventual Sent re-sync are the same row and a retry
// can't double it.

import Foundation
import ZirbeMail

/// A message the user has composed and is about to send. Build it with `reply`
/// or `new`; the send orchestration turns it into an SMTP send plus an
/// optimistic local insert.
public struct OutgoingDraft: Sendable, Hashable {
    public var from: Participant
    public var to: [Participant]
    public var cc: [Participant]
    /// Blind recipients. They receive the message over SMTP but appear in no
    /// header, so neither the To/Cc recipients nor each other see them. Carried
    /// here so the send path can hand them to the transport's envelope; left out
    /// of the optimistic local copy, which has no place to show a blind list.
    public var bcc: [Participant]
    public var subject: String
    /// The full composed body: the user's words plus, for a reply, the quote
    /// trailer. Already assembled, so the send path sends it verbatim.
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    /// The Message-ID shared by the SMTP send, the Sent copy, and the optimistic
    /// local row. Generated once at build time.
    public var messageID: String
    /// When the message is sent, stamped on the local copy so it sorts last in
    /// the conversation immediately.
    public var date: Date
    /// Files sent with the message, each carrying its bytes: the user's picked
    /// files on a new message or reply, or the original's attachments on a
    /// forward. The optimistic local copy shows these as chips with no part
    /// section, so they render but can't be re-opened until the Sent re-sync
    /// restamps real ones.
    public var attachments: [OutgoingAttachment]
    /// A reaction emoji when this draft is a tapback rather than a chat message,
    /// else nil. It rides out as the `X-Zirbe-Reaction` header (see
    /// `outgoingMessage`) and is stamped on the optimistic local copy so the
    /// badge appears at once (see `localMessage`).
    public var reaction: String?

    public init(
        from: Participant,
        to: [Participant],
        cc: [Participant] = [],
        bcc: [Participant] = [],
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        messageID: String,
        date: Date,
        attachments: [OutgoingAttachment] = [],
        reaction: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageID = messageID
        self.date = date
        self.attachments = attachments
        self.reaction = reaction
    }

    /// The wire form handed to the mail engine for SMTP send and Sent-append.
    public var outgoingMessage: OutgoingMessage {
        OutgoingMessage(
            from: OutgoingAddress(address: from.address, name: from.displayName),
            to: to.map { OutgoingAddress(address: $0.address, name: $0.displayName) },
            cc: cc.map { OutgoingAddress(address: $0.address, name: $0.displayName) },
            bcc: bcc.map { OutgoingAddress(address: $0.address, name: $0.displayName) },
            subject: subject,
            textBody: body,
            inReplyTo: inReplyTo,
            references: references,
            messageID: messageID,
            attachments: attachments,
            headers: reaction.map { [MailHeader.zirbeReaction: $0] } ?? [:]
        )
    }

    /// The optimistic local copy, inserted into the store the moment we send so
    /// the message shows in its conversation without waiting for a Sent re-sync.
    /// Flagged read (the user wrote it) and carries the same Message-ID, so a
    /// later Sent sync updates this same row instead of adding a duplicate.
    public var localMessage: Message {
        Message(
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            date: date,
            flags: [.seen],
            bodyText: body,
            attachments: attachments.map {
                // No part section yet: the chip names the file but stays
                // un-openable until the Sent re-sync supplies the real section.
                MessageAttachment(filename: $0.filename, mimeType: $0.mimeType, partID: "")
            },
            reaction: reaction
        )
    }

    /// The optimistic local copy of a *draft*, filed in the Drafts folder. Like
    /// `localMessage` but flagged `\Draft` and stamped with the UID the APPEND
    /// returned (when the server supports UIDPLUS), so the draft shows at once and
    /// a later edit or send can replace or expunge the right server copy without
    /// first re-syncing Drafts. A nil `uid` means the server reported none; the
    /// UID is then learned on the next Drafts sync.
    func draftLocalMessage(uid: UInt32?) -> Message {
        var message = localMessage
        message.uid = uid
        message.flags = [.seen, .draft]
        return message
    }
}

extension DraftAttachment {
    /// The transport-layer form handed to the send path. The domain stages a
    /// picked file as a `DraftAttachment` and converts here, so the app stays one
    /// layer away from ZirbeMail's `OutgoingAttachment`.
    var outgoing: OutgoingAttachment {
        OutgoingAttachment(filename: filename, mimeType: mimeType, data: data)
    }
}

extension OutgoingDraft {
    /// A reply into `thread`, sent as `account`. Recipients are passed in
    /// explicitly (the UI starts from `ReplyBuilder.replyAllRecipients` and lets
    /// the user remove people, group-chat style), while the subject, threading
    /// headers, quote trailer, and Message-ID are derived from the thread. The
    /// quoted message defaults to the conversation's most recent; pass `replyingTo`
    /// to answer an earlier message specifically (swipe-to-reply), which quotes and
    /// threads onto that message instead.
    public static func reply(
        to thread: Thread,
        as account: Account,
        to recipients: [Participant],
        cc: [Participant],
        body userText: String,
        attachments: [OutgoingAttachment] = [],
        replyingTo target: Message? = nil,
        sentAt date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> OutgoingDraft {
        let quoted = target ?? thread.messages.last
        let (inReplyTo, references) = target.map { ReplyBuilder.threadingHeaders(replyingTo: $0) }
            ?? ReplyBuilder.threadingHeaders(replyingTo: thread)
        let composed = quoted.map {
            QuotedText.replyBody(userText, quoting: $0, locale: locale, timeZone: timeZone)
        } ?? userText.trimmingCharacters(in: .whitespacesAndNewlines)
        return OutgoingDraft(
            from: account.selfParticipant,
            to: recipients,
            cc: cc,
            subject: ReplyBuilder.replySubject(for: thread),
            body: composed,
            inReplyTo: inReplyTo,
            references: references,
            messageID: ReplyBuilder.generateMessageID(for: account),
            date: date,
            attachments: attachments
        )
    }

    /// A reaction (tapback) to `target` within `thread`, sent as `account`. It
    /// carries the emoji as the `X-Zirbe-Reaction` header so a receiving Zirbe
    /// renders a badge, and a readable body ("Reacted 👍 to '…'") so any other
    /// client shows a sensible line instead. Threading points `In-Reply-To` at
    /// the reacted-to message specifically (not the thread's latest), so the
    /// badge lands on the right bubble; recipients are the thread's reply-all set,
    /// so in a group everyone sees the reaction. The caller guarantees `target`
    /// carries a Message-ID, which is what the reaction threads onto.
    public static func reaction(
        to target: Message,
        in thread: Thread,
        as account: Account,
        emoji: String,
        sentAt date: Date = Date()
    ) -> OutgoingDraft {
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: account)
        let targetID = target.messageID ?? ""
        var references = target.references.filter { !$0.isEmpty }
        if !targetID.isEmpty, references.last != targetID { references.append(targetID) }
        return OutgoingDraft(
            from: account.selfParticipant,
            to: to,
            cc: cc,
            subject: ReplyBuilder.replySubject(for: thread),
            body: ReactionText.body(emoji: emoji, target: target),
            inReplyTo: targetID.isEmpty ? nil : targetID,
            references: references,
            messageID: ReplyBuilder.generateMessageID(for: account),
            date: date,
            reaction: emoji
        )
    }

    /// A forward of `message` to fresh recipients, sent as `account`. A forward
    /// starts a new conversation: it goes to different people under a `Fwd:`
    /// subject, so it carries no threading headers and won't slot into the source
    /// thread. The body is the user's optional note plus the forwarded-message
    /// block; the attachments are the original's files, already refetched into
    /// bytes by the caller. The subject is passed in already prefixed.
    public static func forward(
        message: Message,
        subject: String,
        as account: Account,
        to recipients: [Participant],
        cc: [Participant],
        note: String,
        attachments: [OutgoingAttachment],
        sentAt date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> OutgoingDraft {
        OutgoingDraft(
            from: account.selfParticipant,
            to: recipients,
            cc: cc,
            subject: subject,
            body: QuotedText.forwardBody(note, forwarding: message, locale: locale, timeZone: timeZone),
            messageID: ReplyBuilder.generateMessageID(for: account),
            date: date,
            attachments: attachments
        )
    }

    /// A draft of a new conversation, ready to APPEND to the Drafts folder. Same
    /// shape as `new`, with two differences: the Message-ID is supplied rather
    /// than generated, so editing an existing draft keeps one id (and so one local
    /// row, one thread, and one reconciliation key) across saves; and the body is
    /// kept verbatim rather than trimmed, since a draft is mid-composition and its
    /// leading or trailing whitespace is the user's. No threading headers, since
    /// reply-drafts are out of scope for v1; no content guardrails, since a draft
    /// may be half-written with an empty subject, body, or recipient list.
    public static func draft(
        from account: Account,
        to recipients: [Participant],
        cc: [Participant] = [],
        subject: String,
        body: String,
        attachments: [OutgoingAttachment] = [],
        messageID: String,
        savedAt date: Date
    ) -> OutgoingDraft {
        OutgoingDraft(
            from: account.selfParticipant,
            to: recipients,
            cc: cc,
            subject: subject,
            body: body,
            messageID: messageID,
            date: date,
            attachments: attachments
        )
    }

    /// A brand-new conversation from `account`. Answers nothing, so it carries no
    /// threading headers; the subject is sent as given (the send guardrail
    /// requires it be non-empty).
    public static func new(
        from account: Account,
        to recipients: [Participant],
        cc: [Participant] = [],
        bcc: [Participant] = [],
        subject: String,
        body: String,
        attachments: [OutgoingAttachment] = [],
        sentAt date: Date
    ) -> OutgoingDraft {
        OutgoingDraft(
            from: account.selfParticipant,
            to: recipients,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            messageID: ReplyBuilder.generateMessageID(for: account),
            date: date,
            attachments: attachments
        )
    }
}
