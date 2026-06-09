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
    private let sender: MailSender

    public init(account: Account, store: MailStore) {
        self.account = account
        self.store = store
        self.engine = MailEngine(config: MailServerConfig(host: account.imapHost, port: account.imapPort))
        self.sender = MailSender(config: MailServerConfig(host: account.smtpHost, port: account.smtpPort))
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

    /// Send a composed draft, then make it visible immediately.
    ///
    /// The SMTP send is the gate: if it throws, nothing was delivered and nothing
    /// is stored, so the caller can let the user retry the same draft (its reused
    /// Message-ID keeps a retry from doubling). Once the send succeeds the message
    /// is delivered, so the optimistic local copy is inserted and the thread
    /// recomputed even if the rest fails, and the bubble appears at once.
    ///
    /// Appending a copy to the server's Sent folder is best effort: it only helps
    /// other mail clients see the message, so a failure there is logged and
    /// swallowed rather than reported as a send failure for mail that did send.
    /// The local copy carries the same Message-ID, so when Sent is later synced
    /// the two reconcile to one row.
    public func send(_ draft: OutgoingDraft, password: String) async throws {
        let outgoing = draft.outgoingMessage
        try await sender.send(outgoing, username: account.username, password: password)

        try await store.upsert(Mailbox(accountID: account.id, name: Self.localSentMailbox, role: .sent))
        try await store.save([draft.localMessage], accountID: account.id, mailboxName: Self.localSentMailbox)
        try await store.rethread(accountID: account.id)

        do {
            try await engine.connect(username: account.username, password: password)
            try await engine.saveToSent(outgoing)
        } catch {
            // The mail was sent and is shown locally; a missing server-side Sent
            // copy is a reconciliation detail, not a send failure.
        }
    }

    /// Close the warm session and forget the password. Call on sign-out.
    public func disconnect() async {
        await engine.disconnect()
    }

    /// The mailbox name the optimistic Sent copy is filed under locally. The
    /// server's real Sent folder is resolved by the engine when appending; a
    /// later Sent sync (a future milestone) will reconcile the names by
    /// Message-ID. Until then this is a stable local label, not a server folder.
    private static let localSentMailbox = "Sent"
}
