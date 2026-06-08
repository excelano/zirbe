// Maps swift-nio-imap's codec types into SwiftIMAP's public value types.
// Keeping this in one place is what lets the public API stay free of any
// swift-nio-imap type.

import NIOCore
import NIOIMAP

extension Address {
    /// Maps a single envelope address. Group syntax (RFC 5322 address groups)
    /// is skipped; it is rare in practice and not needed yet.
    init?(_ element: EmailAddressListElement) {
        guard case .singleAddress(let address) = element else { return nil }
        self.init(
            name: address.personName.map { String(buffer: $0) },
            mailbox: address.mailbox.map { String(buffer: $0) },
            host: address.host.map { String(buffer: $0) }
        )
    }
}

enum EnvelopeMapping {
    static func addresses(_ elements: [EmailAddressListElement]) -> [Address] {
        elements.compactMap(Address.init)
    }

    /// swift-nio-imap (0.2.0) keeps the raw `String` of `MessageID` and
    /// `InternetMessageDate` internal with no public accessor. These are the
    /// threading headers we depend on, so until the library exposes them we
    /// read the stored value reflectively. Contained here on purpose.
    static func rawString(_ value: Any) -> String? {
        for child in Mirror(reflecting: value).children where child.label == "rawValue" {
            return child.value as? String
        }
        return nil
    }
}

extension MessageEnvelope {
    mutating func apply(_ attribute: MessageAttribute) {
        switch attribute {
        case .uid(let value):
            uid = value.rawValue
        case .flags(let flags):
            self.flags = flags.map { String(describing: $0) }
        case .envelope(let envelope):
            // TODO: subjects/names may be RFC 2047 encoded-words; decode later.
            subject = envelope.subject.map { String(buffer: $0) }
            date = envelope.date.flatMap { EnvelopeMapping.rawString($0) }
            from = EnvelopeMapping.addresses(envelope.from)
            sender = EnvelopeMapping.addresses(envelope.sender)
            replyTo = EnvelopeMapping.addresses(envelope.reply)
            to = EnvelopeMapping.addresses(envelope.to)
            cc = EnvelopeMapping.addresses(envelope.cc)
            bcc = EnvelopeMapping.addresses(envelope.bcc)
            messageID = envelope.messageID.flatMap { EnvelopeMapping.rawString($0) }
            inReplyTo = envelope.inReplyTo.flatMap { EnvelopeMapping.rawString($0) }
        default:
            break
        }
    }
}
