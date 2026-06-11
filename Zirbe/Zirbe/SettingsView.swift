// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The settings sheet, reached from the gear in the inbox. It shows the signed-in
// account and, for now, a single action: Sign Out. The structure (a sectioned
// Form) is deliberately laid out to grow as more settings arrive.

import SwiftUI
import ZirbeCore

struct SettingsView: View {
    let account: Account
    /// Full sign-out: forget the credential and wipe the local copy. Routed up to
    /// the session, which swaps the UI back to onboarding.
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Email", value: account.emailAddress)
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
