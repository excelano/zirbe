// Maps SwiftMail's MessageInfo into Zirbe's MailEnvelope. The only file that
// imports SwiftMail's model types; keeping it isolated is what makes the
// engine swappable.

import SwiftMail

extension MailEnvelope {
    init(_ info: MessageInfo) {
        self.init(
            sequenceNumber: info.sequenceNumber.value,
            uid: info.uid?.value,
            subject: info.subject,
            from: info.from,
            to: info.to,
            cc: info.cc,
            date: info.date,
            messageID: info.messageId?.description,
            inReplyTo: info.inReplyTo?.description,
            references: (info.references ?? []).map(\.description),
            flags: info.flags.map { String(describing: $0) }
        )
    }
}

extension MailboxInfo {
    init(_ info: Mailbox.Info) {
        self.init(
            name: info.name,
            specialUse: MailboxSpecialUse(info),
            isSelectable: info.isSelectable,
            hierarchyDelimiter: info.hierarchyDelimiter
        )
    }
}

extension MailboxSpecialUse {
    /// Resolve a folder's role from its RFC 6154 special-use attributes. A folder
    /// literally named INBOX is the inbox even when the server omits the `\Inbox`
    /// attribute (many do); the rest come straight from the advertised flags.
    /// `nil` for an ordinary user folder.
    init?(_ info: Mailbox.Info) {
        if info.name.uppercased() == "INBOX" || info.attributes.contains(.inbox) {
            self = .inbox
        } else if info.attributes.contains(.sent) {
            self = .sent
        } else if info.attributes.contains(.drafts) {
            self = .drafts
        } else if info.attributes.contains(.trash) {
            self = .trash
        } else if info.attributes.contains(.archive) {
            self = .archive
        } else if info.attributes.contains(.junk) {
            self = .junk
        } else {
            return nil
        }
    }
}
