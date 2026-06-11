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

    var body: some View {
        Group {
            if session.isRestoring {
                launch
            } else if let model = session.model, model.isConnected {
                NavigationStack {
                    InboxView(model: model, onSignOut: { Task { await session.signOut() } })
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

    /// Held briefly on launch while a saved session is restored, so onboarding
    /// doesn't flash before a silent auto-connect.
    private var launch: some View {
        Text("Zirbe")
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
    }
}
