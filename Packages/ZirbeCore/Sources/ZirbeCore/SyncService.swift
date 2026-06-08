// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The glue between the mail engine and the store. It fetches from the server,
// maps envelopes into domain messages, persists them, and recomputes threads.
// The UI never calls this directly for data; it reads the store, which this
// fills.

import Foundation
import ZirbeMail

/// Drives a sync for one account: fetch, store, rethread. Thin by design; the
/// engine owns the protocol and the store owns persistence.
public actor SyncService {
    private let account: Account
    private let store: MailStore
    private let engine: MailEngine

    public init(account: Account, store: MailStore) {
        self.account = account
        self.store = store
        self.engine = MailEngine(config: MailServerConfig(host: account.imapHost, port: account.imapPort))
    }

    /// Fetch the most recent `limit` messages from `mailbox`, persist them, and
    /// recompute conversations. Returns the resulting inbox summaries.
    ///
    /// The password is passed in per call and never stored on the service; it
    /// comes from the Keychain at the call site and is used only for the IMAP
    /// login over TLS.
    @discardableResult
    public func syncInbox(
        password: String,
        mailbox: String = "INBOX",
        limit: Int = 50
    ) async throws -> [ThreadSummary] {
        try await engine.connect()
        try await engine.login(username: account.username, password: password)
        let envelopes = try await engine.fetchRecentEnvelopes(in: mailbox, limit: limit)
        await engine.disconnect()

        try await store.upsert(account)
        try await store.upsert(Mailbox(accountID: account.id, name: mailbox, role: .inbox))
        try await store.save(envelopes.map(Message.init), accountID: account.id, mailboxName: mailbox)
        try await store.rethread(accountID: account.id)

        return try await store.threadSummaries(accountID: account.id)
    }
}
