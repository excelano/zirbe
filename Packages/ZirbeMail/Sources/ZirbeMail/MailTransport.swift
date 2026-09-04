// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The transport seam. ZirbeCore's SyncService talks to the server through these
// two protocols rather than the concrete engine and sender, so everything above
// the store can run against an in-memory fake in tests. The real adapters,
// MailEngine and MailSender, conform below with no change to their behavior.
//
// The split mirrors the two connections: IMAP is a warm, stateful session that
// reads and files mail; SMTP is a per-send connection that only delivers. Each
// gets its own protocol so a test can fake one without the other, and so the
// send path's failure modes stay distinct from the read path's.

import Foundation

/// The IMAP side: the engine's public surface, one requirement per operation
/// SyncService performs. A conformer keeps its own session; `connect` is
/// idempotent and every other call assumes it has been made.
public protocol IMAPTransport: Sendable {
    func connect(username: String, password: String) async throws
    func fetchRecentEnvelopes(in mailbox: String, limit: Int) async throws -> [MailEnvelope]
    func mailboxState(in mailbox: String) async throws -> MailboxState
    func listMailboxes() async throws -> [MailboxInfo]
    func fetchTextBodies(in mailbox: String, messages: [(id: String, uid: UInt32)]) async throws -> [String: MessageBody]
    func fetchHTMLBody(in mailbox: String, uid: UInt32) async throws -> HTMLBody?
    func fetchAttachment(in mailbox: String, uid: UInt32, partID: String) async throws -> Data
    func saveToSent(_ outgoing: OutgoingMessage) async throws
    func saveToDrafts(_ outgoing: OutgoingMessage, replacing previousUID: UInt32?) async throws -> UInt32?
    func removeDraft(uid: UInt32) async throws
    func setSeen(_ seen: Bool, in mailbox: String, uids: [UInt32]) async throws
    func setFlagged(_ flagged: Bool, in mailbox: String, uids: [UInt32]) async throws
    func idleChanges(in mailbox: String) async throws -> AsyncStream<Void>
    func stopIdle() async
    func trash(in mailbox: String, uids: [UInt32]) async throws
    func move(in mailbox: String, uids: [UInt32], to destination: String) async throws
    func archive(in mailbox: String, uids: [UInt32]) async throws
    func markJunk(in mailbox: String, uids: [UInt32]) async throws
    func disconnect() async
}

/// The SMTP side: deliver one message. A throw means nothing was delivered.
public protocol SMTPTransport: Sendable {
    func send(_ outgoing: OutgoingMessage, username: String, password: String) async throws
}

extension MailEngine: IMAPTransport {}
extension MailSender: SMTPTransport {}
