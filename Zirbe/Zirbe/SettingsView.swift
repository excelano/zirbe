// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import SwiftUI
import UIKit
import UserNotifications
import ZirbeCore

/// UserDefaults keys for the app's reading preferences, shared by the settings
/// toggles here and the conversation view that honors them. The HTML pair default
/// off: Zirbe shows the plain-text version with remote images blocked unless the
/// user opts into the richer, less private behavior.
enum SettingsKeys {
    /// Open an HTML email in Web View automatically instead of the chat bubble.
    static let openHTMLInWebView = "settings.openHTMLInWebView"
    /// Load remote images in Web View by default rather than blocking them.
    static let loadRemoteImages = "settings.loadRemoteImages"
    /// Post a banner when a background check finds new mail. Defaults on; the
    /// notifier reads the same key and treats an unset value as on.
    static let newMailNotifications = "settings.newMailNotifications"
    /// How many lines of each message to preview in the inbox row (0 = none).
    /// Defaults to 2; the inbox row reads the same key.
    static let previewLineCount = "settings.previewLineCount"
}

struct SettingsView: View {
    let session: AppSession
    let onRemoveAccount: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addingAccount = false
    /// True when the system permission has been denied, so the toggle can't take
    /// effect and we point the user to the system Settings instead.
    @State private var notificationsDenied = false
    @AppStorage(SettingsKeys.openHTMLInWebView) private var openHTMLInWebView = false
    @AppStorage(SettingsKeys.loadRemoteImages) private var loadRemoteImages = false
    @AppStorage(SettingsKeys.newMailNotifications) private var newMailNotifications = true
    @AppStorage(SettingsKeys.previewLineCount) private var previewLineCount = 2
    #if DEBUG
    @AppStorage(DemoMode.userDefaultsKey) private var demoMode = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(session.models, id: \.account.id) { model in
                        NavigationLink {
                            AccountSettingsView(session: session, model: model, onRemove: onRemoveAccount)
                        } label: {
                            accountRow(model)
                        }
                    }
                    Button("Add Account") { addingAccount = true }
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
                    Picker("Preview", selection: $previewLineCount) {
                        Text("None").tag(0)
                        Text("1 Line").tag(1)
                        Text("2 Lines").tag(2)
                        Text("3 Lines").tag(3)
                    }
                } header: {
                    Text("Inbox")
                } footer: {
                    Text("How many lines of each message to preview under the subject.")
                }

                Section {
                    Toggle("Open HTML email in Web View", isOn: $openHTMLInWebView)
                    Toggle("Load remote images", isOn: $loadRemoteImages)
                } header: {
                    Text("HTML Email")
                } footer: {
                    Text("Zirbe shows the plain-text version as a chat bubble by default. Web View renders the full HTML message. Loading remote images can let a sender know you opened the message and roughly where you are, so it stays off unless you turn it on.")
                }

                #if DEBUG
                Section {
                    Toggle("Demo mode", isOn: $demoMode)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Replaces your mail with generic sample conversations for App Store screenshots. Relaunch the app to apply. Your real account is left untouched.")
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Color.zirbeCanvas)
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
            .sheet(isPresented: $addingAccount) {
                OnboardingView(
                    prefill: nil,
                    session: session,
                    onConnected: { addingAccount = false },
                    onCancel: { addingAccount = false }
                )
            }
        }
    }

    private func accountRow(_ model: InboxModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AccountLabel(account: model.account)
            if model.account.label?.isEmpty == false {
                Text(model.account.emailAddress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.isConnected {
                Text("Password needed")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct AccountSettingsView: View {
    let session: AppSession
    let model: InboxModel
    let onRemove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var confirmingRemove = false
    @State private var reentering = false

    private var account: Account { model.account }

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $label, prompt: Text(account.emailAddress))
                    .textInputAutocapitalization(.words)
                    .onSubmit(saveLabel)
                LabeledContent("Email", value: account.emailAddress)
            } footer: {
                Text("The label names this account in the folder list and the inbox title.")
            }

            Section("Color") {
                HStack {
                    ForEach(AccountColor.allCases, id: \.self) { color in
                        Button {
                            Task { await session.setAppearance(label: account.label, color: color, accountID: account.id) }
                        } label: {
                            ZStack {
                                AccountDot(color: color, size: 28)
                                if color == account.color {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.name)
                        .accessibilityAddTraits(color == account.color ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            if !model.isConnected {
                Section {
                    Button("Sign In Again") { reentering = true }
                } footer: {
                    Text("Zirbe can’t sign in to this account, so it isn’t syncing.")
                }
            }

            Section {
                NavigationLink {
                    BlockedSendersView(model: model)
                } label: {
                    LabeledContent("Blocked Senders") {
                        Text(model.blockedSenders.isEmpty ? "None" : "\(model.blockedSenders.count)")
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("A blocked sender's mail is moved to your Junk folder as it arrives, and their existing mail is moved there when you block them.")
            }

            Section {
                Button("Remove Account", role: .destructive) {
                    confirmingRemove = true
                }
            } footer: {
                Text("Removing an account deletes its downloaded mail from this device.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.zirbeCanvas)
        .navigationTitle(account.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { label = account.label ?? "" }
        .onDisappear(perform: saveLabel)
        .task { await model.loadBlockedSenders() }
        .sheet(isPresented: $reentering) {
            OnboardingView(
                prefill: account,
                session: session,
                onConnected: { reentering = false },
                onCancel: { reentering = false }
            )
        }
        .confirmationDialog(
            "Remove \(account.emailAddress)?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                dismiss()
                onRemove(account.id)
            }
        } message: {
            Text("This removes the account and its downloaded mail from this device.")
        }
    }

    private func saveLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLabel = trimmed.isEmpty ? nil : trimmed
        guard newLabel != account.label else { return }
        Task { await session.setAppearance(label: newLabel, color: account.color, accountID: account.id) }
    }
}

/// The list of blocked senders, reached from Settings. Each row is an address;
/// swipe or tap Unblock to remove it, which only stops future junking (mail
/// already moved to Junk stays there). Empty until someone is blocked.
private struct BlockedSendersView: View {
    let model: InboxModel

    var body: some View {
        List {
            if model.blockedSenders.isEmpty {
                Section {
                    Text("No blocked senders. Block someone from the ⋯ menu in a conversation, and their mail moves to Junk.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(model.blockedSenders, id: \.self) { address in
                        Text(address)
                            .swipeActions(edge: .trailing) {
                                Button("Unblock") {
                                    Task { await model.unblock(address: address) }
                                }
                                .tint(.accentColor)
                            }
                    }
                } footer: {
                    Text("Unblocking lets their future mail reach your inbox again. Mail already moved to Junk stays there.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.zirbeCanvas)
        .navigationTitle("Blocked Senders")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadBlockedSenders() }
    }
}
