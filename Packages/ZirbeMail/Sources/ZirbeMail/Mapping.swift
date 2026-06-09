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
