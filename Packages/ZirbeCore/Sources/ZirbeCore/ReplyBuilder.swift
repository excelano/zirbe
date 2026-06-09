// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The rules for replying into a conversation: who a reply-all goes to, the
// threading headers that keep it in the same thread, and a fresh Message-ID. All
// derived from the conversation's most recent message, never an all-time union,
// so a reply addresses whoever is currently on the thread rather than re-adding
// people who were dropped earlier.

import Foundation

public enum ReplyBuilder {
    /// The recipients of a reply-all into `thread`, sent as `account`.
    ///
    /// To keeps the latest message's sender together with its To recipients; Cc
    /// keeps its Cc. The account's own address is removed from both (you don't
    /// reply to yourself), and no address appears twice, with To winning over Cc.
    /// Returns empty lists for an empty thread.
    public static func replyAllRecipients(
        to thread: Thread,
        as account: Account
    ) -> (to: [Participant], cc: [Participant]) {
        guard let latest = thread.messages.last else { return ([], []) }
        let me = account.emailAddress.lowercased()
        var placed: Set<String> = [me]

        var to: [Participant] = []
        for p in ([latest.from].compactMap { $0 } + latest.to) where placed.insert(p.address).inserted {
            to.append(p)
        }
        var cc: [Participant] = []
        for p in latest.cc where placed.insert(p.address).inserted {
            cc.append(p)
        }

        // A note to self: the only person on the latest message is the account,
        // so dropping yourself left nobody. Email lets you write to yourself, so
        // address the reply back to you rather than to no one.
        if to.isEmpty && cc.isEmpty {
            return ([account.selfParticipant], [])
        }
        return (to, cc)
    }

    /// The `In-Reply-To` and `References` for a reply into `thread`. In-Reply-To
    /// is the latest message's Message-ID; References extends that message's
    /// chain with its own id, so the reply slots in beneath it.
    public static func threadingHeaders(
        replyingTo thread: Thread
    ) -> (inReplyTo: String?, references: [String]) {
        guard let latest = thread.messages.last else { return (nil, []) }
        var references = latest.references.filter { !$0.isEmpty }
        if let mid = latest.messageID, !mid.isEmpty, references.last != mid {
            references.append(mid)
        }
        return (latest.messageID, references)
    }

    /// A fresh, globally-unique Message-ID for an outgoing message, in
    /// `<id@domain>` form. The domain comes from the account address so the id is
    /// well-formed; it is generated before sending so the SMTP send and the
    /// Sent-folder copy carry the same value and a retry deduplicates.
    public static func generateMessageID(for account: Account) -> String {
        let domain = account.emailAddress.split(separator: "@").last.map(String.init) ?? "localhost"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    /// A reply subject: the thread subject with a single `Re:` prefix. The thread
    /// subject is already normalized (prior `Re:`/`Fwd:` stripped), so this adds
    /// exactly one and never stacks them.
    public static func replySubject(for thread: Thread) -> String {
        let base = thread.subject.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Re:" : "Re: \(base)"
    }
}
