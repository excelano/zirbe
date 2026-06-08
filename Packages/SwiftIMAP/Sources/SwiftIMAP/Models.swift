// SwiftIMAP — public value types.
//
// These are the entire public vocabulary of the library. None of Apple's
// swift-nio-imap types appear here, so callers depend only on SwiftIMAP.

import Foundation

/// An IMAP server endpoint. TLS is assumed (implicit TLS on connect).
public struct IMAPServer: Sendable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 993) {
        self.host = host
        self.port = port
    }
}

/// A username and password, or username and app-specific password.
public struct Credentials: Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// A named mailbox (folder) on the server.
public struct Mailbox: Sendable, Hashable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// The result of selecting a mailbox.
public struct MailboxStatus: Sendable, Hashable {
    public var name: String
    public var messageCount: Int
    public var recentCount: Int
    public var uidValidity: UInt32?
    public var uidNext: UInt32?

    public init(
        name: String,
        messageCount: Int = 0,
        recentCount: Int = 0,
        uidValidity: UInt32? = nil,
        uidNext: UInt32? = nil
    ) {
        self.name = name
        self.messageCount = messageCount
        self.recentCount = recentCount
        self.uidValidity = uidValidity
        self.uidNext = uidNext
    }
}

/// An email address parsed from an envelope. Any field may be absent because
/// real-world mail is inconsistent.
public struct Address: Sendable, Hashable, CustomStringConvertible {
    /// Display name, e.g. "David Anderson".
    public var name: String?
    /// Local part, the bit before the @.
    public var mailbox: String?
    /// Domain, the bit after the @.
    public var host: String?

    public init(name: String? = nil, mailbox: String? = nil, host: String? = nil) {
        self.name = name
        self.mailbox = mailbox
        self.host = host
    }

    /// The addr-spec ("local@domain") when both halves are present.
    public var email: String? {
        switch (mailbox, host) {
        case let (mailbox?, host?): return "\(mailbox)@\(host)"
        case let (mailbox?, nil): return mailbox
        default: return nil
        }
    }

    public var description: String {
        switch (name, email) {
        case let (name?, email?) where !name.isEmpty: return "\(name) <\(email)>"
        case let (_, email?): return email
        case let (name?, nil): return name
        default: return "(unknown)"
        }
    }
}

/// A message's envelope: the header-level metadata, with the threading headers
/// that identify which conversation a message belongs to.
public struct MessageEnvelope: Sendable, Hashable {
    public var sequenceNumber: UInt32?
    public var uid: UInt32?
    public var subject: String?
    public var date: String?
    public var from: [Address]
    public var sender: [Address]
    public var replyTo: [Address]
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var messageID: String?
    public var inReplyTo: String?
    public var flags: [String]

    public init(
        sequenceNumber: UInt32? = nil,
        uid: UInt32? = nil,
        subject: String? = nil,
        date: String? = nil,
        from: [Address] = [],
        sender: [Address] = [],
        replyTo: [Address] = [],
        to: [Address] = [],
        cc: [Address] = [],
        bcc: [Address] = [],
        messageID: String? = nil,
        inReplyTo: String? = nil,
        flags: [String] = []
    ) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        self.subject = subject
        self.date = date
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.flags = flags
    }
}

/// A contiguous range of message sequence numbers to fetch (1-based, inclusive).
public struct MessageRange: Sendable, Hashable {
    public var lowerBound: UInt32
    public var upperBound: UInt32

    public init(_ lowerBound: UInt32, through upperBound: UInt32) {
        precondition(lowerBound >= 1, "IMAP sequence numbers start at 1")
        self.lowerBound = Swift.min(lowerBound, upperBound)
        self.upperBound = Swift.max(lowerBound, upperBound)
    }

    public init(_ range: ClosedRange<UInt32>) {
        self.init(range.lowerBound, through: range.upperBound)
    }
}
