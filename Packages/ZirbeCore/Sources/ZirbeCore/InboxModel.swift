// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The observable state the conversation UI binds to. It wraps the offline store
// and the sync service: the store is the source of truth the list reads, and
// the service fills it from the server. Per the architecture, the view model
// lives here in ZirbeCore (not the app target) so it is testable without a UI.

import Foundation
import Observation
import ZirbeMail

/// Drives the read-only conversation UI for one account. Holds the inbox
/// summaries the list shows and loads full conversations on demand.
///
/// The session password lives here in memory only, for the life of the run, and
/// is never written to disk. This is the M2c stopgap; M4 moves credentials to
/// the Keychain and adds real onboarding. Nothing about this view model
/// persists a secret.
@MainActor
@Observable
public final class InboxModel {
    /// The current folder's rows, most recent activity first. Read-only to the UI.
    public private(set) var summaries: [ThreadSummary] = []
    /// True while a sync is in flight, for a list-level progress view.
    public private(set) var isSyncing = false
    /// The last error, if any, in a form a view can show directly.
    public private(set) var errorMessage: String?

    /// The account's folders, for the mailbox switcher. Populated from the cache
    /// and refreshed from the server when the switcher opens.
    public private(set) var mailboxes: [Mailbox] = []
    /// Per-folder unread badge counts, keyed by mailbox name, from the local
    /// cache; a folder not yet visited has no entry. See `MailStore.unreadCounts`.
    public private(set) var unreadCounts: [String: Int] = [:]
    /// The folder currently on screen. INBOX is home and the default; selecting
    /// another swaps the list to that folder's scoped view.
    public private(set) var currentMailbox: Mailbox

    public let account: Account
    private let store: MailStore
    private let sync: SyncService
    /// The app-specific password for this session, in memory only. Cleared on
    /// sign-out; replaced by the Keychain in M4.
    private var password: String?

    public init(account: Account, store: MailStore) {
        self.account = account
        self.store = store
        self.sync = SyncService(account: account, store: store)
        self.currentMailbox = Mailbox(accountID: account.id, name: "INBOX", role: .inbox)
    }

    /// Whether a password is held, so refresh and conversation loads can run.
    public var isConnected: Bool { password != nil }

    /// Whether the home (INBOX) view is on screen. The home view is the unscoped
    /// "all conversations" list; every other folder is a scoped view. INBOX stays
    /// the privileged folder synced on launch, watched over IDLE, and polled in
    /// the background regardless of which folder is showing.
    public var isViewingInbox: Bool {
        currentMailbox.role == .inbox || currentMailbox.name == "INBOX"
    }

    /// Show whatever is already in the store, with no network. Safe on launch to
    /// display cached mail immediately.
    public func loadCached() async {
        await attempt {
            try await self.reloadList()
        }
    }

    /// The current folder's conversation list: every conversation with a message
    /// filed in the folder showing, carrying its whole thread. Scoping the home
    /// view to INBOX (rather than the whole store) keeps junk-only and sent-only
    /// conversations out of the inbox while still surfacing a thread the moment it
    /// has any INBOX message, the Messages-style behavior we want.
    private func currentSummaries() async throws -> [ThreadSummary] {
        try await store.threadSummaries(accountID: account.id, mailboxName: currentMailbox.name)
    }

    /// Re-read the visible list and the folder badge counts from the store. Called
    /// after any sync or mutation, so the list and the switcher's badges stay in
    /// step with the cache without each call path repeating the two reads.
    private func reloadList() async throws {
        summaries = try await currentSummaries()
        unreadCounts = try await store.unreadCounts(accountID: account.id)
    }

