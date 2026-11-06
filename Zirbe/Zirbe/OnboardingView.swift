// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// First-run onboarding: a single adaptive screen. The user types an email; once
// it has a domain, the servers are inferred from a baked-in provider table
// (ProviderPresets, offline — no network autodiscovery), the password field
// appears with a provider-specific hint, and the prefilled server settings sit
// in a disclosure that opens automatically for unknown domains. The password is
// handed to AppSession, which signs in and, on success, stores it in the
// Keychain so the next launch is silent. This screen never stores a secret.

import AuthenticationServices
import SwiftUI
import ZirbeCore

struct OnboardingView: View {
    /// A stored account whose password needs re-entering: its address and
    /// servers are prefilled, so the user only types the password.
    let prefill: Account?
    let session: AppSession
    var onConnected: () -> Void = {}
    var onCancel: (() -> Void)?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var usesAppPassword = false

    @State private var email = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    /// The domain the server fields were last prefilled for, so typing within one
    /// domain doesn't clobber edits but switching domains re-prefills.
    @State private var appliedDomain: String?
    @State private var serversExpanded = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    private var preset: ProviderPreset? { ProviderPresets.preset(forEmail: email) }
    private var resolved: ProviderPreset? { ProviderPresets.resolve(forEmail: email) }
    private var hasDomain: Bool { resolved != nil }

    private var oauthProvider: OAuthProvider? {
        guard !usesAppPassword, let id = ProviderPresets.oauthProvider(forIMAPHost: imapHost) else { return nil }
        let provider = OAuthProvider.provider(for: id)
        return provider.isConfigured ? provider : nil
    }

    private var hostedProviders: [OAuthProvider] {
        guard preset == nil, ProviderPresets.oauthProvider(forIMAPHost: imapHost) == nil else { return [] }
        return [OAuthProvider.microsoft, .google].filter(\.isConfigured)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                brand
                emailField
                if hasDomain {
                    providerCaption
                    if let oauthProvider {
                        signInButton(oauthProvider)
                        Button("Use an app password instead") { usesAppPassword = true }
                            .font(.footnote)
                    } else {
                        passwordField
                        if !hostedProviders.isEmpty { hostedSignIn }
                    }
                    serverSettings
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if oauthProvider == nil {
                    connectButton
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.zirbeCanvas.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .padding()
                    .disabled(isConnecting)
            }
        }
        .overlay {
            if isConnecting {
                ProgressView().controlSize(.large)
            }
        }
        .onAppear(perform: applyPrefill)
        .onChange(of: email) { _, _ in applyPresetIfDomainChanged() }
    }

    // MARK: Sections

    private var brand: some View {
        VStack(spacing: 6) {
            Text("Zirbe")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
            Text("Connect your email")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
        .padding(.bottom, 8)
    }

    private var emailField: some View {
        TextField("you@example.com", text: $email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.center)
            .font(.title3)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var providerCaption: some View {
        if let name = preset?.displayName {
            Label("Looks like \(name)", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("App-specific password", text: $password)
                .textContentType(.password)
                .focused($passwordFocused)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            if let hint = resolved?.passwordHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func signInButton(_ provider: OAuthProvider) -> some View {
        Button { signIn(with: provider) } label: {
            Text("Sign in with \(provider.displayName)")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .disabled(isConnecting)
    }

    private var hostedSignIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email hosted by Microsoft 365 or Google Workspace?")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(hostedProviders, id: \.id) { provider in
                    Button("Sign in with \(provider.displayName)") {
                        let servers = ProviderPresets.servers(for: provider.id)
                        imapHost = servers.imapHost
                        imapPort = String(servers.imapPort)
                        smtpHost = servers.smtpHost
                        smtpPort = String(servers.smtpPort)
                        signIn(with: provider)
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isConnecting)
    }

    private var serverSettings: some View {
        DisclosureGroup("Server settings", isExpanded: $serversExpanded) {
            VStack(spacing: 12) {
                serverRow("IMAP host", text: $imapHost, placeholder: "imap.example.com")
                serverRow("IMAP port", text: $imapPort, placeholder: "993", number: true)
                serverRow("SMTP host", text: $smtpHost, placeholder: "smtp.example.com")
                serverRow("SMTP port", text: $smtpPort, placeholder: "587", number: true)
            }
            .padding(.top, 8)
        }
        .tint(.secondary)
        .font(.subheadline)
    }

    private func serverRow(_ label: String, text: Binding<String>, placeholder: String, number: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(number ? .numberPad : .URL)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private var connectButton: some View {
        Button(action: connect) {
            Text("Connect")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canConnect ? Color.accentColor : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(canConnect ? .white : .secondary)
        }
        .disabled(!canConnect || isConnecting)
        .padding(.top, 8)
    }

    // MARK: Logic

    private var canConnect: Bool {
        hasDomain && !password.isEmpty && !imapHost.trimmed.isEmpty && !smtpHost.trimmed.isEmpty
    }

    /// Prefill the server fields from the provider table whenever the email's
    /// domain changes, and open the disclosure for unknown domains so the user
    /// confirms the guessed servers.
    private func applyPresetIfDomainChanged() {
        guard let resolved else { appliedDomain = nil; return }
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased()
        guard domain != appliedDomain else { return }
        appliedDomain = domain
        imapHost = resolved.imapHost
        imapPort = String(resolved.imapPort)
        smtpHost = resolved.smtpHost
        smtpPort = String(resolved.smtpPort)
        serversExpanded = (resolved.displayName == nil)  // open for unknown providers
    }

    private func applyPrefill() {
        guard let prefill, email.isEmpty else { return }
        appliedDomain = prefill.emailAddress.split(separator: "@").last.map(String.init)?.lowercased()
        email = prefill.emailAddress
        imapHost = prefill.imapHost
        imapPort = String(prefill.imapPort)
        smtpHost = prefill.smtpHost
        smtpPort = String(prefill.smtpPort)
    }

    private var formAccount: Account {
        Account(
            emailAddress: email.trimmed,
            imapHost: imapHost.trimmed,
            imapPort: Int(imapPort.trimmed) ?? 993,
            smtpHost: smtpHost.trimmed,
            smtpPort: Int(smtpPort.trimmed) ?? 587
        )
    }

    private func connect() {
        passwordFocused = false
        let account = formAccount
        run { try await session.connect(account: account, password: password) }
    }

    private func signIn(with provider: OAuthProvider) {
        let account = formAccount
        let authorization = OAuthAuthorization(provider: provider, loginHint: account.emailAddress)
        run {
            let callback = try await webAuthenticationSession.authenticate(
                using: authorization.url,
                callbackURLScheme: provider.callbackScheme,
                preferredBrowserSession: .ephemeral
            )
            try await session.connect(account: account, authorization: authorization, callback: callback)
        }
    }

    private func run(_ attempt: @escaping () async throws -> Void) {
        Task {
            isConnecting = true
            errorMessage = nil
            do {
                try await attempt()
                onConnected()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
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
