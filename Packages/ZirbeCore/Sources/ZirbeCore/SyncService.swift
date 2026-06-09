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
    /// login over TLS. The engine keeps the connection warm between calls, so a
    /// later sync or conversation open reuses it rather than reconnecting.
    @discardableResult
    public func syncInbox(
        password: String,
        mailbox: String = "INBOX",
        limit: Int = 50
    ) async throws -> [ThreadSummary] {
        try await engine.connect(username: account.username, password: password)
        let envelopes = try await engine.fetchRecentEnvelopes(in: mailbox, limit: limit)

        try await store.upsert(account)
        try await store.upsert(Mailbox(accountID: account.id, name: mailbox, role: .inbox))
        try await store.save(envelopes.map(Message.init), accountID: account.id, mailboxName: mailbox)
        try await store.rethread(accountID: account.id)

        return try await store.threadSummaries(accountID: account.id)
    }

    /// Load a full conversation for display, fetching any message bodies that
    /// aren't cached yet and storing them. The first open pulls the text parts
    /// over the warm session (one mailbox select, one pipelined burst); later
    /// opens read straight from the store with no network. Returns nil if the
    /// thread is unknown.
    ///
    /// The password is per call for the same reason as `syncInbox`: it lives in
    /// the Keychain (M4) or the in-memory session, never on this service.
    public func loadConversation(id: String, password: String) async throws -> Thread? {
        let targets = try await store.messagesNeedingBodies(threadID: id)
        if !targets.isEmpty {
            try await engine.connect(username: account.username, password: password)
            var bodies: [String: String] = [:]
            for (mailbox, group) in Dictionary(grouping: targets, by: \.mailbox) {
                let fetched = try await engine.fetchTextBodies(
                    in: mailbox,
                    messages: group.map { (id: $0.id, uid: $0.uid) }
                )
                bodies.merge(fetched) { _, new in new }
            }
            try await store.storeBodies(bodies)
        }
        return try await store.thread(id: id)
    }

    /// Close the warm session and forget the password. Call on sign-out.
    public func disconnect() async {
        await engine.disconnect()
    }
}
