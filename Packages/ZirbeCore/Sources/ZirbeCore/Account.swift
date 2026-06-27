// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// An account and its mailboxes. Note what is NOT here: no password, no token.
// Credentials live in the Keychain, device-bound, referenced by account id.

import Foundation

/// A configured mail account. Holds only what we need to reach the server and
/// label it in the UI; the secret to authenticate is in the Keychain under
/// this account's id, never in the model.
public struct Account: Sendable, Hashable, Identifiable, Codable {
    /// Stable account identity, the email address.
    public var id: String
    public var emailAddress: String
    public var displayName: String?
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    public var username: String

    public init(
        id: String? = nil,
        emailAddress: String,
        displayName: String? = nil,
        imapHost: String,
        imapPort: Int = 993,
        smtpHost: String,
        smtpPort: Int = 587,
        username: String? = nil
    ) {
        let address = emailAddress.lowercased()
        self.id = id ?? address
        self.emailAddress = address
        self.displayName = displayName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = username ?? address
    }

    /// This account as a conversation participant, the sender of anything Zirbe
    /// sends from it. The display name carries through to the `From` header.
    public var selfParticipant: Participant {
        Participant(address: emailAddress, displayName: displayName)
    }
}

/// The well-known purpose of a mailbox, when we can determine it from IMAP
/// special-use attributes or name heuristics. Drives which folders the UI
/// surfaces and how it labels them.
public enum MailboxRole: String, Sendable, Hashable, Codable {
    case inbox, sent, drafts, trash, archive, junk
}

/// One IMAP folder within an account.
public struct Mailbox: Sendable, Hashable, Identifiable, Codable {
    public var accountID: String
    /// The IMAP folder name as the server reports it, e.g. `INBOX`.
    public var name: String
    public var role: MailboxRole?
    /// The server's hierarchy delimiter ("/" on Gmail, "." on Dovecot), or nil
    /// when unknown (an old cached row before its first server refresh).
    public var hierarchyDelimiter: String?

    public init(accountID: String, name: String, role: MailboxRole? = nil, hierarchyDelimiter: String? = nil) {
        self.accountID = accountID
        self.name = name
        self.role = role
        self.hierarchyDelimiter = hierarchyDelimiter
    }

    public var id: String { "\(accountID)/\(name)" }

    /// A short, human label for the switcher and titles: the INBOX reads as
    /// "Inbox", and a nested folder is flattened to its leaf (`INBOX.Sent` →
    /// "Sent", `[Gmail]/Sent Mail` → "Sent Mail"). Splitting uses the server's
    /// real delimiter, never a guess: a "." is a separator on Dovecot but a
    /// literal character in a Gmail label ("node.js"), so guessing would truncate
    /// it. With no known delimiter we leave the name whole rather than risk that.
    /// Leaf-only in v1; the full tree is out of scope.
    public var displayName: String {
        if role == .inbox || name == "INBOX" { return "Inbox" }
        guard let delimiter = hierarchyDelimiter?.first else { return name }
        let leaf = name.split(separator: delimiter).last
        return leaf.map(String.init) ?? name
    }
}
