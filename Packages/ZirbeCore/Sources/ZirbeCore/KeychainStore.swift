// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Device-bound credential storage. The app-specific password for an account is
// kept in the Keychain, keyed by the account id, so a returning user lands in
// the inbox without retyping it. The accessibility class is deliberately
// `...ThisDeviceOnly`: the secret never syncs to iCloud Keychain and never
// migrates to another device in a backup restore, which is the privacy posture
// Zirbe inherits — credentials are bound to the device that obtained them.

import Foundation
import Security

/// A thin wrapper over the Keychain for one secret per account. Stateless; all
/// methods key on the account id (the lowercased email).
public enum KeychainStore {
    /// The Keychain service all Zirbe credentials live under.
    private static let service = "com.excelano.zirbe"

    /// Errors from the underlying Keychain calls, carrying the `OSStatus` so an
    /// unexpected failure is at least legible.
    public enum KeychainError: Error {
        case unexpected(OSStatus)
    }

    /// Store (or replace) the password for an account. The item is written
    /// `AfterFirstUnlock` so a future background refresh can still read it once
    /// the device has been unlocked since boot, but `ThisDeviceOnly` so it never
    /// leaves this device. Synchronizable is left off (no iCloud Keychain).
    public static func save(password: String, for accountID: String) throws {
        let data = Data(password.utf8)
        // Replace any existing item: delete then add keeps this idempotent
        // without a read-modify-write race.
        try? delete(for: accountID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    /// The stored password for an account, or nil if none is held. A missing
    /// item is not an error; any other failure is.
    public static func password(for accountID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpected(status)
        }
    }

    /// Remove the stored password for an account. A missing item is a no-op.
    public static func delete(for accountID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }
}
