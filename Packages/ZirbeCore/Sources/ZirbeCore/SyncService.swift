// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The glue between the mail engine and the store. It fetches from the server,
// maps envelopes into domain messages, persists them, and recomputes threads.
// The UI never calls this directly for data; it reads the store, which this
// fills.

import Foundation
import ZirbeMail

/// Drives a sync for one account: fetch, store, rethread. Thin by design; the
/// engine owns the protocol and the store owns persistence.
public actor SyncService {
    private let account: Account
    private let store: MailStore
    private let engine: MailEngine
    private let sender: MailSender

    public init(account: Account, store: MailStore) {
        self.account = account
        self.store = store
        self.engine = MailEngine(config: MailServerConfig(host: account.imapHost, port: account.imapPort))
        self.sender = MailSender(config: MailServerConfig(host: account.smtpHost, port: account.smtpPort))
    }

    /// Fetch the most recent `limit` messages from `mailbox`, reconcile the cache
    /// against the server, and recompute conversations. Returns the resulting
    /// inbox summaries.
    ///
    /// Reconciliation is what makes a refresh reflect deletions made in another
    /// client, not just additions. First the server's UIDVALIDITY is compared to
    /// the one last stored: a change means the mailbox was renumbered and every
    /// cached UID is stale, so the local copy is cleared and rebuilt. Then, after
    /// saving the freshly fetched headers, any cached message whose UID the server
    /// no longer reports is pruned, so a thread deleted elsewhere disappears here.
    ///
    /// The password is passed in per call and never stored on the service; it
    /// comes from the Keychain at the call site and is used only for the IMAP
    /// login over TLS. The engine keeps the connection warm between calls, so a
    /// later sync or conversation open reuses it rather than reconnecting.
    @discardableResult
    public func syncInbox(
        password: String,
        mailbox: String = "INBOX",
        limit: Int = 50
    ) async throws -> [ThreadSummary] {
        try await engine.connect(username: account.username, password: password)

        // The server's current identity and contents for this mailbox: its
        // UIDVALIDITY and the full set of UIDs it holds right now.
        let state = try await engine.mailboxState(in: mailbox)
        let cachedValidity = try await store.uidValidity(accountID: account.id, mailboxName: mailbox)

        let envelopes = try await engine.fetchRecentEnvelopes(in: mailbox, limit: limit)

        try await store.upsert(account)
        try await store.upsert(Mailbox(accountID: account.id, name: mailbox, role: .inbox))

        // A changed UIDVALIDITY invalidates every cached UID for the mailbox; the
        // cache can't be reconciled, only rebuilt, so drop it before re-saving.
        if let cachedValidity, cachedValidity != Int64(state.uidValidity) {
            try await store.clearMessages(accountID: account.id, mailboxName: mailbox)
        }
        try await store.setUIDValidity(Int64(state.uidValidity), accountID: account.id, mailboxName: mailbox)

        try await store.save(envelopes.map(Message.init), accountID: account.id, mailboxName: mailbox)
        // Drop anything the server no longer has, so deletions made elsewhere
        // take effect locally. The keep-set is the server's full UID list, not
        // just the fetched window, so older mail still on the server survives.
        try await store.pruneMessages(
            accountID: account.id,
            mailboxName: mailbox,
            keepingUIDs: Set(state.uids.map(Int64.init))
        )
        try await store.rethread(accountID: account.id)

        // Backfill each thread's newest message body so the inbox row shows a
        // preview snippet. Only threads whose latest message isn't already cached
        // are fetched, grouped by mailbox over the warm session; a second
        // rethread then recomputes the snippets from the fresh bodies. This also
        // makes the first open of those threads instant, since the body is now
        // cached. Best effort: a fetch failure here leaves the snippet empty
        // rather than failing the whole sync, so the inbox still updates.
        do {
            let needing = try await store.latestMessagesNeedingBodies(accountID: account.id)
            if !needing.isEmpty {
                var bodies: [String: (text: String, hasHTML: Bool, attachments: [MessageAttachment])] = [:]
                for (mailbox, group) in Dictionary(grouping: needing, by: \.mailbox) {
                    let fetched = try await engine.fetchTextBodies(
                        in: mailbox,
                        messages: group.map { (id: $0.id, uid: $0.uid) }
                    )
                    for (id, body) in fetched {
                        bodies[id] = (text: body.text, hasHTML: body.hasHTML, attachments: body.attachments.map(MessageAttachment.init))
                    }
                }
                try await store.storeBodies(bodies)
                try await store.rethread(accountID: account.id)
            }
        } catch {
            // Snippets are a convenience; a failure to backfill them must not
            // sink a sync that already reconciled the inbox.
        }

        return try await store.threadSummaries(accountID: account.id)
    }

    /// Load a full conversation for display, fetching any message bodies that
    /// aren't cached yet and storing them. The first open pulls the text parts
    /// over the warm session (one mailbox select, one pipelined burst); later
    /// opens read straight from the store with no network. Returns nil if the
    /// thread is unknown.
    ///
    /// The password is per call for the same reason as `syncInbox`: it lives in
    /// the Keychain (M4) or the in-memory session, never on this service.
    public func loadConversation(id: String, password: String) async throws -> Thread? {
        let targets = try await store.messagesNeedingBodies(threadID: id)
        if !targets.isEmpty {
            try await engine.connect(username: account.username, password: password)
            var bodies: [String: (text: String, hasHTML: Bool, attachments: [MessageAttachment])] = [:]
            for (mailbox, group) in Dictionary(grouping: targets, by: \.mailbox) {
                let fetched = try await engine.fetchTextBodies(
                    in: mailbox,
                    messages: group.map { (id: $0.id, uid: $0.uid) }
                )
                for (id, body) in fetched {
                    bodies[id] = (text: body.text, hasHTML: body.hasHTML, attachments: body.attachments.map(MessageAttachment.init))
                }
            }
            try await store.storeBodies(bodies)
        }
        return try await store.thread(id: id)
    }

    /// Fetch one message's HTML for the Web View, by message id, with its inline
    /// images resolved to bytes. Resolves the message's server reference from the
    /// store, then pulls the HTML part and any `cid:`-referenced images over the
    /// warm session. Returns nil when the message is unknown, purely local, or
    /// carries no HTML. The password is per call, as elsewhere.
    public func fetchHTMLBody(messageID: String, password: String) async throws -> WebViewBody? {
        guard let ref = try await store.messageRef(id: messageID) else { return nil }
        try await engine.connect(username: account.username, password: password)
        guard let body = try await engine.fetchHTMLBody(in: ref.mailbox, uid: ref.uid) else { return nil }
        return WebViewBody(
            html: body.html,
            inlineImages: body.images.map {
                InlineImage(contentID: $0.contentID, mimeType: $0.mimeType, data: $0.data)
            }
        )
    }

    /// Fetch and decode one attachment's bytes, by message id and MIME part id,
    /// over the warm session, for opening it in a preview. Resolves the message's
    /// server reference from the store, then pulls just that part. Returns nil when
    /// the message is unknown or purely local (no UID, so nothing to fetch); a
    /// missing part or undecodable bytes throw from the engine. The password is per
    /// call, as elsewhere.
    public func fetchAttachment(messageID: String, partID: String, password: String) async throws -> Data? {
        guard let ref = try await store.messageRef(id: messageID) else { return nil }
        try await engine.connect(username: account.username, password: password)
        return try await engine.fetchAttachment(in: ref.mailbox, uid: ref.uid, partID: partID)
    }

    /// Send a composed draft, then make it visible immediately.
    ///
    /// The SMTP send is the gate: if it throws, nothing was delivered and nothing
    /// is stored, so the caller can let the user retry the same draft (its reused
    /// Message-ID keeps a retry from doubling). Once the send succeeds the message
    /// is delivered, so the optimistic local copy is inserted and the thread
    /// recomputed even if the rest fails, and the bubble appears at once.
    ///
    /// Appending a copy to the server's Sent folder is best effort: it only helps
    /// other mail clients see the message, so a failure there is logged and
    /// swallowed rather than reported as a send failure for mail that did send.
    /// The local copy carries the same Message-ID, so when Sent is later synced
    /// the two reconcile to one row.
    public func send(_ draft: OutgoingDraft, password: String) async throws {
        let outgoing = draft.outgoingMessage
        try await sender.send(outgoing, username: account.username, password: password)

        try await store.upsert(Mailbox(accountID: account.id, name: Self.localSentMailbox, role: .sent))
        try await store.save([draft.localMessage], accountID: account.id, mailboxName: Self.localSentMailbox)
        try await store.rethread(accountID: account.id)

        do {
            try await engine.connect(username: account.username, password: password)
            try await engine.saveToSent(outgoing)
        } catch {
            // The mail was sent and is shown locally; a missing server-side Sent
            // copy is a reconciliation detail, not a send failure.
        }
    }

    /// Mark a thread read or unread: set or clear `\Seen` on its messages on the
    /// server (grouped by mailbox), then update the local store and rethread so
    /// the inbox unread state follows. The server update is skipped when the
    /// thread has no server-backed messages (a purely local conversation).
    public func setRead(threadID: String, seen: Bool, password: String) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.setSeen(seen, in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.setSeen(seen, threadID: threadID)
        try await store.rethread(accountID: account.id)
    }

    /// Flag or unflag a thread: set or clear `\Flagged` on its messages on the
    /// server (grouped by mailbox), then update the local store and rethread so
    /// the inbox flagged state follows. The server update is skipped when the
    /// thread has no server-backed messages (a purely local conversation).
    public func setFlagged(threadID: String, flagged: Bool, password: String) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.setFlagged(flagged, in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.setFlagged(flagged, threadID: threadID)
        try await store.rethread(accountID: account.id)
    }

    /// Trash a thread: move its server-backed messages to the server's Trash
    /// (grouped by mailbox), then delete the local copies and rethread so the
    /// conversation leaves the inbox. The server move is the gate for messages
    /// that have it; local-only messages are simply dropped.
    public func trash(threadID: String, password: String) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.trash(in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.deleteThread(threadID: threadID)
        try await store.rethread(accountID: account.id)
    }

    /// Begin watching the inbox for server-side changes, yielding once per change
    /// so the caller can re-sync (IMAP IDLE). Connects first, since the dedicated
    /// IDLE connection reuses the session's authentication. Thin pass-through to
    /// the engine; the password is per call as everywhere else.
    public func watchInbox(password: String, mailbox: String = "INBOX") async throws -> AsyncStream<Void> {
        try await engine.connect(username: account.username, password: password)
        return try await engine.idleChanges(in: mailbox)
    }

    /// Stop watching the inbox and tear down the IDLE connection.
    public func stopWatching() async {
        await engine.stopIdle()
    }

    /// Close the warm session and forget the password. Call on sign-out.
    public func disconnect() async {
        await engine.disconnect()
    }

    /// The mailbox name the optimistic Sent copy is filed under locally. The
    /// server's real Sent folder is resolved by the engine when appending; a
    /// later Sent sync (a future milestone) will reconcile the names by
    /// Message-ID. Until then this is a stable local label, not a server folder.
    private static let localSentMailbox = "Sent"
}
