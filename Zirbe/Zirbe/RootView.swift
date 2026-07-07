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
    /// The navigation stack's pushed conversations, by thread id. Empty at the
    /// inbox; a notification tap (or a future deep link) pushes one id onto it.
    @State private var path: [String] = []
    @ObservedObject private var notifier = NewMailNotifier.shared

    var body: some View {
        Group {
            if session.isRestoring {
                launch
            } else if let model = session.model, model.isConnected {
                NavigationStack(path: $path) {
                    InboxView(model: model, onSignOut: { Task { await session.signOut() } })
                        .navigationDestination(for: String.self) { threadID in
                            conversation(threadID, model: model)
                        }
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
                    guard DemoMode.opensTopConversation, path.isEmpty,
                          let first = model.summaries.first else { return }
                    path = [first.id]
                }
                #endif
                // A tapped notification surfaces its thread here; push it and clear.
                .onReceive(notifier.$pendingThreadID) { threadID in
                    guard let threadID else { return }
                    path = [threadID]
                    notifier.pendingThreadID = nil
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

    /// The conversation for a deep-linked thread id. Resolves the inbox summary;
    /// on a cold launch from a tap the summaries may not be loaded yet, so it shows
    /// a brief loader and triggers a refresh, then rebuilds once they arrive.
    @ViewBuilder
    private func conversation(_ threadID: String, model: InboxModel) -> some View {
        if let summary = model.summaries.first(where: { $0.id == threadID }) {
            ConversationView(model: model, summary: summary)
        } else {
            ProgressView()
                .task { await model.refresh() }
        }
    }

    /// Held briefly on launch while a saved session is restored, so onboarding
    /// doesn't flash before a silent auto-connect.
    private var launch: some View {
        Text("Zirbe")
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
    }
}