    /// Connect with an app-specific password, then sync the inbox. Throws if the
    /// sync fails (e.g. a wrong password), clearing the held password so the
    /// caller can keep the user on the connect screen. The password is retained
    /// only on success, for later refreshes and body loads.
    public func signIn(password: String) async throws {
        self.password = password
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await performSync(password: password)
        } catch {
            self.password = nil
            throw error
        }
    }

    /// Re-sync the inbox using the held password. Errors surface in
    /// `errorMessage` rather than throwing, for pull-to-refresh.
    public func refresh() async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        isSyncing = true
        await attempt {
            try await self.performSync(password: password)
        }
        isSyncing = false
    }

    private func performSync(password: String) async throws {
        if isViewingInbox {
            try await sync.syncInbox(password: password)
        } else {
            try await sync.syncFolder(mailbox: currentMailbox.name, role: currentMailbox.role, password: password)
        }
        try await reloadList()
    }

    /// Load the cached folder list immediately (no network), for opening the
    /// mailbox switcher. Pair with `discoverFolders()` to refresh it from the
    /// server in the background.
    public func loadMailboxes() async {
        await attempt {
            self.mailboxes = try await self.store.mailboxes(accountID: self.account.id)
            self.unreadCounts = try await self.store.unreadCounts(accountID: self.account.id)
        }
    }

    /// Refresh the folder list from the server (LIST), caching the result.
    /// Best-effort: a failure leaves the cached list in place rather than
    /// surfacing, since the switcher still works from the cache. A no-op when not
    /// connected.
    public func discoverFolders() async {
        guard let password else { return }
        do {
            mailboxes = try await sync.discoverFolders(password: password)
        } catch {
            // The switcher falls back to whatever folders are already cached.
        }
    }

    /// Switch the visible list to `mailbox`, syncing it if it's not the home view.
    /// INBOX is home and reads its cached "all conversations" list immediately
    /// (it's already synced and watched); any other folder syncs lazily on this
    /// first switch, then serves from the cache on later visits.
    public func selectMailbox(_ mailbox: Mailbox) async {
        currentMailbox = mailbox
        guard let password else {
            await attempt { try await self.reloadList() }
            return
        }
        isSyncing = true
        await attempt {
            if self.isViewingInbox {
                try await self.reloadList()
            } else {
                try await self.performSync(password: password)
            }
        }
        isSyncing = false
    }

    /// The live-refresh monitor, running while the inbox is foreground and on
    /// screen. Holds an IMAP IDLE watch that ticks on each server-side change and
    /// re-syncs in response. nil when live refresh is off.
    private var monitorTask: Task<Void, Never>?

    /// Whether a live-refresh watch is currently running.
    public var isLiveRefreshing: Bool { monitorTask != nil }

    /// Start watching the inbox for new mail while it's on screen, re-syncing on
    /// each server-side change (IMAP IDLE). Idempotent, and a no-op when not
    /// connected. Pair with `stopLiveRefresh()` when the app leaves the
    /// foreground. There is no instant push — the watch needs a foreground
    /// connection — so updates pause when the app is backgrounded and resume on
    /// return. A failed or dropped watch is non-fatal: the inbox still updates on
    /// pull-to-refresh and on the next foreground, so nothing surfaces as an error.
    public func startLiveRefresh() {
        guard let password, monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let changes = try await self.sync.watchInbox(password: password)
                for await _ in changes {
                    if Task.isCancelled { break }
                    await self.refresh()
                }
            } catch {
                // Live refresh is a bonus on top of pull and foreground sync; a
                // watch that won't start or dies is silently left off.
            }
        }
    }

    /// Stop the live-refresh watch and tear down its IDLE connection.
    public func stopLiveRefresh() async {
        monitorTask?.cancel()
        monitorTask = nil
        await sync.stopWatching()
    }

    /// Search the synced conversations for `query`, returning the matching thread
    /// summaries most-recent-first. Local-only over the store, so it needs no
    /// password, is instant, and works offline; it covers only mail already
    /// downloaded. An empty query returns nothing. Any error surfaces in
    /// `errorMessage` and yields an empty result.
    public func search(_ query: String) async -> [ThreadSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try await store.searchThreads(accountID: account.id, query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Load a full conversation for display, fetching message bodies on first
    /// open and caching them. Returns nil if not connected or the thread is
    /// unknown. The conversation view owns its own loading indicator, so this
    /// does not touch `isSyncing`.
    public func conversation(id: String) async -> Thread? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        do {
            return try await sync.loadConversation(id: id, password: password)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Send a reply into `thread`. Recipients default to reply-all derived from
    /// the latest message, less any addresses the user removed (the group-chat
    /// "remove someone" gesture). Returns the refreshed conversation with the
    /// sent bubble in place, or nil if a guardrail fails or the send errors, with
    /// the reason in `errorMessage`. The user's text gets the quote trailer
    /// appended; the body passed here is just what they typed.
    @discardableResult
    public func sendReply(to thread: Thread, removing removedAddresses: Set<String> = [], body: String, attachments: [DraftAttachment] = []) async -> Thread? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            errorMessage = "Write a message or attach a file before sending."
            return nil
        }

        var (to, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: account)
        let removed = Set(removedAddresses.map { $0.lowercased() })
        to = to.filter { !removed.contains($0.address) }
        cc = cc.filter { !removed.contains($0.address) }
        guard !to.isEmpty || !cc.isEmpty else {
            errorMessage = "A reply needs at least one recipient."
            return nil
        }

        let draft = OutgoingDraft.reply(to: thread, as: account, to: to, cc: cc, body: trimmed, attachments: attachments.map(\.outgoing), sentAt: Date())
        do {
            try await sync.send(draft, password: password)
            return try await store.thread(id: thread.id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Start a new conversation. The subject is required (a status panel reads by
    /// subject, so an empty one is rejected), as are a body and at least one
    /// recipient. Returns whether it sent; on success the inbox summaries refresh
    /// to include the new conversation. On failure the reason is in
    /// `errorMessage`.
    @discardableResult
    public func sendNew(
        to recipients: [Participant],
        cc: [Participant] = [],
        subject: String,
        body: String,
        attachments: [DraftAttachment] = [],
        discardingDraft discarding: DraftContext? = nil
    ) async -> Bool {
        guard let password else {
            errorMessage = "Connect an account first."
            return false
        }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else {
            errorMessage = "A new conversation needs a subject."
            return false
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty || !attachments.isEmpty else {
            errorMessage = "Write a message or attach a file before sending."
            return false
        }
        guard !recipients.isEmpty || !cc.isEmpty else {
            errorMessage = "Add at least one recipient."
            return false
        }

        let draft = OutgoingDraft.new(from: account, to: recipients, cc: cc, subject: trimmedSubject, body: trimmedBody, attachments: attachments.map(\.outgoing), sentAt: Date())
        do {
            try await sync.send(draft, password: password)
            if let discarding {
                // The message is sent, so its draft has served its purpose.
                // Best-effort: a failed expunge leaves a stale draft to reconcile,
                // not a failed send, so it must not turn a sent message into an
                // error. The single reloadList below reflects both changes.
                try? await sync.deleteDraft(threadID: discarding.threadID, password: password)
            }
            try await reloadList()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Save the composer's current contents as a draft in the server's Drafts
    /// folder, filing an optimistic local copy so it appears in Drafts at once.
    /// Editing an existing draft (pass its `DraftContext`) reuses the same
    /// Message-ID, so the save replaces the prior server copy rather than stacking
    /// a second; a brand-new draft generates a fresh id. Returns the draft's
    /// context for a later edit, send-delete, or discard, or nil if not connected
    /// or the save failed (reason in `errorMessage`).
    ///
    /// Unlike `sendNew`, a draft has no content guardrails: a half-written message
    /// with an empty subject, body, or recipient list still saves. The caller
    /// decides when a composer is worth saving.
    @discardableResult
    public func saveDraft(
        to recipients: [Participant],
        cc: [Participant] = [],
        subject: String,
        body: String,
        attachments: [DraftAttachment] = [],
        editing existing: DraftContext? = nil
    ) async -> DraftContext? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        let messageID = existing?.messageID ?? ReplyBuilder.generateMessageID(for: account)
        let draft = OutgoingDraft.draft(
            from: account,
            to: recipients,
            cc: cc,
            subject: subject,
            body: body,
            attachments: attachments.map(\.outgoing),
            messageID: messageID,
            savedAt: Date()
        )
        do {
            try await sync.saveDraft(draft, password: password)
            try await reloadList()
            return DraftContext(messageID: messageID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Delete a draft: expunge its server copy from Drafts and drop its local copy,
    /// refreshing the list. Called when a draft is explicitly discarded; a sent
    /// draft is removed by `sendNew` itself. Errors surface in `errorMessage`.
    public func deleteDraft(_ context: DraftContext) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            try await self.sync.deleteDraft(threadID: context.threadID, password: password)
            try await self.reloadList()
        }
    }

    /// Load a saved draft for editing, returning its composer-ready fields and a
    /// context to re-save or delete it. Fetches the body and re-fetches each
    /// attachment's bytes over the warm session (mirroring `loadConversation` and
    /// the forward path) so editing and re-saving preserves the files. Returns nil
    /// if not connected, the draft is unknown, or it carries no Message-ID, with
    /// any error in `errorMessage`.
    public func loadDraft(threadID: String) async -> DraftEdit? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        do {
            guard let thread = try await sync.loadConversation(id: threadID, password: password),
                  let message = thread.messages.first,
                  let messageID = message.messageID, !messageID.isEmpty
            else { return nil }

            // Re-fetch each attachment's bytes so a re-save carries the files, not
            // just their names. A chip with no server part section yet (an
            // optimistic copy not synced) is skipped; the resume flow taps a synced
            // Drafts thread, so the parts are present.
            var attachments: [DraftAttachment] = []
            for attachment in message.attachments where !attachment.partID.isEmpty {
                if let data = try await sync.fetchAttachment(
                    messageID: message.id, partID: attachment.partID, password: password
                ) {
                    attachments.append(DraftAttachment(
                        filename: attachment.filename, mimeType: attachment.mimeType, data: data
                    ))
                }
            }
            return DraftEdit(
                context: DraftContext(messageID: messageID),
                to: message.to,
                cc: message.cc,
                subject: message.subject ?? "",
                body: message.bodyText ?? "",
                attachments: attachments
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Mark one or more conversations read or unread, reflecting each on the
    /// server and then refreshing the inbox rows once. The server updates loop
    /// over the warm session; the single store re-read at the end reflects them
    /// all at once. Errors surface in `errorMessage`.
    public func markRead(threadIDs: [String], read: Bool) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            for id in threadIDs {
                try await self.sync.setRead(threadID: id, seen: read, password: password)
            }
            try await self.reloadList()
        }
    }

    /// Mark a single conversation read or unread.
    public func markRead(threadID: String, read: Bool) async {
        await markRead(threadIDs: [threadID], read: read)
    }

    /// Mark a conversation read once it has been opened, but only when it is
    /// currently unread, so opening clears the inbox dot without a needless
    /// server round trip on already-read mail.
    public func markReadOnOpen(_ thread: Thread) async {
        guard thread.isUnread else { return }
        await markRead(threadID: thread.id, read: true)
    }

    /// Flag or unflag one or more conversations, reflecting each on the server
    /// and then refreshing the inbox rows once, mirroring `markRead`. Errors
    /// surface in `errorMessage`.
    public func markFlagged(threadIDs: [String], flagged: Bool) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            for id in threadIDs {
                try await self.sync.setFlagged(threadID: id, flagged: flagged, password: password)
            }
            try await self.reloadList()
        }
    }

    /// Flag or unflag a single conversation.
    public func markFlagged(threadID: String, flagged: Bool) async {
        await markFlagged(threadIDs: [threadID], flagged: flagged)
    }

    /// Fetch one message's HTML for the Web View, with its inline images, on
    /// demand when the user taps it. Returns nil if not connected, the message is
    /// unknown, or it has no HTML, with any error in `errorMessage`. The body is
    /// not cached; it is pulled fresh each open, since it is only needed while the
    /// reader is looking at it.
    public func htmlBody(for messageID: String) async -> WebViewBody? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        do {
            return try await sync.fetchHTMLBody(messageID: messageID, password: password)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Fetch one attachment's decoded bytes, by message id and MIME part id, on
    /// demand when the user taps its chip. Returns nil if not connected, the
    /// message is unknown or purely local, or the fetch fails, with any error in
    /// `errorMessage`. The bytes are not cached; they're pulled fresh each open and
    /// the caller writes them to a temp file for the preview.
    public func attachmentData(messageID: String, partID: String) async -> Data? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        do {
            return try await sync.fetchAttachment(messageID: messageID, partID: partID, password: password)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The bytes of an image attachment for an inline thumbnail: the cache first
    /// (instant for a just-sent image, or one viewed before), then a fetch by part
    /// section, caching the result so the next open is instant too. The disk read
    /// runs off the main actor. Returns nil for a purely local attachment that was
    /// never cached, or on a failed fetch; no error is surfaced, since a thumbnail
    /// that can't load falls back to a chip rather than interrupting the reader.
    public func imageData(messageID: String, attachment: MessageAttachment) async -> Data? {
        let filename = attachment.filename
        if let cached = await Task.detached(priority: .userInitiated, operation: {
            AttachmentCache.data(messageID: messageID, filename: filename)
        }).value {
            return cached
        }
        guard !attachment.partID.isEmpty, let password else { return nil }
        let data = try? await sync.fetchAttachment(messageID: messageID, partID: attachment.partID, password: password)
        if let data {
            AttachmentCache.save(data, messageID: messageID, filename: filename)
        }
        return data
    }

    /// Forward one message to fresh recipients. Refetches each of the message's
    /// attachments into bytes over the warm session so the forward carries the
    /// files (not just their names), then sends a new conversation under a `Fwd:`
    /// subject with the user's optional note above the forwarded block. Returns
    /// whether it sent; on success the inbox refreshes to show the new
    /// conversation. The reason for any failure is in `errorMessage`.
    ///
    /// An attachment whose bytes can't be refetched is dropped from the forward
    /// rather than failing the whole send; the note and the other files still go.
    @discardableResult
    public func sendForward(
        _ message: Message,
        in thread: Thread,
        to recipients: [Participant],
        cc: [Participant],
        note: String
    ) async -> Bool {
        guard let password else {
            errorMessage = "Connect an account first."
            return false
        }
        guard !recipients.isEmpty || !cc.isEmpty else {
            errorMessage = "Add at least one recipient."
            return false
        }
        do {
            var files: [OutgoingAttachment] = []
            for attachment in message.attachments where !attachment.partID.isEmpty {
                guard let data = try await sync.fetchAttachment(
                    messageID: message.id, partID: attachment.partID, password: password
                ) else { continue }
                files.append(OutgoingAttachment(
                    filename: attachment.filename, mimeType: attachment.mimeType, data: data
                ))
            }
            let draft = OutgoingDraft.forward(
                message: message,
                subject: ReplyBuilder.forwardSubject(for: thread),
                as: account,
                to: recipients,
                cc: cc,
                note: note,
                attachments: files,
                sentAt: Date()
            )
            try await sync.send(draft, password: password)
            try await reloadList()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Trash one or more conversations: move each to the server's Trash and drop
    /// it from the inbox, refreshing the rows once at the end. Server-first, so a
    /// failed move leaves that conversation in place with the reason in
    /// `errorMessage`.
    public func trash(threadIDs: [String]) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            for id in threadIDs {
                try await self.sync.trash(threadID: id, password: password)
            }
            try await self.reloadList()
        }
    }

    /// Trash a single conversation.
    public func trash(_ summary: ThreadSummary) async {
        await trash(threadIDs: [summary.id])
    }

    /// Archive one or more conversations: move each to the server's Archive,
    /// preserving its read state, and drop it from the current list, refreshing the
    /// rows once at the end. Server-first, mirroring `trash`: a failed move leaves
    /// that conversation in place with the reason in `errorMessage`.
    public func archive(threadIDs: [String]) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            for id in threadIDs {
                try await self.sync.archive(threadID: id, password: password)
            }
            try await self.reloadList()
        }
    }

    /// Archive a single conversation.
    public func archive(_ summary: ThreadSummary) async {
        await archive(threadIDs: [summary.id])
    }

    /// Mark one or more conversations as junk: move each to the server's Junk
    /// folder and drop it from the current list, refreshing once at the end.
    /// Server-first, mirroring `trash`.
    public func junk(threadIDs: [String]) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            for id in threadIDs {
                try await self.sync.junk(threadID: id, password: password)
            }
            try await self.reloadList()
        }
    }

    /// Mark a single conversation as junk.
    public func junk(_ summary: ThreadSummary) async {
        await junk(threadIDs: [summary.id])
    }

    /// Move one or more conversations to `destination` (a folder name) and drop
    /// each from the current list, refreshing once at the end. Server-first,
    /// mirroring `trash`.
    public func move(threadIDs: [String], to destination: String) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await attempt {
            for id in threadIDs {
                try await self.sync.move(threadID: id, to: destination, password: password)
            }
            try await self.reloadList()
        }
    }

    /// Move a single conversation to `destination`.
    public func move(_ summary: ThreadSummary, to destination: String) async {
        await move(threadIDs: [summary.id], to: destination)
    }

    /// Forget the session password, stop any live-refresh watch, close the warm
    /// connection, and clear in-memory state.
    public func signOut() {
        monitorTask?.cancel()
        monitorTask = nil
        password = nil
        summaries = []
        mailboxes = []
        unreadCounts = [:]
        currentMailbox = Mailbox(accountID: account.id, name: "INBOX", role: .inbox)
        errorMessage = nil
        Task { await sync.disconnect() }
    }

    /// Run a throwing async body, routing any error into `errorMessage` so the
    /// read paths don't each repeat the do/catch.
    private func attempt(_ body: @escaping () async throws -> Void) async {
        errorMessage = nil
        do {
            try await body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
