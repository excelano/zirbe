// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Device-bound credential storage. An account's app-specific password or OAuth
// tokens are kept in the Keychain, keyed by the account id, so a returning user lands in
// the inbox without retyping it. The accessibility class is deliberately
// `...ThisDeviceOnly`: the secret never syncs to iCloud Keychain and never
// migrates to another device in a backup restore, which is the privacy posture
// Zirbe inherits — credentials are bound to the device that obtained them.

import Foundation
import Security

public enum Credential: Sendable, Equatable {
    case password(String)
    case oauth(OAuthTokens)
}

public protocol CredentialStore: Sendable {
    func save(_ credential: Credential, for accountID: String) throws
    func credential(for accountID: String) throws -> Credential?
    func delete(for accountID: String) throws
}

/// A thin wrapper over the Keychain for one secret per account. Stateless; all
/// methods key on the account id (the lowercased email).
public struct KeychainStore: CredentialStore {
    public init() {}

    /// The Keychain service all Zirbe credentials live under.
    private static let service = "com.excelano.zirbe"
    private static let oauthService = "com.excelano.zirbe.oauth"

    /// Errors from the underlying Keychain calls, carrying the `OSStatus` so an
    /// unexpected failure is at least legible.
    public enum KeychainError: Error {
        case unexpected(OSStatus)
    }

    public func save(_ credential: Credential, for accountID: String) throws {
        try delete(for: accountID)
        switch credential {
        case .password(let password):
            try write(Data(password.utf8), service: Self.service, account: accountID)
        case .oauth(let tokens):
            try write(JSONEncoder().encode(tokens), service: Self.oauthService, account: accountID)
        }
    }

    public func credential(for accountID: String) throws -> Credential? {
        if let data = try read(service: Self.oauthService, account: accountID) {
            return .oauth(try JSONDecoder().decode(OAuthTokens.self, from: data))
        }
        return try read(service: Self.service, account: accountID).map { .password(String(decoding: $0, as: UTF8.self)) }
    }

    public func delete(for accountID: String) throws {
        try remove(service: Self.service, account: accountID)
        try remove(service: Self.oauthService, account: accountID)
    }

    /// The item is written `AfterFirstUnlock` so a background refresh can still
    /// read it once the device has been unlocked since boot, but `ThisDeviceOnly`
    /// so it never leaves this device. Synchronizable is left off (no iCloud
    /// Keychain).
    private func write(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    private func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpected(status)
        }
    }

    private func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }
}
