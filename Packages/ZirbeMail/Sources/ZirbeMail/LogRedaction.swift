// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Masking for the one identifying value the mail layer handles: the account's
// own address. Debug logs stay useful without carrying who the user is.

import Foundation

/// Masks values that shouldn't reach a log.
///
/// Zirbe sends nothing anywhere, but a debug line still lands in the device's log
/// store, which a sysdiagnose or a connected Mac can read back. The account
/// address is the one piece of identity this layer routinely holds, and a log
/// confirming a session opened doesn't need it to be useful.
enum LogRedaction {
    /// An email address with its local part — the half that names the person —
    /// removed, keeping the domain so a log still says which provider answered.
    /// Anything that isn't an address is masked whole rather than guessed at.
    static func address(_ address: String) -> String {
        guard let at = address.firstIndex(of: "@"), at != address.startIndex else { return "•••" }
        let domain = address[address.index(after: at)...]
        return domain.isEmpty ? "•••" : "•••@\(domain)"
    }
}
