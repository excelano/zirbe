// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The observable state the conversation UI binds to. It wraps the offline store
// and the sync service: the store is the source of truth the list reads, and
// the service fills it from the server. Per the architecture, the view model
// lives here in ZirbeCore (not the app target) so it is testable without a UI.

import Foundation
import Observation

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
