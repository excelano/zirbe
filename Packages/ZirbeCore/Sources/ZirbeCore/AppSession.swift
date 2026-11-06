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
    public private(set) var models: [InboxModel] = []
    public private(set) var currentAccountID: String?
    /// The last restore/connect error, in a form a view can show.
    public private(set) var errorMessage: String?
    /// True until the first restore attempt finishes, so the UI can hold a
    /// launch view instead of flashing onboarding before a silent auto-connect.
    public private(set) var isRestoring = true

    private var store: MailStore?
    private let credentials: any CredentialStore
    private let openStore: () throws -> MailStore
    private let makeModel: (Account, MailStore) -> InboxModel
    private let defaults: UserDefaults

    private static let currentAccountKey = "session.currentAccountID"

    public convenience init() {
        self.init(
            credentials: KeychainStore(),
            openStore: { try MailStore(path: StoreLocation.databasePath()) },
            makeModel: { InboxModel(account: $0, store: $1) },
            defaults: .standard
        )
    }

    init(
        credentials: any CredentialStore,
        openStore: @escaping () throws -> MailStore,
        makeModel: @escaping (Account, MailStore) -> InboxModel,
        defaults: UserDefaults
    ) {
        self.credentials = credentials
        self.openStore = openStore
        self.makeModel = makeModel
        self.defaults = defaults
    }

    public var model: InboxModel? {
        models.first { $0.account.id == currentAccountID } ?? models.first
    }

    public var accounts: [Account] { models.map(\.account) }

    public var isConnected: Bool { model?.isConnected == true }

    /// An account found persisted but not connected: no stored password, or the
    /// server rejected it. The onboarding screen prefills from it so the user
    /// only re-enters the password.
    public var restoredAccount: Account? {
        model.flatMap { $0.isConnected ? nil : $0.account }
    }

    public var firstConnectedAccountID: String? {
        models.first(where: \.isConnected)?.account.id
    }

    public var inboxUnreadCount: Int {
        models.reduce(0) { $0 + ($1.unreadCounts["INBOX"] ?? 0) }
    }

    public func restore() async {
        guard models.isEmpty else { isRestoring = false; return }
        defer { isRestoring = false }
        #if DEBUG
        if DemoMode.isActive {
            await enterDemo()
            return
        }
        #endif
        do {
            let store = try ensureStore()
            for account in try await store.accounts() {
                let candidate = makeModel(account, store)
                do {
                    if let password = try credentials.password(for: account.id) {
                        await candidate.resume(password: password)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
                models.append(candidate)
            }
            let remembered = defaults.string(forKey: Self.currentAccountKey)
            currentAccountID = models.contains { $0.account.id == remembered } ? remembered : models.first?.account.id
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
        var account = account
        if let existing = models.first(where: { $0.account.id == account.id })?.account {
            account.label = existing.label
            account.color = existing.color
        } else {
            account.color = nextColor()
        }
        let candidate = makeModel(account, store)
        try await candidate.signIn(password: password)
        try credentials.save(password: password, for: account.id)
        errorMessage = nil
        if let index = models.firstIndex(where: { $0.account.id == account.id }) {
            let replaced = models[index]
            models[index] = candidate
            await replaced.stopLiveRefresh()
            replaced.signOut()
        } else {
            models.append(candidate)
        }
        await select(account.id)
    }

    public func setAppearance(label: String?, color: AccountColor, accountID: String) async {
        guard let model = models.first(where: { $0.account.id == accountID }) else { return }
        do {
            try await store?.setAppearance(label: label, color: color, accountID: accountID)
            model.account.label = label
            model.account.color = color
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nextColor() -> AccountColor {
        let used = Set(models.map(\.account.color))
        return AccountColor.allCases.first { !used.contains($0) }
            ?? AccountColor.allCases[models.count % AccountColor.allCases.count]
    }

    public func select(_ accountID: String) async {
        guard models.contains(where: { $0.account.id == accountID }) else { return }
        if let previous = model, previous.account.id != accountID {
            await previous.stopLiveRefresh()
        }
        currentAccountID = accountID
        defaults.set(accountID, forKey: Self.currentAccountKey)
    }

    public func remove(_ accountID: String) async {
        guard let index = models.firstIndex(where: { $0.account.id == accountID }) else { return }
        let removed = models.remove(at: index)
        await removed.stopLiveRefresh()
        removed.signOut()
        try? credentials.delete(for: accountID)
        AttachmentCache.removeAll()
        if models.isEmpty {
            try? await store?.eraseAll()
        } else {
            try? await store?.eraseAccount(accountID)
        }
        if currentAccountID == accountID {
            currentAccountID = models.first?.account.id
            defaults.set(currentAccountID, forKey: Self.currentAccountKey)
        }
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
            models = [candidate]
            currentAccountID = DemoData.account.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    private func ensureStore() throws -> MailStore {
        if let store { return store }
        let created = try openStore()
        store = created
        return created
    }
}
