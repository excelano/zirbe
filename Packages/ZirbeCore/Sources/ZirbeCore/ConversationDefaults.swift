// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Naming for conversations the user never titled. Zirbe shows a conversation by
// its title, and carries that title over email as the Subject header. When the
// user starts a conversation without naming it, we still need a subject on the
// wire (the title is only ever derived from it), so we send a neutral default;
// for display, an unnamed thread falls back to the other participants' names, the
// way Messages titles a chat by who it's with rather than by an empty subject.

import Foundation

public enum ConversationDefaults {
    /// The Subject sent for a conversation the user didn't name. Neutral on
    /// purpose: it lands in non-Zirbe inboxes, so it must not read as branding.
    public static let unnamedSubject = "Chat"

    /// The title to show for a thread: the user-given subject when there is one,
    /// otherwise "Chat with <the other people>", computed per viewer so each side
    /// sees the others and never their own name (a thread is "unnamed" when its
    /// subject is empty or is exactly the default we send). A chat with no one
    /// else — a note to self — keeps the bare default.
    public static func displayTitle(
        subject: String,
        participants: [Participant],
        selfAddress: String
    ) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != unnamedSubject { return trimmed }

        let me = selfAddress.lowercased()
        let others = participants
            .filter { $0.address.lowercased() != me }
            .prefix(3)
            .map(\.label)
        guard !others.isEmpty else { return unnamedSubject }
        return "\(unnamedSubject) with \(others.joined(separator: ", "))"
    }
}
