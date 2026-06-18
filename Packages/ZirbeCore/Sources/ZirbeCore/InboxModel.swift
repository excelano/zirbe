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
    /// The inbox rows, most recent activity first. Read-only to the UI.
    public private(set) var summaries: [ThreadSummary] = []
    /// True while an inbox sync is in flight, for a list-level progress view.
    public private(set) var isSyncing = false
    /// The last error, if any, in a form a view can show directly.
    public private(set) var errorMessage: String?

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
    }

    /// Whether a password is held, so refresh and conversation loads can run.
    public var isConnected: Bool { password != nil }

    /// Show whatever is already in the store, with no network. Safe on launch to
    /// display cached mail immediately.
    public func loadCached() async {
        await attempt {
            self.summaries = try await self.store.threadSummaries(accountID: self.account.id)
        }
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
        summaries = try await sync.syncInbox(password: password)
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
    public func sendReply(to thread: Thread, removing removedAddresses: Set<String> = [], body: String) async -> Thread? {
        guard let password else {
            errorMessage = "Connect an account first."
            return nil
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Write a message before sending."
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

        let draft = OutgoingDraft.reply(to: thread, as: account, to: to, cc: cc, body: trimmed, sentAt: Date())
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
        body: String
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
        guard !trimmedBody.isEmpty else {
            errorMessage = "Write a message before sending."
            return false
        }
        guard !recipients.isEmpty || !cc.isEmpty else {
            errorMessage = "Add at least one recipient."
            return false
        }

        let draft = OutgoingDraft.new(from: account, to: recipients, cc: cc, subject: trimmedSubject, body: trimmedBody, sentAt: Date())
        do {
            try await sync.send(draft, password: password)
            summaries = try await store.threadSummaries(accountID: account.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
            self.summaries = try await self.store.threadSummaries(accountID: self.account.id)
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
            self.summaries = try await self.store.threadSummaries(accountID: self.account.id)
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
            summaries = try await store.threadSummaries(accountID: account.id)
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
            self.summaries = try await self.store.threadSummaries(accountID: self.account.id)
        }
    }

    /// Trash a single conversation.
    public func trash(_ summary: ThreadSummary) async {
        await trash(threadIDs: [summary.id])
    }

    /// Forget the session password, close the warm connection, and clear
    /// in-memory state.
    public func signOut() {
        password = nil
        summaries = []
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
