// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The settings sheet, reached from the gear in the inbox. It shows the signed-in
// account and, for now, a single action: Sign Out. The structure (a sectioned
// Form) is deliberately laid out to grow as more settings arrive.

import SwiftUI
import UIKit
import UserNotifications
import ZirbeCore

/// UserDefaults keys for the app's reading preferences, shared by the settings
/// toggles here and the conversation view that honors them. The HTML pair default
/// off: Zirbe shows the plain-text version with remote images blocked unless the
/// user opts into the richer, less private behavior.
enum SettingsKeys {
    /// Open an HTML email in its Web View automatically instead of the text bubble.
    static let openHTMLInWebView = "settings.openHTMLInWebView"
    /// Load remote images in the Web View by default rather than blocking them.
    static let loadRemoteImages = "settings.loadRemoteImages"
    /// Post a banner when a background check finds new mail. Defaults on; the
    /// notifier reads the same key and treats an unset value as on.
    static let newMailNotifications = "settings.newMailNotifications"
}

struct SettingsView: View {
    let account: Account
    /// Full sign-out: forget the credential and wipe the local copy. Routed up to
    /// the session, which swaps the UI back to onboarding.
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    /// True when the system permission has been denied, so the toggle can't take
    /// effect and we point the user to the system Settings instead.
    @State private var notificationsDenied = false
    @AppStorage(SettingsKeys.openHTMLInWebView) private var openHTMLInWebView = false
    @AppStorage(SettingsKeys.loadRemoteImages) private var loadRemoteImages = false
    @AppStorage(SettingsKeys.newMailNotifications) private var newMailNotifications = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Email", value: account.emailAddress)
                }

                Section {
                    Text("Zirbe updates live while you're reading and checks for new mail in the background when iOS allows. There's no instant push: that would need a server holding the connection, and Zirbe has none. Mail that arrives while the app is closed appears at the next background check or when you reopen it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Refreshing")
                }

                Section {
                    Toggle("New mail notifications", isOn: $newMailNotifications)
                    if notificationsDenied {
                        Button("Allow in System Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notificationsDenied
                        ? "Notifications are turned off for Zirbe in System Settings. Turn them on there to get a banner when a background check finds new mail."
                        : "Get a banner when a background check finds new mail. These follow the same schedule as the background refresh above, not instant push.")
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
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsDenied = settings.authorizationStatus == .denied
            }
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
