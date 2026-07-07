// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Type-ahead over the local address book for the recipient fields. As the user
// types a name or an email in To, Cc, or Bcc, this searches the on-device
// Contacts store and offers matches to tap. Like the avatar lookup, the read is
// local and display-only: the address book is loaded once into memory, searched
// there, and nothing ever leaves the device. A denied Contacts permission simply
// yields no suggestions, and the field still takes a typed address.

import Foundation
import Contacts
import ZirbeCore

/// Whether the local Contacts store may be read, asking once if it has never been
/// asked. Shared by the avatar lookup and the recipient type-ahead so the two
/// agree on what counts as access (limited access, iOS 18+, is enough to read
/// matches).
enum ContactsAuthorization {
    static func granted(_ store: CNContactStore) async -> Bool {
        // Demo/screenshot mode never touches Contacts, so no permission alert can
        // land on a capture. Avatars fall back to monograms, which is the intent.
        if DemoMode.isActive { return false }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await store.requestAccess(for: .contacts)) ?? false
        default:
            if #available(iOS 18.0, *), status == .limited { return true }
            return false
        }
    }
}

/// One address-book match offered under a recipient field: a name (possibly
/// empty) and the email it resolves to. One suggestion per email, so a contact
/// with several addresses offers each.
struct ContactSuggestion: Identifiable, Hashable {
    let name: String
    let email: String

    var id: String { "\(email)|\(name)" }

    /// The recipient token this fills into the field, in the `Name <addr>` form
    /// `RecipientParsing` round-trips (or the bare address when unnamed).
    var token: String {
        name.isEmpty ? email : "\(name) <\(email)>"
    }

    var participant: Participant { Participant(address: email, displayName: name.isEmpty ? nil : name) }
}

/// Searches the local Contacts store by name or email for the recipient
/// type-ahead. The address book is enumerated once (lazily, off the main thread
/// on this actor) into a flat list of name/email pairs, then every keystroke
/// filters that list in memory, so typing stays instant. A denied store yields an
/// empty list. The cache lives for the run; it isn't invalidated if the address
/// book changes mid-session, which is a fair trade for a compose sheet.
actor ContactSearchService {
    static let shared = ContactSearchService()

    private let store = CNContactStore()
    private var entries: [ContactSuggestion]?

    /// The best matches for `query`, ranked prefix-first, capped to a short list.
    /// Matches a prefix of the name, any name word, or the email; an empty or
    /// too-short query returns nothing.
    func search(_ query: String, limit: Int = 6) async -> [ContactSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let all = await loadEntries()
        var scored: [(entry: ContactSuggestion, rank: Int)] = []
        var seen = Set<String>()
        for entry in all {
            let name = entry.name.lowercased()
            let email = entry.email.lowercased()
            let rank: Int
            if name.hasPrefix(q) || email.hasPrefix(q) {
                rank = 0
            } else if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                rank = 1
            } else if name.contains(q) || email.contains(q) {
                rank = 2
            } else {
                continue
            }
            // One row per email; the first (best-ranked after sort) wins.
            scored.append((entry, rank))
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name) == .orderedAscending
            }
            .compactMap { scored in
                seen.insert(scored.entry.email.lowercased()).inserted ? scored.entry : nil
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Load and cache the flat name/email list from the address book, once.
    private func loadEntries() async -> [ContactSuggestion] {
        if let entries { return entries }
        guard await ContactsAuthorization.granted(store) else {
            entries = []
            return []
        }
        let keys: [CNKeyDescriptor] = [
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        var result: [ContactSuggestion] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            for email in contact.emailAddresses {
                let address = (email.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !address.isEmpty else { continue }
                result.append(ContactSuggestion(name: name, email: address))
            }
        }
        entries = result
        return result
    }
}

/// The text bookkeeping for a recipient field that holds several comma-separated
/// recipients: which fragment is being typed now, and how to complete it with a
/// chosen contact.
enum RecipientDraftText {
    /// The fragment currently being typed: the text after the last comma or
    /// semicolon, trimmed. Empty when the field ends on a separator.
    static func currentFragment(_ text: String) -> String {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;"))
        return (parts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace the in-progress fragment with a completed recipient token, keeping
    /// any earlier recipients and leaving a trailing ", " so the next one can be
    /// typed straight away.
    static func completing(_ text: String, with token: String) -> String {
        if let range = text.range(of: "[,;][^,;]*$", options: .regularExpression) {
            let head = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return head.isEmpty ? "\(token), " : "\(head), \(token), "
        }
        return "\(token), "
    }
}
