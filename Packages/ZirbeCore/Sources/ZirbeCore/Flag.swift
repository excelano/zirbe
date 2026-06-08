// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// IMAP message flags, normalized into a domain enum. The mail engine hands us
// flags as strings; this turns the system flags we care about into cases and
// keeps anything else as a keyword.

import Foundation

/// A message flag. The standard IMAP system flags are modeled as cases; any
/// server- or user-defined keyword is preserved verbatim.
public enum Flag: Sendable, Hashable, Codable {
    case seen
    case answered
    case flagged
    case deleted
    case draft
    case recent
    case keyword(String)

    /// Build a flag from a raw IMAP flag string. Lenient on formatting: the
    /// engine may render system flags as `\Seen`, `Seen`, `.seen`, and so on,
    /// so we match on the contained keyword and fall back to `.keyword`.
    public init(imap raw: String) {
        let key = raw.lowercased().filter(\.isLetter)
        switch key {
        case let k where k.contains("seen"): self = .seen
        case let k where k.contains("answered"): self = .answered
        case let k where k.contains("flagged"): self = .flagged
        case let k where k.contains("deleted"): self = .deleted
        case let k where k.contains("draft"): self = .draft
        case let k where k.contains("recent"): self = .recent
        default: self = .keyword(raw)
        }
    }
}
