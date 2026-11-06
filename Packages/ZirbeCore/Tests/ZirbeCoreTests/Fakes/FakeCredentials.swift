// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import Foundation
@testable import ZirbeCore

final class FakeCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: Credential]

    init(_ passwords: [String: String] = [:]) {
        self.credentials = passwords.mapValues { .password($0) }
    }

    var stored: [String: Credential] {
        lock.withLock { credentials }
    }

    func save(_ credential: Credential, for accountID: String) throws {
        lock.withLock { credentials[accountID] = credential }
    }

    func credential(for accountID: String) throws -> Credential? {
        lock.withLock { credentials[accountID] }
    }

    func delete(for accountID: String) throws {
        _ = lock.withLock { credentials.removeValue(forKey: accountID) }
    }
}
