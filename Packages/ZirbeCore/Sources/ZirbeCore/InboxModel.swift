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
    /// The blocked sender addresses, for the management list in Settings.
    /// Normalized and sorted; loaded on demand and updated on block/unblock.
    public private(set) var blockedSenders: [String] = []

    public let account: Account
    private let store: MailStore
    private let sync: SyncService
    /// The app-specific password for this session, in memory only. Cleared on
    /// sign-out; replaced by the Keychain in M4.
    private var password: String?

    /// Replies whose SMTP send failed, kept so the user can retry them verbatim —
    /// same recipients, body, attachments, and Message-ID — by tapping the failed
    /// bubble. Keyed by that Message-ID. An entry is added when a send fails and
    /// dropped once it finally goes through. Held in memory only: a retry is a
    /// same-session action, so a failed bubble left by a relaunch shows "Not
    /// Delivered" without a retry, and the user composes again.
    private var pendingReplies: [String: OutgoingDraft] = [:]

    /// Whether a gated operation — a sync or a mutation — currently holds the
    /// gate, and the operations queued behind it. Both are `@MainActor`-isolated
    /// along with the rest of this class, so they need no further synchronization.
    private var inOperation = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set when a live-refresh tick arrives while an operation holds the gate, so
    /// the tick can be dropped now and made up once with a single catch-up sync.
    private var missedLiveTick = false

    /// Run `body` with no other gated operation in flight, waiting for one that is.
    ///
    /// Syncing and mutating must never interleave. Both are async and both run on
    /// the MainActor, so without this gate they suspend into each other: a sync
    /// reads the server's message list, a trash running in the gap deletes those
    /// rows locally, and then the sync writes its now-stale snapshot back —
    /// resurrecting the conversation until some later sync prunes it again. That
    /// is the "deleted mail flashes back" behavior, and it is worst on a bulk
    /// delete because the loop leaves a much wider gap for a sync to land in.
    /// Serializing whole operations removes the gap.
    ///
    /// A waiter re-checks the flag on resume rather than assuming the gate is its
    /// own, so a barging caller can't hand two operations the gate at once.
    private func exclusively<T>(_ body: () async throws -> T) async rethrows -> T {
        while inOperation {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
        inOperation = true
        defer {
            inOperation = false
            if !operationWaiters.isEmpty { operationWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Run the one catch-up sync owed to live-refresh ticks that were dropped
    /// while an operation held the gate. Called after a gated mutation, outside the
    /// gate. A no-op when no tick was missed or the watch isn't running.
    private func drainMissedLiveTick() {
        guard missedLiveTick, monitorTask != nil else { return }
        missedLiveTick = false
        Task { await self.refresh() }
    }

    /// The production wiring: a sync service over the account's real servers.
    public convenience init(account: Account, store: MailStore) {
        self.init(account: account, store: store, sync: SyncService(account: account, store: store))
    }

    /// The seam: a sync service the caller built, so tests can hand in one wired
    /// to fake transports.
    public init(account: Account, store: MailStore, sync: SyncService) {
        self.account = account
        self.store = store
        self.sync = sync
        self.currentMailbox = Mailbox(accountID: account.id, name: "INBOX", role: .inbox)
    }

    /// Whether a password is held, so refresh and conversation loads can run.
    public var isConnected: Bool { password != nil }

    /// True in demo/screenshot mode, where the store is pre-seeded and every
    /// network path is short-circuited. Always false in release. See `DemoMode`.
    public private(set) var isDemo = false

    #if DEBUG
    /// Enter demo/screenshot mode: mark the session connected against an already
    /// seeded in-memory store, with no password prompt and no network. `isConnected`
    /// then reads true so the UI shows the inbox; every sync path checks `isDemo`
    /// and no-ops. Compiled out of release builds.
    public func enterDemoMode() {
        isDemo = true
        password = "demo"
    }
    #endif

    /// Whether the home (INBOX) view is on screen. The home view is the unscoped
    /// "all conversations" list; every other folder is a scoped view. INBOX stays
    /// the privileged folder synced on launch, watched over IDLE, and polled in
    /// the background regardless of which folder is showing.
    public var isViewingInbox: Bool {
        currentMailbox.role == .inbox || currentMailbox.name == "INBOX"
    }

    /// Whether the folder on screen is the one a `role` names. Trash, archive, and
    /// junk each drop a conversation out of the list they were run from — except
    /// when that list is the destination, where the conversation stays put. The
    /// optimistic row removal asks this so it never guesses wrong and produces the
    /// very flash it exists to prevent.
    private func isViewing(_ role: MailboxRole) -> Bool {
        currentMailbox.role == role
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
        // Demo mode reads from the pre-seeded store only; never touch the network.
        if isDemo { try await reloadList(); return }
        // Gated: a sync writes back the message list it read at the top, so it must
        // not straddle a mutation that deletes rows in between. See `exclusively`.
        try await exclusively {
            if isViewingInbox {
                try await sync.syncInbox(password: password)
            } else {
                try await sync.syncFolder(mailbox: currentMailbox.name, role: currentMailbox.role, password: password)
            }
            try await reloadList()
        }
        // The user is present for a foreground sync (a refresh, or the IDLE watch
        // firing), so anything now in the inbox counts as already seen: advance the
        // notification mark past it, leaving the background poll to notify only for
        // mail that lands while the app is away. Also seeds the mark on the first
        // sync after connecting, so a returning inbox isn't announced wholesale.
        try await store.markNotificationWatermark(accountID: account.id)
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
        guard !isDemo, let password, monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let changes = try await self.sync.watchInbox(password: password)
                for await _ in changes {
                    if Task.isCancelled { break }
                    // Our own trash, archive, junk, and move expunge mail from the
                    // inbox, and the server reports that back down this watch, so a
                    // mutation ticks it once per conversation it touches. Syncing on
                    // each of those re-reads the whole window to learn what the
                    // mutation already knows. Drop the tick while an operation is in
                    // flight and make it up with a single catch-up sync afterwards,
                    // so genuinely new mail that landed mid-mutation still surfaces.
                    if self.inOperation { self.missedLiveTick = true; continue }
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
    /// "remove someone" gesture). The user's text gets the quote trailer appended;
    /// the body passed here is just what they typed.
    ///
    /// Returns nil only when a guardrail rejects the send (no text, no recipient),
    /// leaving the composer's text untouched and the reason in `errorMessage`.
    /// Once the message is built it always returns the refreshed conversation: the
    /// sent bubble on success, or an undelivered bubble the user can retry when the
    /// SMTP send failed.
    @discardableResult
    public func sendReply(to thread: Thread, removing removedAddresses: Set<String> = [], body: String, attachments: [DraftAttachment] = [], replyingToMessageID: String? = nil) async -> Thread? {
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

        // A swipe-to-reply names an earlier message to answer; quote and thread
        // onto it rather than the conversation's latest.
        let target = replyingToMessageID.flatMap { id in
            thread.messages.first { $0.messageID == id }
        }
        let draft = OutgoingDraft.reply(to: thread, as: account, to: to, cc: cc, body: trimmed, attachments: attachments.map(\.outgoing), replyingTo: target, sentAt: Date())
        return await deliverReply(draft, into: thread.id, password: password)
    }

    /// Whether a failed bubble can be retried in place, i.e. its draft is still
    /// held from this session. A bubble left undelivered by a relaunch has no held
    /// draft, so it shows "Not Delivered" without a retry.
    public func canRetry(messageID: String) -> Bool {
        pendingReplies[messageID] != nil
    }

    /// Retry a reply that failed to send, resending the held draft verbatim. The
    /// reused Message-ID keeps the retry from doubling: a success flips the failed
    /// bubble to sent in place. Returns the refreshed conversation, or nil if not
    /// connected or the draft is no longer held (a relaunch cleared it).
    @discardableResult
    public func retrySend(messageID: String, in threadID: String) async -> Thread? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        guard let draft = pendingReplies[messageID] else { return nil }
        return await deliverReply(draft, into: threadID, password: password)
    }

    /// Transmit a built reply and record the outcome as a bubble in its thread. On
    /// a successful SMTP send the bubble is filed as sent and a server Sent copy is
    /// attempted; on failure it is filed as an undelivered bubble and the draft is
    /// held for retry. Either way the refreshed conversation is returned for the
    /// view to show.
    private func deliverReply(_ draft: OutgoingDraft, into threadID: String, password: String) async -> Thread? {
        do {
            try await sync.transmit(draft, password: password)
        } catch {
            // The undelivered bubble is the indicator, so the shared errorMessage
            // is left untouched: setting it here would also surface in the next
            // compose or forward sheet, which reads the same property.
            pendingReplies[draft.messageID] = draft
            try? await sync.recordLocal(draft, state: .failed)
            return try? await store.thread(id: threadID)
        }
        try? await sync.recordLocal(draft, state: .sent)
        pendingReplies[draft.messageID] = nil
        errorMessage = nil
        await sync.saveSentCopy(draft, password: password)
        return try? await store.thread(id: threadID)
    }

    /// Send a reaction (tapback) to a message in `thread`. The emoji rides out as
    /// an `X-Zirbe-Reaction` header (a receiving Zirbe shows a badge; any other
    /// client sees a short readable line), threaded onto the reacted-to message so
    /// the badge lands on the right bubble. Unlike a reply there is no failed
    /// bubble to retry: the SMTP send is the gate, and a failure surfaces in
    /// `errorMessage` having changed nothing. On success the reaction is filed as a
    /// local copy and the refreshed conversation is returned, the reaction now
    /// among its messages (rendered as a badge, not a bubble). Returns nil when not
    /// connected or the target carries no Message-ID to thread onto.
    ///
    /// The composer's undo window lives in the view: this is called only once the
    /// user has let the reaction stand, so by the time it runs the send is final.
    @discardableResult
    public func sendReaction(_ emoji: String, to targetMessageID: String, in thread: Thread) async -> Thread? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        guard let target = thread.messages.first(where: { $0.messageID == targetMessageID }) else { return nil }
        let draft = OutgoingDraft.reaction(to: target, in: thread, as: account, emoji: emoji)
        do {
            try await sync.transmit(draft, password: password)
        } catch {
            errorMessage = "Couldn't send your reaction. Try again."
            return try? await store.thread(id: thread.id)
        }
        try? await sync.recordLocal(draft, state: .sent)
        await sync.saveSentCopy(draft, password: password)
        return try? await store.thread(id: thread.id)
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
        bcc: [Participant] = [],
        subject: String,
        body: String,
        attachments: [DraftAttachment] = [],
        discardingDraft discarding: DraftContext? = nil
    ) async -> Bool {
        guard let password else {
            errorMessage = "Connect an account first."
            return false
        }
        // The title is optional: an unnamed conversation still needs a subject on
        // the wire, so fall back to the neutral default. Display derives the title
        // back from this (showing the participants for an unnamed thread).
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let wireSubject = trimmedSubject.isEmpty ? ConversationDefaults.unnamedSubject : trimmedSubject
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty || !attachments.isEmpty else {
            errorMessage = "Write a message or attach a file before sending."
            return false
        }
        guard !recipients.isEmpty || !cc.isEmpty || !bcc.isEmpty else {
            errorMessage = "Add at least one recipient."
            return false
        }

        let draft = OutgoingDraft.new(from: account, to: recipients, cc: cc, bcc: bcc, subject: wireSubject, body: trimmedBody, attachments: attachments.map(\.outgoing), sentAt: Date())
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

    /// Apply a per-thread server mutation across a selection, rethreading and
    /// refreshing once at the end rather than once per thread: K selected
    /// conversations cost one rethread, not K. Even if a mutation fails midway the
    /// threads already changed are rethreaded and shown before the error surfaces,
    /// so partial progress isn't lost. The shared shape of the bulk read/flag/
    /// trash/archive/junk/move actions; each passes `rethread: false` to the
    /// per-thread sync call. Errors surface in `errorMessage`.
    private func bulkMutate(
        _ threadIDs: [String],
        removingRows: Bool = false,
        _ mutate: @escaping (String) async throws -> Void
    ) async {
        // Gated for the whole loop, so a live-refresh or pull sync can't land in a
        // gap between two threads and write its pre-delete snapshot back over them.
        await attempt {
            try await self.exclusively {
                // Drop the rows now for the actions that remove a conversation from
                // this list. The server round trip is seconds on a slow connection
                // and a whole multiple of that for a bulk selection, and leaving the
                // rows up for it reads as a dead tap. The reload below is still the
                // truth: anything the server refused comes straight back, with the
                // reason in `errorMessage`.
                if removingRows {
                    let removed = Set(threadIDs)
                    self.summaries.removeAll { removed.contains($0.id) }
                }
                var caught: Error?
                for id in threadIDs {
                    do { try await mutate(id) } catch { caught = error; break }
                }
                try await self.sync.rethread()
                try await self.reloadList()
                if let caught { throw caught }
            }
        }
        drainMissedLiveTick()
    }

    /// Mark one or more conversations read or unread, reflecting each on the
    /// server and then refreshing the inbox rows once. Errors surface in
    /// `errorMessage`.
    public func markRead(threadIDs: [String], read: Bool) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await bulkMutate(threadIDs) { id in
            try await self.sync.setRead(threadID: id, seen: read, password: password, rethread: false)
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
        await bulkMutate(threadIDs) { id in
            try await self.sync.setFlagged(threadID: id, flagged: flagged, password: password, rethread: false)
        }
    }

    /// Flag or unflag a single conversation.
    public func markFlagged(threadID: String, flagged: Bool) async {
        await markFlagged(threadIDs: [threadID], flagged: flagged)
    }

    /// Pin or unpin a conversation, keeping it at the top of the inbox. Local-only
    /// app state, so unlike flagging it needs no connection and touches no server;
    /// the list simply re-sorts on reload. Errors surface in `errorMessage`.
    public func setPinned(threadID: String, pinned: Bool) async {
        await attempt {
            try await self.store.setPinned(pinned, threadID: threadID, accountID: self.account.id)
            try await self.reloadList()
        }
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

    /// The bytes of an inline-rendered attachment (an image thumbnail or a voice
    /// memo to play): the cache first (instant for a just-sent file, or one
    /// loaded before), then a fetch by part section, caching the result so the
    /// next load is instant too. The disk read runs off the main actor. Returns
    /// nil for a purely local attachment that was never cached, or on a failed
    /// fetch; no error is surfaced, since an inline view that can't load falls
    /// back to a chip rather than interrupting the reader.
    public func cachedAttachmentData(messageID: String, attachment: MessageAttachment) async -> Data? {
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
        await bulkMutate(threadIDs, removingRows: !isViewing(.trash)) { id in
            try await self.sync.trash(threadID: id, password: password, rethread: false)
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
        await bulkMutate(threadIDs, removingRows: !isViewing(.archive)) { id in
            try await self.sync.archive(threadID: id, password: password, rethread: false)
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
        await bulkMutate(threadIDs, removingRows: !isViewing(.junk)) { id in
            try await self.sync.junk(threadID: id, password: password, rethread: false)
        }
    }

    /// Mark a single conversation as junk.
    public func junk(_ summary: ThreadSummary) async {
        await junk(threadIDs: [summary.id])
    }

    /// Block a sender: add the address to the blocklist and sync, which moves
    /// their existing INBOX mail to Junk and keeps new arrivals out on every
    /// later sync. The address is normalized; the account's own address can't be
    /// blocked. Server-touching (the sync moves the backlog), so a failed sync
    /// surfaces in `errorMessage` with the address still added.
    public func block(address: String) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        let normalized = address.lowercased()
        guard !normalized.isEmpty, normalized != account.emailAddress.lowercased() else { return }
        await attempt {
            try await self.exclusively {
                try await self.store.setBlocked(true, address: normalized, accountID: self.account.id)
                try await self.sync.syncInbox(password: password)
                self.blockedSenders = try await self.store.blockedSenders(accountID: self.account.id)
                try await self.reloadList()
            }
        }
        drainMissedLiveTick()
    }

    /// Unblock a sender: remove the address so their future mail stays in the
    /// inbox. Mail already moved to Junk is left there; unblocking only stops
    /// future junking. Local-only, no network. Errors surface in `errorMessage`.
    public func unblock(address: String) async {
        await attempt {
            try await self.store.setBlocked(false, address: address, accountID: self.account.id)
            self.blockedSenders = try await self.store.blockedSenders(accountID: self.account.id)
        }
    }

    /// Load the blocked sender list into `blockedSenders` for the management UI.
    public func loadBlockedSenders() async {
        await attempt {
            self.blockedSenders = try await self.store.blockedSenders(accountID: self.account.id)
        }
    }

    /// Move one or more conversations to `destination` (a folder name) and drop
    /// each from the current list, refreshing once at the end. Server-first,
    /// mirroring `trash`.
    public func move(threadIDs: [String], to destination: String) async {
        guard let password else {
            errorMessage = "Connect an account first."
            return
        }
        await bulkMutate(threadIDs, removingRows: destination != currentMailbox.name) { id in
            try await self.sync.move(threadID: id, to: destination, password: password, rethread: false)
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
