// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The client-side threading pass. Given a flat list of messages, group them
// into conversations using their RFC 5322 Message-ID / In-Reply-To / References
// headers, following Jamie Zawinski's message-threading algorithm
// (https://www.jwz.org/doc/threading.html). The output is what the inbox shows:
// one Thread per conversation, each a flat, time-ordered list of messages.
//
// Why JWZ and not the IMAP THREAD extension: SwiftMail does not expose
// server-side THREAD, and a single client pass behaves identically across every
// provider, which is simpler and more predictable than a server-or-client
// split. Why subject merging is off by default: JWZ's subject-grouping step is
// the part prone to false merges (two unrelated "Re: lunch" threads collapsing
// into one). For a named-group-chat UI a false merge is worse than a missed
// one, so v1 threads on headers alone and leaves subject merging as a toggle.

import Foundation

public enum Threader {
    /// Group `messages` into conversations.
    ///
    /// - Parameter mergeBySubject: when true, runs JWZ's final subject-grouping
    ///   step to also merge root threads that share a normalized subject. Off by
    ///   default; see the file note on false merges.
    /// - Returns: one `Thread` per conversation, each with its messages oldest
    ///   first. Thread order is unspecified; callers sort (typically by
    ///   `lastActivity`).
    public static func thread(_ messages: [Message], mergeBySubject: Bool = false) -> [Thread] {
        let forest = buildForest(messages)
        var roots = prune(forest, isRoot: true)
        if mergeBySubject {
            roots = mergeRootsBySubject(roots)
        }
        return roots.map(makeThread)
    }

    // MARK: - JWZ container tree

    /// A node in the threading tree. May hold a real message or stand in for one
    /// we only know about because something referenced it.
    private final class Container {
        var message: Message?
        weak var parent: Container?
        var children: [Container] = []
        /// The id this container is keyed by. For keyed containers it is a real
        /// Message-ID (possibly of a message we never received); for anonymous
        /// or duplicate ones it is a synthetic, non-shared marker.
        let key: String
        /// Whether `key` is a real, shareable Message-ID.
        let keyed: Bool

        init(key: String, keyed: Bool) {
            self.key = key
            self.keyed = keyed
        }
    }

    /// Is `ancestor` somewhere above `node` in the tree? Used to refuse links
    /// that would create a cycle.
    private static func isAncestor(_ ancestor: Container, of node: Container) -> Bool {
        var p = node.parent
        while let cur = p {
            if cur === ancestor { return true }
            p = cur.parent
        }
        return false
    }

    /// Step 1: build the container forest from the messages.
    private static func buildForest(_ messages: [Message]) -> [Container] {
        var idTable: [String: Container] = [:]
        var all: [Container] = []
        var anonCounter = 0

        func keyedContainer(_ id: String) -> Container {
            if let existing = idTable[id] { return existing }
            let c = Container(key: id, keyed: true)
            idTable[id] = c
            all.append(c)
            return c
        }

        func anonContainer(_ reason: String) -> Container {
            let c = Container(key: "\(reason):\(anonCounter)", keyed: false)
            anonCounter += 1
            all.append(c)
            return c
        }

        for message in messages {
            // 1A: find or make the container for this message.
            let this: Container
            if let mid = message.messageID, !mid.isEmpty {
                if let existing = idTable[mid] {
                    if existing.message == nil {
                        existing.message = message
                        this = existing
                    } else {
                        // Duplicate Message-ID: keep both, but the second can't
                        // own the shared key.
                        let c = anonContainer("dup")
                        c.message = message
                        this = c
                    }
                } else {
                    let c = keyedContainer(mid)
                    c.message = message
                    this = c
                }
            } else {
                let c = anonContainer("anon")
                c.message = message
                this = c
            }

            // 1B: link the ancestry chain together, oldest -> newest.
            let chain = ancestry(of: message)
            var prev: Container?
            for refID in chain {
                let rc = keyedContainer(refID)
                if let prev,
                   rc.parent == nil,
                   rc !== prev,
                   !isAncestor(rc, of: prev) {
                    rc.parent = prev
                    prev.children.append(rc)
                }
                prev = rc
            }

            // 1C: the last ancestry element is this message's parent. Trust the
            // real message over any parent we presumed earlier, unless that
            // would form a cycle.
            if let newParent = prev, newParent !== this, !isAncestor(this, of: newParent) {
                this.parent?.children.removeAll { $0 === this }
                this.parent = newParent
                newParent.children.append(this)
            }
        }

        return all.filter { $0.parent == nil }
    }

