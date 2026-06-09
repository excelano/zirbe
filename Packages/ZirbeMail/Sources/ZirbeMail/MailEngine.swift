// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The mail engine adapter. Wraps SwiftMail's IMAPServer and returns Zirbe-owned
// MailEnvelope values. Intentionally thin: SwiftMail does the protocol work.
//
// The engine keeps a warm, authenticated session: one TLS connection and login
// are reused across operations rather than paid per call. Credentials are held
// in memory only, for the life of the session, so a connection the server drops
// between operations can be transparently restored. Nothing is persisted.

import Foundation
import Logging
import SwiftMail

public enum MailEngineError: Error {
    /// An operation was attempted before `connect(username:password:)`.
    case notConnected
}

public actor MailEngine {
    private let server: IMAPServer
    private let logger: Logger
    /// The credentials of the current session, in memory only. Set by `connect`,
    /// cleared by `disconnect`; used to restore a dropped connection.
    private var credentials: (username: String, password: String)?
    /// Whether we hold a live, authenticated session. Reset when the socket dies.
    private var isLoggedIn = false
    /// The resolved Sent mailbox name, cached after the first lookup so saving a
    /// sent copy doesn't re-list the server's special-use mailboxes each time.
    private var sentMailboxName: String?

    public init(config: MailServerConfig, logger: Logger = Logger(label: "zirbe.mail")) {
        self.logger = logger
        self.server = IMAPServer(host: config.host, port: config.port)
    }

    /// Establish or reuse an authenticated session with these credentials.
    /// Idempotent: when a live session already exists this returns immediately
    /// without a new connection or login. The password is held in memory only so
    /// a dropped connection can be restored; it is never written to disk.
    public func connect(username: String, password: String) async throws {
        credentials = (username, password)
        try await ensureSession()
    }

    /// Selects `mailbox` and returns the envelopes of the most recent `limit`
    /// messages, newest last (server order).
    public func fetchRecentEnvelopes(in mailbox: String, limit: Int = 20) async throws -> [MailEnvelope] {
        try await perform {
            let selection = try await self.server.selectMailbox(mailbox)
            self.logger.debug("selected \(mailbox): \(selection.messageCount) message(s)")
            guard let identifiers = selection.latest(limit) else { return [] }
            let infos = try await self.server.fetchMessageInfosBulk(using: identifiers)
            return infos.map(MailEnvelope.init)
        }
    }

    /// Fetches the readable text bodies of several messages in one mailbox,
    /// reusing the warm session. Selects the mailbox once, reads each message's
    /// body structure, then downloads all the chosen text parts in a single
    /// pipelined burst rather than one round trip at a time. Returns the decoded
    /// text keyed by the caller's message id; a message with no text part (or one
    /// that fails to decode) is simply absent from the result.
    ///
    /// Only the text part is downloaded, never attachments. `text/plain` is
    /// preferred; a message that carries only `text/html` is reduced to plain
    /// text so a text-first bubble still has something to show.
    public func fetchTextBodies(
        in mailbox: String,
        messages: [(id: String, uid: UInt32)]
    ) async throws -> [String: String] {
        guard !messages.isEmpty else { return [:] }
        return try await perform {
            _ = try await self.server.selectMailbox(mailbox)

            // Pick the body part for each message from its (cheap) structure.
            var chosen: [(id: String, uid: UID, part: MessagePart)] = []
            for message in messages {
                let uid = UID(message.uid)
                let structure = try await self.server.fetchStructure(uid)
                if let part = Self.bodyPart(in: structure) {
                    chosen.append((message.id, uid, part))
                }
            }
            guard !chosen.isEmpty else { return [:] }

            // Download every chosen section in one pipelined burst.
            let requests = chosen.map { (uid: $0.uid, section: $0.part.section) }
            let fetched = try await self.server.fetchPartsPipelined(parts: requests)

            // Decode each, matching the pipelined results back by UID and section.
            var bodies: [String: String] = [:]
            for entry in chosen {
                guard let data = fetched[entry.uid]?.first(where: { $0.section == entry.part.section })?.data
                else { continue }
                var filled = entry.part
                filled.data = data
                guard let text = filled.textContent else { continue }
                bodies[entry.id] = entry.part.contentType.lowercased().hasPrefix("text/html")
                    ? Self.plainText(fromHTML: text)
                    : text
            }
            return bodies
        }
    }

    /// Save a copy of a just-sent message to the server's Sent mailbox, over the
    /// warm session, so it appears in other mail clients and survives a local
    /// rebuild. Flagged `\Seen` since the user wrote it. The same Message-ID as
    /// the SMTP send is carried through, so a retry that re-appends is the user's
    /// to avoid; this does not retry on a dropped connection (unlike the read
    /// path), because an APPEND that half-committed could otherwise be doubled.
    public func saveToSent(_ outgoing: OutgoingMessage) async throws {
        try await ensureSession()
        let mailbox = try await resolvedSentMailbox()
        try await server.append(email: Email(outgoing), to: mailbox, flags: [.seen])
    }

    /// Close the session and forget the credentials. Call on sign-out.
    public func disconnect() async {
        isLoggedIn = false
        credentials = nil
        sentMailboxName = nil
        try? await server.disconnect()
    }

    // MARK: - Session

    /// The server's Sent mailbox name, resolved once and cached. Lists the
    /// special-use mailboxes on first call (which also populates the general
    /// list, so the name-based fallback for a server without SPECIAL-USE works
    /// too), then reads the Sent folder.
    private func resolvedSentMailbox() async throws -> String {
        if let sentMailboxName { return sentMailboxName }
        try await server.listSpecialUseMailboxes()
        let name = try await server.sentFolder.name
        sentMailboxName = name
        return name
    }

    /// Ensure a live, authenticated session, reusing the existing one when it is
    /// still connected. Cheap and safe to call before every operation.
    private func ensureSession() async throws {
        guard let credentials else { throw MailEngineError.notConnected }
        if isLoggedIn, await server.isConnected { return }
        if await !server.isConnected {
            try await server.connect()
        }
        try await server.login(username: credentials.username, password: credentials.password)
        isLoggedIn = true
        logger.debug("session ready for \(credentials.username)")
    }

    /// Run an operation against the warm session. If the connection has died by
    /// the time the operation runs, restore it once and retry; other failures
    /// propagate unchanged. Operations here are reads, so a retry is safe.
    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        try await ensureSession()
        do {
            return try await operation()
        } catch {
            guard await !server.isConnected else { throw error }
            logger.debug("connection dropped mid-operation; restoring and retrying once")
            isLoggedIn = false
            try await ensureSession()
            return try await operation()
        }
    }

    // MARK: - Body part selection

    /// Picks the one part to render: the `text/plain` body, else the `text/html`
    /// body, skipping anything marked as an attachment.
    private static func bodyPart(in parts: [MessagePart]) -> MessagePart? {
        func body(_ type: String) -> MessagePart? {
            parts.first {
                $0.contentType.lowercased().hasPrefix(type) && $0.disposition?.lowercased() != "attachment"
            }
        }
        return body("text/plain") ?? body("text/html")
    }

    /// A deliberately crude HTML-to-text reduction for the html-only fallback:
    /// strip tags and collapse whitespace. Faithful HTML rendering is M6's job;
    /// this only keeps the bubble readable until then.
    private static func plainText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
