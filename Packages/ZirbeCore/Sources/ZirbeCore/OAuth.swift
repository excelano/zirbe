// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import CryptoKit
import Foundation
import ZirbeMail

public struct OAuthProvider: Sendable, Hashable {
    public enum ID: String, Sendable, Hashable, Codable {
        case microsoft, google
    }

    public let id: ID
    public let displayName: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    public let clientID: String
    public let redirectURI: String
    let scopes: [String]
    let refreshSendsScope: Bool

    public var callbackScheme: String {
        String(redirectURI.prefix { $0 != ":" })
    }

    public var isConfigured: Bool { !clientID.isEmpty }

    public static func provider(for id: ID) -> OAuthProvider {
        switch id {
        case .microsoft: .microsoft
        case .google: .google
        }
    }

    public static let microsoft = OAuthProvider(
        id: .microsoft,
        displayName: "Microsoft",
        authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        clientID: OAuthClientIDs.microsoft,
        redirectURI: "msauth.com.excelano.zirbe://auth",
        scopes: [
            "https://outlook.office.com/IMAP.AccessAsUser.All",
            "https://outlook.office.com/SMTP.Send",
            "offline_access",
        ],
        refreshSendsScope: true
    )

    public static let google = OAuthProvider(
        id: .google,
        displayName: "Google",
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        clientID: OAuthClientIDs.google,
        redirectURI: googleRedirectURI(clientID: OAuthClientIDs.google),
        scopes: ["https://mail.google.com/"],
        refreshSendsScope: false
    )

    static func googleRedirectURI(clientID: String) -> String {
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        return "\(reversed):/oauth2redirect"
    }
}

enum OAuthClientIDs {
    static let microsoft = "1e5b498b-2c00-4466-9028-b3841124ed78"
    static let google = ""
}

public struct OAuthTokens: Sendable, Hashable, Codable {
    public var provider: OAuthProvider.ID
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(provider: OAuthProvider.ID, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public enum OAuthError: Error, Equatable {
    case stateMismatch
    case denied(String)
    case missingCode
    case missingRefreshToken
    case rejected(status: Int, error: String?)
}

extension OAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .denied(let reason):
            "Sign-in was declined (\(reason))."
        case .stateMismatch, .missingCode:
            "The sign-in didn’t complete. Try again."
        case .missingRefreshToken:
            "The provider didn’t allow offline access, so Zirbe can’t stay signed in."
        case .rejected(let status, let error):
            "The provider refused the sign-in (\(error ?? "HTTP \(status)"))."
        }
    }
}

public struct OAuthAuthorization: Sendable {
    public let provider: OAuthProvider
    public let state: String
    let codeVerifier: String
    public let url: URL

    public init(provider: OAuthProvider, loginHint: String) {
        self.init(provider: provider, loginHint: loginHint, state: Self.randomToken(), codeVerifier: Self.randomToken())
    }

    init(provider: OAuthProvider, loginHint: String, state: String, codeVerifier: String) {
        self.provider = provider
        self.state = state
        self.codeVerifier = codeVerifier
        var components = URLComponents(url: provider.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "login_hint", value: loginHint),
        ]
        self.url = components.url!
    }

    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw OAuthError.stateMismatch }
        if let error = value("error") { throw OAuthError.denied(value("error_description") ?? error) }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public protocol OAuthHTTP: Sendable {
    func post(_ url: URL, form: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionOAuthHTTP: OAuthHTTP {
    public init() {}

    public func post(_ url: URL, form: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(OAuthClient.formEncoded(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct OAuthClient: Sendable {
    let http: any OAuthHTTP
    let now: @Sendable () -> Date

    public init(http: any OAuthHTTP = URLSessionOAuthHTTP(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.now = now
    }

    public func redeem(_ code: String, for authorization: OAuthAuthorization) async throws -> OAuthTokens {
        let provider = authorization.provider
        let response = try await post(provider, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": provider.redirectURI,
            "client_id": provider.clientID,
            "code_verifier": authorization.codeVerifier,
        ])
        guard let refreshToken = response.refresh_token else { throw OAuthError.missingRefreshToken }
        return tokens(from: response, provider: provider.id, refreshToken: refreshToken)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        let provider = OAuthProvider.provider(for: tokens.provider)
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": provider.clientID,
        ]
        if provider.refreshSendsScope { form["scope"] = provider.scopes.joined(separator: " ") }
        let response: TokenResponse
        do {
            response = try await post(provider, form: form)
        } catch let OAuthError.rejected(_, error) where error == "invalid_grant" {
            throw MailEngineError.authenticationRejected
        }
        return self.tokens(from: response, provider: provider.id, refreshToken: response.refresh_token ?? tokens.refreshToken)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private func post(_ provider: OAuthProvider, form: [String: String]) async throws -> TokenResponse {
        let (data, status) = try await http.post(provider.tokenEndpoint, form: form)
        guard (200..<300).contains(status) else {
            throw OAuthError.rejected(status: status, error: try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func tokens(from response: TokenResponse, provider: OAuthProvider.ID, refreshToken: String) -> OAuthTokens {
        OAuthTokens(
            provider: provider,
            accessToken: response.access_token,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(response.expires_in)
        )
    }

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { key in
            let value = form[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }
}

extension Credential {
    public func login(accountID: String, store: any CredentialStore, client: OAuthClient) -> MailLogin {
        switch self {
        case .password(let password):
            .password(password)
        case .oauth(let tokens):
            OAuthTokenSource(tokens: tokens, client: client) { fresh in
                try? store.save(.oauth(fresh), for: accountID)
            }.login
        }
    }
}

public actor OAuthTokenSource {
    private var tokens: OAuthTokens
    private let client: OAuthClient
    private let onRefresh: @Sendable (OAuthTokens) -> Void
    private var refreshing: Task<OAuthTokens, Error>?

    public init(tokens: OAuthTokens, client: OAuthClient, onRefresh: @escaping @Sendable (OAuthTokens) -> Void) {
        self.tokens = tokens
        self.client = client
        self.onRefresh = onRefresh
    }

    public nonisolated var login: MailLogin {
        .accessToken { try await self.accessToken() }
    }

    public func accessToken() async throws -> String {
        if tokens.expiresAt > client.now().addingTimeInterval(60) { return tokens.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { [client, tokens] in try await client.refresh(tokens) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        tokens = fresh
        onRefresh(fresh)
        return fresh.accessToken
    }
}
