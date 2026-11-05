// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Top level. The AppSession owns the store and the connected session: on launch
// it tries to restore a saved account silently from the Keychain, landing the
// user in the inbox; otherwise it shows onboarding. Sign-out routes back here.
// The password lives in the InboxModel for the run and, persisted, in the
// device-bound Keychain — never on disk in the clear, never synced.

import SwiftUI
import ZirbeCore

struct RootView: View {
    @State private var session = AppSession()
    /// The navigation stack's pushed conversations, each with the summary it was
    /// opened from, so an inbox reload doesn't redraw the open conversation.
    /// On regular width the same path drives the split view's detail column, so a
    /// size change carries the open conversation across.
    @State private var path: [ThreadSummary] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var notifier = NewMailNotifier.shared

    var body: some View {
        Group {
            if session.isRestoring {
                launch
            } else if let model = session.model, model.isConnected {
                navigation(model: model)
                .id(model.account.id)
                .task(id: session.inboxUnreadCount) {
                    await notifier.updateBadge(unreadCount: session.inboxUnreadCount)
                }
                // Land in the inbox, then ask for notification permission once.
                // Demo mode never prompts, so a permission alert can't land on a
                // screenshot.
                .task {
                    guard !DemoMode.isActive else { return }
                    await notifier.requestAuthorizationIfNeeded()
                }
                #if DEBUG
                // Demo screenshot capture: open the top conversation on launch so
                // the thread screen can be grabbed without a tap. Summaries are
                // already seeded by the time this branch renders.
                .task {
                    guard DemoMode.opensTopConversation, path.isEmpty else { return }
                    let wanted = DemoMode.openSubject
                    guard let target = model.summaries.first(where: { summary in
                        wanted.map { summary.subject.localizedCaseInsensitiveContains($0) } ?? true
                    }) else { return }
                    path = [target]
                }
                #endif
                // A tapped notification surfaces its thread here; open it and clear.
                .onReceive(notifier.$pendingTarget) { target in
                    guard let target else { return }
                    notifier.pendingTarget = nil
                    Task { await open(target) }
                }
            } else {
                OnboardingView(
                    prefillEmail: session.restoredAccount?.emailAddress ?? "",
                    onConnect: { account, password in
                        try await session.connect(account: account, password: password)
                    }
                )
            }
        }
        .task { await session.restore() }
    }

    /// The push stack on compact width; on regular width the conversation list
    /// beside the open conversation.
    @ViewBuilder
    private func navigation(model: InboxModel) -> some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                InboxView(model: model, onSignOut: signOut, openedThread: openedThread)
            } detail: {
                if let summary = path.last {
                    ConversationView(model: model, summary: summary, onClose: closeConversation)
                        .id(summary.id)
                } else {
                    Color.zirbeCanvas.ignoresSafeArea()
                }
            }
            .onChange(of: model.currentMailbox) { path.removeAll() }
        } else {
            NavigationStack(path: $path) {
                InboxView(model: model, onSignOut: signOut)
                    .navigationDestination(for: ThreadSummary.self) { summary in
                        ConversationView(model: model, summary: summary, showsBack: true, onClose: closeConversation)
                    }
            }
        }
    }

    private func signOut() {
        guard let accountID = session.model?.account.id else { return }
        path.removeAll()
        Task { await session.remove(accountID) }
    }

    private func closeConversation() {
        path.removeAll()
    }

    /// The split view's open conversation, as the inbox reads and sets it.
    private var openedThread: Binding<ThreadSummary?> {
        Binding(get: { path.last }, set: { path = $0.map { [$0] } ?? [] })
    }

    /// Open a notification's conversation. A message that arrived after the last
    /// sync isn't in the list yet, so a miss syncs once and looks again.
    private func open(_ target: NewMailNotifier.Target) async {
        if session.currentAccountID != target.accountID {
            path.removeAll()
            await session.select(target.accountID)
        }
        guard let model = session.model, model.account.id == target.accountID else { return }
        func summary() -> ThreadSummary? { model.summaries.first { $0.id == target.threadID } }
        if summary() == nil { await model.refresh() }
        if let found = summary() { path = [found] }
    }

    /// Held briefly on launch while a saved session is restored, so onboarding
    /// doesn't flash before a silent auto-connect.
    private var launch: some View {
        Text("Zirbe")
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
    }
}
