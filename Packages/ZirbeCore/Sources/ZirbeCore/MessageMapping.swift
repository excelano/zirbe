// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Maps a ZirbeMail MailEnvelope into a domain Message. The one place ZirbeCore
// touches the mail layer's types, so the rest of the core is independent of how
// mail is fetched.

import ZirbeMail

extension Message {
    /// Build a domain message from a fetched envelope, parsing the raw address
    /// strings into participants and normalizing the flags.
    public init(_ envelope: MailEnvelope) {
        self.init(
            messageID: envelope.messageID,
            uid: envelope.uid,
            inReplyTo: envelope.inReplyTo,
            references: envelope.references,
            subject: envelope.subject,
            from: AddressParser.parseList(envelope.from).first,
            to: envelope.to.flatMap(AddressParser.parseList),
            date: envelope.date,
            flags: Set(envelope.flags.map(Flag.init(imap:)))
        )
    }
}
