// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The M2c connect screen: collect an account and an app-specific password.
// Email and host are remembered (non-secret); the password is typed each launch
// and never stored. Real onboarding with autodiscovery and Keychain storage
// arrives in M4.

import SwiftUI
import ZirbeCore

struct ConnectView: View {
    /// Called with the assembled account and the typed password. Throwing keeps
    /// the user on this screen on failure, e.g. a wrong password.
    let onConnect: (Account, String) async throws -> Void

    @AppStorage("account.email") private var email = ""
    @AppStorage("account.imapHost") private var imapHost = ""
    @AppStorage("account.smtpHost") private var smtpHost = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App-specific password", text: $password)
                }
                Section("Servers") {
                    TextField("IMAP host, e.g. imap.fastmail.com", text: $imapHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("SMTP host, e.g. smtp.fastmail.com", text: $smtpHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: connect)
                        .disabled(!canConnect || isConnecting)
                }
            }
            .overlay {
                if isConnecting {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    private var canConnect: Bool {
        !email.trimmed.isEmpty && !imapHost.trimmed.isEmpty && !password.isEmpty
    }

    private func connect() {
        let imap = imapHost.trimmed
        let smtp = smtpHost.trimmed.isEmpty ? imap : smtpHost.trimmed
        let account = Account(emailAddress: email.trimmed, imapHost: imap, smtpHost: smtp)
        Task {
            isConnecting = true
            errorMessage = nil
            do {
                try await onConnect(account, password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
