// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Who joined or left the conversation, derived by comparing each message's
// people to the message before it, the way a group chat shows "Carol was
// removed". Membership is just who a message is from and to (From, To, Cc), so
// this needs no stored roster: the messages are the record.
//
// The account's own address is never reported. Zirbe only holds messages the
// user was party to, so a truthful "you were removed" can't be derived from the
// envelopes anyway, and an apparent self-drop is usually a Bcc artifact (a Bcc'd
// message hides the user from To/Cc) that would mislead. Other people's changes
// are reported normally.

import Foundation

public enum ParticipantChange {
    /// The people added and removed at one message boundary, shown above that
    /// message. Only boundaries with a real change produce a delta.
    public struct Delta: Sendable, Hashable, Identifiable {
        /// The id of the message this change precedes.
        public var messageID: String
        public var added: [Participant]
        public var removed: [Participant]

        public init(messageID: String, added: [Participant], removed: [Participant]) {
            self.messageID = messageID
            self.added = added
            self.removed = removed
        }

        public var id: String { messageID }
    }

    /// The membership changes across a conversation's messages, oldest first.
    /// For each adjacent pair, whoever is on the newer message but not the older
    /// was added, and whoever fell off was removed. The account's own address is
    /// excluded from both. Boundaries with no change are omitted.
    public static func deltas(across messages: [Message], excluding selfAddress: String) -> [Delta] {
        guard messages.count >= 2 else { return [] }
        let me = selfAddress.lowercased()

        var deltas: [Delta] = []
        for index in 1..<messages.count {
            let before = members(of: messages[index - 1])
            let after = members(of: messages[index])
            let beforeAddrs = Set(before.map(\.address))
            let afterAddrs = Set(after.map(\.address))

            let addedAddrs = afterAddrs.subtracting(beforeAddrs).subtracting([me])
            let removedAddrs = beforeAddrs.subtracting(afterAddrs).subtracting([me])
            guard !addedAddrs.isEmpty || !removedAddrs.isEmpty else { continue }

            deltas.append(Delta(
                messageID: messages[index].id,
                added: pick(addedAddrs, from: after),
                removed: pick(removedAddrs, from: before)
            ))
        }
        return deltas
    }

    /// Everyone on a message: its sender plus its To and Cc recipients.
    private static func members(of message: Message) -> [Participant] {
        [message.from].compactMap { $0 } + message.to + message.cc
    }

    /// The participants in `pool` whose address is in `addresses`, deduplicated by
    /// address and keeping the first (richest) occurrence for its display name.
    private static func pick(_ addresses: Set<String>, from pool: [Participant]) -> [Participant] {
        var seen = Set<String>()
        var result: [Participant] = []
        for p in pool where addresses.contains(p.address) && seen.insert(p.address).inserted {
            result.append(p)
        }
        return result
    }
}
