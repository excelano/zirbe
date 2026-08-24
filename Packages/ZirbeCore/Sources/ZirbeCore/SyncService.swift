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
        try await reconcile(mailbox: mailbox, role: .inbox, password: password, limit: limit)
        // The home view is scoped to INBOX: every conversation with an INBOX
        // message, carrying its whole thread. Scoping keeps junk-only and
        // sent-only threads out of the inbox now that other folders also sync.
        return try await store.threadSummaries(accountID: account.id, mailboxName: mailbox)
    }

    /// Sync one non-inbox folder and return its scoped conversation list: the
    /// threads with a message filed in `mailbox`. Same reconcile as the inbox
    /// (fetch, UIDVALIDITY check, prune, rethread, snippet backfill), differing
    /// only in the role stamped on the folder and in returning a mailbox-scoped
    /// view rather than the whole account. Folders sync lazily, on first visit and
    /// on refresh; INBOX remains the one folder synced on launch and watched.
    @discardableResult
    public func syncFolder(
        mailbox: String,
        role: MailboxRole?,
        password: String,
        limit: Int = 50
    ) async throws -> [ThreadSummary] {
        try await reconcile(mailbox: mailbox, role: role, password: password, limit: limit)
        return try await store.threadSummaries(accountID: account.id, mailboxName: mailbox)
    }

    /// Fetch a folder, reconcile the cache against the server, and recompute
    /// threads. The shared core of `syncInbox` and `syncFolder`; neither returns
    /// from here, since they differ only in which summaries they read back after.
    private func reconcile(mailbox: String, role: MailboxRole?, password: String, limit: Int) async throws {
        try await engine.connect(username: account.username, password: password)

        // The server's current identity and contents for this mailbox: its
        // UIDVALIDITY and the full set of UIDs it holds right now.
        let state = try await engine.mailboxState(in: mailbox)
        let cachedValidity = try await store.uidValidity(accountID: account.id, mailboxName: mailbox)

        let envelopes = try await engine.fetchRecentEnvelopes(in: mailbox, limit: limit)

        try await store.upsert(account)
        try await store.upsert(Mailbox(accountID: account.id, name: mailbox, role: role))

        // A changed UIDVALIDITY invalidates every cached UID for the mailbox; the
        // cache can't be reconciled, only rebuilt, so drop it before re-saving.
        let validityChanged = cachedValidity.map { $0 != Int64(state.uidValidity) } ?? false
        if validityChanged {
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
        // A UIDVALIDITY renumber leaves the new-mail high-water mark pointing at
        // stale UIDs from the old scheme, usually higher than the renumbered ones,
        // so genuinely new INBOX mail would sit below the mark and never notify
        // until the server's counter climbed back past it. Reseed the mark to the
        // rebuilt inbox's top, so the rebuilt inbox isn't announced wholesale and
        // arrivals after the renumber do notify. Only INBOX carries the mark.
        if validityChanged, mailbox == Self.inboxMailbox {
            try await store.markNotificationWatermark(accountID: account.id)
        }
        // Enforce the sender blocklist before rethreading, so a blocked sender's
        // mail is gone from the inbox in the same pass it arrives. INBOX-scoped,
        // and catches both new arrivals just fetched and any backlog left when a
        // sender was newly blocked.
        if mailbox == Self.inboxMailbox {
            try await enforceBlocklist()
        }
        try await store.rethread(accountID: account.id)

        // Backfill each thread's newest message body so the inbox row shows a
        // preview snippet. Only threads whose latest message isn't already cached
        // are fetched, grouped by mailbox over the warm session; each fetched body
        // then moves its own thread's snippet into place. This also makes the first
        // open of those threads instant, since the body is now cached. Best effort:
        // a fetch failure here leaves the snippet empty rather than failing the
        // whole sync, so the inbox still updates.
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
                try await store.refreshThreadSnippets(fromLatestMessages: Array(bodies.keys))
            }
        } catch {
            // Snippets are a convenience; a failure to backfill them must not
            // sink a sync that already reconciled the inbox.
        }
    }

    /// List the server's folders and cache them, so the mailbox switcher has names
    /// and roles to show. Container-only folders (the `\Noselect` parents some
    /// servers use purely for hierarchy) are dropped; they hold no mail to browse.
    /// Roles come from each folder's RFC 6154 special-use attribute, mapped onto
    /// the domain's MailboxRole. Returns the cached set. Pure discovery: it upserts
    /// folder rows but syncs no messages, so visiting a folder still triggers its
    /// own lazy sync.
    @discardableResult
    public func discoverFolders(password: String) async throws -> [Mailbox] {
        try await engine.connect(username: account.username, password: password)
        let mailboxes = try await engine.listMailboxes()
            .filter(\.isSelectable)
            .map { Mailbox(accountID: account.id, name: $0.name, role: MailboxRole($0.specialUse), hierarchyDelimiter: $0.hierarchyDelimiter) }
        for mailbox in mailboxes {
            try await store.upsert(mailbox)
        }
        return mailboxes
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
        try await transmit(draft, password: password)
        try await recordLocal(draft, state: .sent)
        await saveSentCopy(draft, password: password)
    }

    /// The SMTP send on its own: the gate. Throws on any failure, having stored
    /// nothing, so the caller decides whether to record a failed bubble (a reply,
    /// shown in its open thread) or simply surface the error (a new message or
    /// forward, whose composer stays open to retry). A success means the mail was
    /// delivered; the caller then records the local copy and the Sent copy.
    public func transmit(_ draft: OutgoingDraft, password: String) async throws {
        try await sender.send(draft.outgoingMessage, username: account.username, password: password)
    }

    /// File the optimistic local copy of a sent or failed message into the local
    /// Sent mailbox and recompute the thread, so the bubble appears at once. The
    /// `state` is stamped on the copy: `.sent` once delivered, `.failed` when the
    /// transmit threw. Re-recording the same draft (a retry) upserts the one row
    /// by its Message-ID, so a failed bubble flips to sent in place rather than
    /// doubling. Inline-rendered bytes (images, voice memos) are stashed in the
    /// cache, keyed by the copy's display id, so the bubble shows or plays them
    /// before the Sent re-sync supplies a part section to fetch by.
    public func recordLocal(_ draft: OutgoingDraft, state: SendState) async throws {
        var local = draft.localMessage
        local.sendState = state
        try await store.upsert(Mailbox(accountID: account.id, name: Self.localSentMailbox, role: .sent))
        try await store.save([local], accountID: account.id, mailboxName: Self.localSentMailbox)
        try await store.rethread(accountID: account.id)

        // Inline-rendered attachments (images, voice memos) are stashed so the
        // bubble can show or play them before the Sent re-sync supplies a part
        // section to fetch by.
        for attachment in draft.attachments {
            let type = attachment.mimeType.lowercased()
            guard type.hasPrefix("image/") || type.hasPrefix("audio/") else { continue }
            AttachmentCache.save(attachment.data, messageID: local.id, filename: attachment.filename)
        }
    }

    /// Append a copy of a delivered message to the server's Sent folder. Best
    /// effort: it only helps other mail clients see the message, so a failure is
    /// swallowed rather than reported as a send failure for mail that did send.
    /// The same Message-ID as the SMTP send is carried through, so when Sent is
    /// later synced the server copy and the local copy reconcile to one row.
    public func saveSentCopy(_ draft: OutgoingDraft, password: String) async {
        do {
            try await engine.connect(username: account.username, password: password)
            try await engine.saveToSent(draft.outgoingMessage)
        } catch {
            // The mail was sent and is shown locally; a missing server-side Sent
            // copy is a reconciliation detail, not a send failure.
        }
    }

    /// Save a composed draft to the server's Drafts folder and file an optimistic
    /// local copy so it shows in Drafts at once. APPEND is the gate, mirroring how
    /// the SMTP send gates `send`: if it throws, nothing was stored, so the caller
    /// can let the user retry the same draft. On success the local copy is inserted
    /// (or refreshed, when editing) and the thread recomputed.
    ///
    /// Editing is implicit in the Message-ID. A prior copy of this draft is the
    /// local row already keyed by its id; reading that row's UID gives the server
    /// copy to expunge after the new one lands, so an edit replaces rather than
    /// stacks. A nil prior UID (first save, or one never learned because the server
    /// lacks UIDPLUS and Drafts hasn't synced since) skips the expunge, leaving the
    /// old copy to be reconciled on the next Drafts sync. Returns the new server
    /// UID when the server reported one, else nil.
    @discardableResult
    public func saveDraft(_ draft: OutgoingDraft, password: String) async throws -> UInt32? {
        let priorUID = try await store.messageRef(id: draft.localMessage.id)?.uid

        try await engine.connect(username: account.username, password: password)
        let newUID = try await engine.saveToDrafts(draft.outgoingMessage, replacing: priorUID)

        try await store.upsert(Mailbox(accountID: account.id, name: Self.localDraftsMailbox, role: .drafts))
        try await store.save([draft.draftLocalMessage(uid: newUID)], accountID: account.id, mailboxName: Self.localDraftsMailbox)
        try await store.rethread(accountID: account.id)
        return newUID
    }

    /// Delete a draft: expunge its server copy from Drafts and drop the local copy,
    /// then rethread so it leaves the Drafts list. Called when a draft is sent (its
    /// content now lives as a real message) or explicitly discarded. A draft with no
    /// known UID (never synced, no UIDPLUS) is only removed locally, and its server
    /// copy is reconciled away on the next Drafts sync.
    ///
    /// Only the thread's Drafts-filed messages are expunged: `removeDraft` always
    /// targets the Drafts folder, so a UID from another folder would be expunged as
    /// if it were a Drafts UID. A discarded draft is a Drafts-only thread today, so
    /// this filter is a guard against a future thread bridging Drafts with another
    /// folder, not a change in behavior.
    public func deleteDraft(threadID: String, password: String) async throws {
        let draftRefs = try await store.messageRefs(threadID: threadID)
            .filter { $0.mailbox == Self.localDraftsMailbox }
        if !draftRefs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for ref in draftRefs {
                try await engine.removeDraft(uid: ref.uid)
            }
        }
        try await store.deleteThread(threadID: threadID)
        try await store.rethread(accountID: account.id)
    }

    /// Mark a thread read or unread: set or clear `\Seen` on its messages on the
    /// server (grouped by mailbox), then update the local store and rethread so
    /// the inbox unread state follows. The server update is skipped when the
    /// thread has no server-backed messages (a purely local conversation).
    public func setRead(threadID: String, seen: Bool, password: String, rethread: Bool = true) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.setSeen(seen, in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.setSeen(seen, threadID: threadID)
        if rethread { try await store.rethread(accountID: account.id) }
    }

    /// Flag or unflag a thread: set or clear `\Flagged` on its messages on the
    /// server (grouped by mailbox), then update the local store and rethread so
    /// the inbox flagged state follows. The server update is skipped when the
    /// thread has no server-backed messages (a purely local conversation).
    public func setFlagged(threadID: String, flagged: Bool, password: String, rethread: Bool = true) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.setFlagged(flagged, in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.setFlagged(flagged, threadID: threadID)
        if rethread { try await store.rethread(accountID: account.id) }
    }

    /// Trash a thread: move its server-backed messages to the server's Trash
    /// (grouped by mailbox), then delete the local copies and rethread so the
    /// conversation leaves the inbox. The server move is the gate for messages
    /// that have it; local-only messages are simply dropped.
    public func trash(threadID: String, password: String, rethread: Bool = true) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.trash(in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.deleteThread(threadID: threadID)
        if rethread { try await store.rethread(accountID: account.id) }
    }

    /// Move a thread's server-backed messages to `destination` (grouped by their
    /// current mailbox), then drop the local copies and rethread so the
    /// conversation leaves the current folder. The server move is the gate for
    /// messages that have a UID; local-only messages are simply dropped. The
    /// destination folder shows them on its next sync (a moved message gets a new
    /// UID there, so it is re-fetched rather than carried over with a stale one).
    public func move(threadID: String, to destination: String, password: String, rethread: Bool = true) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.move(in: mailbox, uids: group.map(\.uid), to: destination)
            }
        }
        try await store.deleteThread(threadID: threadID)
        if rethread { try await store.rethread(accountID: account.id) }
    }

    /// Archive a thread: move its server-backed messages to the server's Archive
    /// folder (resolved by the engine), preserving their read state, then drop the
    /// local copies and rethread. Same shape as `move`, with the destination the
    /// engine's archive folder rather than a caller-named one.
    public func archive(threadID: String, password: String, rethread: Bool = true) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.archive(in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.deleteThread(threadID: threadID)
        if rethread { try await store.rethread(accountID: account.id) }
    }

    /// Mark a thread as junk: move its server-backed messages to the server's Junk
    /// folder (resolved by the engine, with a name fallback), then drop the local
    /// copies and rethread. Same shape as `archive`.
    public func junk(threadID: String, password: String, rethread: Bool = true) async throws {
        let refs = try await store.messageRefs(threadID: threadID)
        if !refs.isEmpty {
            try await engine.connect(username: account.username, password: password)
            for (mailbox, group) in Dictionary(grouping: refs, by: \.mailbox) {
                try await engine.markJunk(in: mailbox, uids: group.map(\.uid))
            }
        }
        try await store.deleteThread(threadID: threadID)
        if rethread { try await store.rethread(accountID: account.id) }
    }

    /// Recompute threads for the account once. Bulk callers pass `rethread: false`
    /// to the per-thread mutations above and call this a single time after the
    /// loop, so K selected conversations cost one rethread rather than K.
    public func rethread() async throws {
        try await store.rethread(accountID: account.id)
    }

    /// Move any INBOX mail from a blocked sender to the server's Junk folder and
    /// drop the local copies, so a blocked sender's mail never surfaces in the
    /// inbox. Reuses the same server move as `junk`. The engine is already
    /// connected by the surrounding reconcile; the caller rethreads after.
    private func enforceBlocklist() async throws {
        let refs = try await store.blockedInboxRefs(accountID: account.id)
        guard !refs.isEmpty else { return }
        try await engine.markJunk(in: Self.inboxMailbox, uids: refs.map(\.uid))
        try await store.deleteMessages(ids: refs.map(\.id))
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

    /// The privileged folder synced on launch, watched over IDLE, and polled in
    /// the background; the only folder the notification high-water mark tracks.
    /// Matches `MailStore`'s own INBOX scope for that mark.
    private static let inboxMailbox = "INBOX"

    /// The mailbox name the optimistic Sent copy is filed under locally. The
    /// server's real Sent folder is resolved by the engine when appending; a
    /// later Sent sync (a future milestone) will reconcile the names by
    /// Message-ID. Until then this is a stable local label, not a server folder.
    private static let localSentMailbox = "Sent"

    /// The mailbox name the optimistic local Draft copy is filed under, mirroring
    /// `localSentMailbox`. The server's real Drafts folder is resolved by the
    /// engine on APPEND; a later Drafts sync reconciles the names by Message-ID.
    private static let localDraftsMailbox = "Drafts"
}

/// Map the transport layer's special-use enum onto the domain's MailboxRole. The
/// two intentionally mirror each other (ZirbeMail can't see ZirbeCore's type, so
/// it carries its own); this is the one place that bridges them, in ZirbeCore,
/// which is allowed to depend on ZirbeMail.
extension MailboxRole {
    init?(_ specialUse: MailboxSpecialUse?) {
        switch specialUse {
        case .inbox: self = .inbox
        case .sent: self = .sent
        case .drafts: self = .drafts
        case .trash: self = .trash
        case .archive: self = .archive
        case .junk: self = .junk
        case nil: return nil
        }
    }
}
