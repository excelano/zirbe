// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The settings sheet, reached from the gear in the inbox. It shows the signed-in
// account and, for now, a single action: Sign Out. The structure (a sectioned
// Form) is deliberately laid out to grow as more settings arrive.

import SwiftUI
import ZirbeCore

/// UserDefaults keys for the app's reading preferences, shared by the settings
/// toggles here and the conversation view that honors them. Both default off:
/// Zirbe shows the plain-text version with remote images blocked unless the user
/// opts into the richer, less private behavior.
enum SettingsKeys {
    /// Open an HTML email in its Web View automatically instead of the text bubble.
    static let openHTMLInWebView = "settings.openHTMLInWebView"
    /// Load remote images in the Web View by default rather than blocking them.
    static let loadRemoteImages = "settings.loadRemoteImages"
}

struct SettingsView: View {
    let account: Account
    /// Full sign-out: forget the credential and wipe the local copy. Routed up to
    /// the session, which swaps the UI back to onboarding.
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @AppStorage(SettingsKeys.openHTMLInWebView) private var openHTMLInWebView = false
    @AppStorage(SettingsKeys.loadRemoteImages) private var loadRemoteImages = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Email", value: account.emailAddress)
                }

                Section {
                    Toggle("Open HTML email in Web View", isOn: $openHTMLInWebView)
                    Toggle("Load remote images", isOn: $loadRemoteImages)
                } header: {
                    Text("HTML Email")
                } footer: {
                    Text("Zirbe shows the plain-text version by default. Opening the Web View renders the full HTML email. Loading remote images can let a sender know you opened the message and roughly where you are, so it stays off unless you turn it on.")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        confirmingSignOut = true
                    }
                } footer: {
                    Text("Signing out removes this account and its downloaded mail from this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sign out of \(account.emailAddress)?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    onSignOut()
                }
            } message: {
                Text("This removes the account and its downloaded mail from this device.")
            }
        }
    }
}