    /// The ancestry chain for a message: its References, with In-Reply-To
    /// appended when it adds a parent References omitted (some mailers send
    /// In-Reply-To but no References).
    private static func ancestry(of message: Message) -> [String] {
        var chain = message.references.filter { !$0.isEmpty }
        if let irt = message.inReplyTo, !irt.isEmpty, chain.last != irt {
            chain.append(irt)
        }
        return chain
    }

    // MARK: - Pruning

    /// Step 4: drop containers that hold no message and contribute no structure,
    /// promoting real children up so threads don't gain phantom levels.
    private static func prune(_ containers: [Container], isRoot: Bool) -> [Container] {
        var result: [Container] = []
        for c in containers {
            c.children = prune(c.children, isRoot: false)

            if c.message == nil && c.children.isEmpty {
                continue // empty and childless: gone.
            }
            if c.message == nil && !isRoot {
                // Empty interior node: splice its children into this level.
                for child in c.children { child.parent = c.parent }
                result.append(contentsOf: c.children)
                continue
            }
            // Keep: has a message, or is an empty root standing in for a
            // conversation whose original message we never received. We keep
            // empty roots (rather than promoting a child, as JWZ does for tree
            // display) so the thread's identity stays anchored to the referenced
            // Message-ID and never shifts if that root message arrives later.
            result.append(c)
        }
        return result
    }

    // MARK: - Optional subject grouping

    /// Step 5 (opt-in): merge root threads that share a normalized subject under
    /// a synthetic parent. Conservative is still imperfect; see the file note.
    private static func mergeRootsBySubject(_ roots: [Container]) -> [Container] {
        var bySubject: [String: Container] = [:]
        var order: [String] = []
        var merged: [Container] = []

        for root in roots {
            let subject = SubjectNormalizer.normalize(rootSubject(root))
            guard !subject.isEmpty else { merged.append(root); continue }
            if let group = bySubject[subject] {
                root.parent = group
                group.children.append(root)
            } else {
                let group = Container(key: "subj:\(subject)", keyed: false)
                group.children.append(root)
                root.parent = group
                bySubject[subject] = group
                order.append(subject)
            }
        }
        for subject in order {
            let group = bySubject[subject]!
            // A lone group is just its single child; unwrap it.
            merged.append(group.children.count == 1 ? group.children[0] : group)
        }
        for m in merged where m.parent != nil { m.parent = nil }
        return merged
    }

    // MARK: - Thread assembly

    /// Flatten a root container's subtree into a chronological Thread.
    private static func makeThread(_ root: Container) -> Thread {
        var collected: [Message] = []
        collect(root, into: &collected)
        let messages = collected.chronological()

        let subject = SubjectNormalizer.normalize(messages.first { ($0.subject?.isEmpty == false) }?.subject)
        let lastActivity = messages.compactMap(\.date).max()

        var seen = Set<String>()
        var participants: [Participant] = []
        for message in messages {
            for p in ([message.from].compactMap { $0 } + message.to + message.cc) where seen.insert(p.address).inserted {
                participants.append(p)
            }
        }

        return Thread(
            id: threadID(for: root, messages: messages),
            subject: subject,
            messages: messages,
            participants: participants,
            lastActivity: lastActivity
        )
    }

    private static func collect(_ c: Container, into messages: inout [Message]) {
        if let m = c.message { messages.append(m) }
        for child in c.children { collect(child, into: &messages) }
    }

    /// Stable thread identity. Prefer the root's real Message-ID, even if the
    /// root message itself was never received (its key is the id everything
    /// references), then the earliest message's id.
    private static func threadID(for root: Container, messages: [Message]) -> String {
        if let mid = root.message?.messageID, !mid.isEmpty { return "mid:\(mid)" }
        if root.keyed { return "mid:\(root.key)" }
        return messages.first?.id ?? root.key
    }

    private static func rootSubject(_ root: Container) -> String? {
        if let s = root.message?.subject { return s }
        var stack = root.children
        while let c = stack.popLast() {
            if let s = c.message?.subject { return s }
            stack.append(contentsOf: c.children)
        }
        return nil
    }
}
