// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import Foundation
@testable import ZirbeCore

final class FakeCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String]

    init(_ passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    var stored: [String: String] {
        lock.withLock { passwords }
    }

    func save(password: String, for accountID: String) throws {
        lock.withLock { passwords[accountID] = password }
    }

    func password(for accountID: String) throws -> String? {
        lock.withLock { passwords[accountID] }
    }

    func delete(for accountID: String) throws {
        _ = lock.withLock { passwords.removeValue(forKey: accountID) }
    }
}
