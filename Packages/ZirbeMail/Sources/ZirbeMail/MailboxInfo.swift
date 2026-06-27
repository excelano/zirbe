// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Zirbe-owned value types describing the server's folders (mailboxes), so the
// engine can list them and resolve their roles without exposing any SwiftMail
// type. The mapping from SwiftMail's Mailbox.Info lives in Mapping.swift, the
// one file that touches SwiftMail's models.

import Foundation

/// The standard role a folder plays, from its RFC 6154 special-use attribute, so
/// the UI can name and order folders meaningfully ("Sent", "Trash") regardless of
/// the server's own folder name. `nil` for an ordinary user folder with no
/// special role. The domain layer maps this onto its own MailboxRole; keeping a
/// ZirbeMail-native enum is what keeps this layer free of ZirbeCore.
public enum MailboxSpecialUse: String, Sendable, Hashable {
    case inbox, sent, drafts, trash, archive, junk
}

/// One folder as the server reports it: the name every other folder operation
/// takes, its resolved special-use role, and whether it can hold messages.
/// Container-only folders (the `\Noselect` parents some servers use for
/// hierarchy) come back with `isSelectable == false`; whether to show them is the
/// caller's decision, not the engine's.
public struct MailboxInfo: Sendable, Hashable {
    /// The IMAP folder name as the server reports it, e.g. `INBOX` or
    /// `[Gmail]/All Mail`. This is the identifier passed to select, sync, and move.
    public var name: String
    /// The folder's special-use role, or nil for an ordinary user folder.
    public var specialUse: MailboxSpecialUse?
    /// Whether the folder can be selected and hold messages. A container folder
    /// that only groups children is not selectable.
    public var isSelectable: Bool
    /// The server's hierarchy delimiter for this folder ("/" on Gmail, "." on
    /// Dovecot), or nil when the server didn't report one. The only safe way to
    /// flatten a nested name to its leaf, since a "." is a separator on one server
    /// and a literal character on another.
    public var hierarchyDelimiter: String?

    public init(
        name: String,
        specialUse: MailboxSpecialUse? = nil,
        isSelectable: Bool = true,
        hierarchyDelimiter: String? = nil
    ) {
        self.name = name
        self.specialUse = specialUse
        self.isSelectable = isSelectable
        self.hierarchyDelimiter = hierarchyDelimiter
    }
}
