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
    /// Files sent with the message, each carrying its bytes. Empty for a reply or
    /// a new message; a forward fills it with the original's attachments. The
    /// optimistic local copy shows these as chips with no part section, so they
    /// render but can't be re-opened until the Sent re-sync restamps real ones.
    public var attachments: [OutgoingAttachment]

    public init(
        from: Participant,
        to: [Participant],
        cc: [Participant] = [],
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        messageID: String,
        date: Date,
        attachments: [OutgoingAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageID = messageID
        self.date = date
        self.attachments = attachments
    }

    /// The wire form handed to the mail engine for SMTP send and Sent-append.
    public var outgoingMessage: OutgoingMessage {
        OutgoingMessage(
            from: OutgoingAddress(address: from.address, name: from.displayName),
            to: to.map { OutgoingAddress(address: $0.address, name: $0.displayName) },
            cc: cc.map { OutgoingAddress(address: $0.address, name: $0.displayName) },
            subject: subject,
            textBody: body,
            inReplyTo: inReplyTo,
            references: references,
            messageID: messageID,
            attachments: attachments
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
            }
        )
    }
}

extension OutgoingDraft {
    /// A reply into `thread`, sent as `account`. Recipients are passed in
    /// explicitly (the UI starts from `ReplyBuilder.replyAllRecipients` and lets
    /// the user remove people, group-chat style), while the subject, threading
    /// headers, quote trailer, and Message-ID are derived from the thread. The
    /// quoted message is the conversation's most recent.
    public static func reply(
        to thread: Thread,
        as account: Account,
        to recipients: [Participant],
        cc: [Participant],
        body userText: String,
        sentAt date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> OutgoingDraft {
        let (inReplyTo, references) = ReplyBuilder.threadingHeaders(replyingTo: thread)
        let composed = thread.messages.last.map {
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
            date: date
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

    /// A brand-new conversation from `account`. Answers nothing, so it carries no
    /// threading headers; the subject is sent as given (the send guardrail
    /// requires it be non-empty).
    public static func new(
        from account: Account,
        to recipients: [Participant],
        cc: [Participant] = [],
        subject: String,
        body: String,
        sentAt date: Date
    ) -> OutgoingDraft {
        OutgoingDraft(
            from: account.selfParticipant,
            to: recipients,
            cc: cc,
            subject: subject,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            messageID: ReplyBuilder.generateMessageID(for: account),
            date: date
        )
    }
}
