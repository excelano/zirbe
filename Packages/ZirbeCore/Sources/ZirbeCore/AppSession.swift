// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The app's session owner. It holds the one store and the connected InboxModel,
// and sits above InboxModel as the credential-persistence layer: InboxModel
// still keeps the password in memory for the run, while this object reads and
// writes it to the Keychain so a returning user lands in the inbox without
// retyping. Restore on launch, connect on first sign-in, and a full forget on
// sign-out all live here, keeping the views thin.

import Foundation
import Observation

@MainActor
@Observable
public final class AppSession {
    /// The connected session, or nil when no account is signed in.
    public private(set) var model: InboxModel?
    /// The last restore/connect error, in a form a view can show.
    public private(set) var errorMessage: String?
    /// An account we found persisted but couldn't auto-connect (no stored
    /// password, or the sign-in failed). The onboarding screen prefills from it
    /// so the user only re-enters the password.
    public private(set) var restoredAccount: Account?
    /// True until the first restore attempt finishes, so the UI can hold a
    /// launch view instead of flashing onboarding before a silent auto-connect.
    public private(set) var isRestoring = true

    private var store: MailStore?

    public init() {}

    public var isConnected: Bool { model?.isConnected == true }

    /// On launch: if an account and its Keychain password are both present, sign
    /// in silently. Any failure (no password, rejected password, server
    /// unreachable) leaves the account in `restoredAccount` and drops to
    /// onboarding for password re-entry. The stored credential and account row
    /// are left intact, so a later relaunch can still auto-connect.
    public func restore() async {
        guard model == nil else { isRestoring = false; return }
        defer { isRestoring = false }
        #if DEBUG
        if DemoMode.isActive {
            await enterDemo()
            return
        }
        #endif
        do {
            let store = try ensureStore()
            guard let account = try await store.accounts().first else { return }
            guard let password = try KeychainStore.password(for: account.id) else {
                restoredAccount = account
                return
            }
            let candidate = InboxModel(account: account, store: store)
            try await candidate.signIn(password: password)
            model = candidate
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Connect a freshly entered account: sign in (which syncs and persists the
    /// account row), then save the password to the Keychain so the next launch
    /// is silent. Throws back to the onboarding screen on failure; nothing is
    /// written to the Keychain unless the sign-in succeeds.
    public func connect(account: Account, password: String) async throws {
        let store = try ensureStore()
        let candidate = InboxModel(account: account, store: store)
        try await candidate.signIn(password: password)
        try KeychainStore.save(password: password, for: account.id)
        errorMessage = nil
        restoredAccount = nil
        model = candidate
    }

    /// Full sign-out: forget the credential, wipe the local cache, and return to
    /// onboarding. Best-effort — a failed erase still drops the session.
    public func signOut() async {
        let account = model?.account
        model?.signOut()
        model = nil
        restoredAccount = nil
        if let account {
            try? KeychainStore.delete(for: account.id)
        }
        try? await store?.eraseAll()
    }

    #if DEBUG
    /// Enter demo/screenshot mode: build an isolated in-memory store, seed it with
    /// sample conversations, and connect a demo model to it, all without touching
    /// the signed-in account, its Keychain password, or the on-disk cache. The gate
    /// in RootView then shows the inbox as if signed in.
    private func enterDemo() async {
        do {
            let demoStore = try MailStore()
            try await DemoData.seed(into: demoStore)
            let candidate = InboxModel(account: DemoData.account, store: demoStore)
            candidate.enterDemoMode()
            await candidate.loadCached()
            store = demoStore
            model = candidate
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    private func ensureStore() throws -> MailStore {
        if let store { return store }
        let created = try MailStore(path: StoreLocation.databasePath())
        store = created
        return created
    }
}
