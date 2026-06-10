// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The offline source of truth: a GRDB/SQLite store of accounts, mailboxes,
// messages, and threads. The network syncs into it; the UI only ever reads
// from it, so the app never blocks on a server. Threading is recomputed on
// each sync (cheap at this scale) and the result is persisted, so the inbox is
// a single ordered query rather than a graph walk.

import Foundation
import GRDB

// MARK: - Stored records

/// One persisted message row. JSON-backed columns (referenceIDs,
/// toParticipants, flags) are stored automatically by GRDB's Codable support.
struct MessageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    var id: String
    var accountID: String
    var mailboxName: String
    var uid: Int64?
    var messageID: String?
    var inReplyTo: String?
    var referenceIDs: [String]
    var subject: String?
    var fromAddress: String?
    var fromName: String?
    var toParticipants: [Participant]
    var ccParticipants: [Participant]
    var date: Date?
    var flags: [Flag]
    var bodyText: String?
    var threadID: String?

    init(_ message: Message, accountID: String, mailboxName: String) {
        self.id = message.id
        self.accountID = accountID
        self.mailboxName = mailboxName
        self.uid = message.uid.map(Int64.init)
        self.messageID = message.messageID
        self.inReplyTo = message.inReplyTo
        self.referenceIDs = message.references
        self.subject = message.subject
        self.fromAddress = message.from?.address
        self.fromName = message.from?.displayName
        self.toParticipants = message.to
        self.ccParticipants = message.cc
        self.date = message.date
        self.flags = Array(message.flags)
        self.bodyText = message.bodyText
        self.threadID = nil
    }

    var message: Message {
        Message(
            messageID: messageID,
            uid: uid.map { UInt32(truncatingIfNeeded: $0) },
            inReplyTo: inReplyTo,
            references: referenceIDs,
            subject: subject,
            from: fromAddress.map { Participant(address: $0, displayName: fromName) },
            to: toParticipants,
            cc: ccParticipants,
            date: date,
            flags: Set(flags),
            bodyText: bodyText
        )
    }
}

/// One persisted thread row, carrying everything the inbox list shows so the
/// list never has to load messages.
struct ThreadRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "thread"

    var id: String
    var accountID: String
    var subject: String
    var lastActivity: Date?
    var isUnread: Bool
    var messageCount: Int
    var participants: [Participant]

    init(_ thread: Thread, accountID: String) {
        self.id = thread.id
        self.accountID = accountID
        self.subject = thread.subject
        self.lastActivity = thread.lastActivity
        self.isUnread = thread.isUnread
        self.messageCount = thread.messageCount
        self.participants = thread.participants
    }

    var summary: ThreadSummary {
        ThreadSummary(
            id: id,
            subject: subject,
            participants: participants,
            lastActivity: lastActivity,
            isUnread: isUnread,
            messageCount: messageCount
        )
    }
}

/// One persisted mailbox row. Keyed by (accountID, name) since a folder name is
/// only unique within an account.
struct MailboxRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mailbox"

    var accountID: String
    var name: String
    var role: String?

    init(_ mailbox: Mailbox) {
        self.accountID = mailbox.accountID
        self.name = mailbox.name
        self.role = mailbox.role?.rawValue
    }
}

// Account persists as itself; its stored `id` is the primary key.
extension Account: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "account" }
}

// MARK: - Store

/// The mail store. Thread-safe; wraps a GRDB database and exposes an async API.
public final class MailStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    /// Open (or create) a store. Pass a file path for the app's persistent
    /// database, or omit it for an in-memory store (tests, previews).
    public init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: Writes

    public func upsert(_ account: Account) async throws {
        try await dbQueue.write { db in try account.save(db) }
    }

    public func upsert(_ mailbox: Mailbox) async throws {
        try await dbQueue.write { db in try MailboxRow(mailbox).save(db) }
    }

    /// Insert or update the given messages. Existing rows (matched by id) are
    /// refreshed, so re-fetching the same mail is idempotent. A re-synced header
    /// carries no body, so a body already cached for that message is preserved
    /// rather than nulled out.
    public func save(_ messages: [Message], accountID: String, mailboxName: String) async throws {
        try await dbQueue.write { db in
            for message in messages {
                var row = MessageRow(message, accountID: accountID, mailboxName: mailboxName)
                if row.bodyText == nil {
                    row.bodyText = try MessageRow.fetchOne(db, key: row.id)?.bodyText
                }
                try row.save(db)
            }
        }
    }

    /// Prune the cached messages for one mailbox down to what the server still
    /// holds: delete every row in (accountID, mailboxName) whose UID is not in
    /// `keepingUIDs`. Rows with no UID are left alone (a locally-composed Sent
    /// copy has none and is not the server's to delete), and the prune is scoped
    /// to the one mailbox so syncing INBOX never touches Sent. Returns the number
    /// of rows deleted. Call `rethread` after, so threads emptied by the prune
    /// drop out of the inbox.
    @discardableResult
    public func pruneMessages(accountID: String, mailboxName: String, keepingUIDs: Set<Int64>) async throws -> Int {
        try await dbQueue.write { db in
            let stale = try MessageRow
                .filter(Column("accountID") == accountID && Column("mailboxName") == mailboxName && Column("uid") != nil)
                .fetchAll(db)
                .filter { row in row.uid.map { !keepingUIDs.contains($0) } ?? false }
            for row in stale { try row.delete(db) }
            return stale.count
        }
    }

    /// Drop every cached message in one mailbox. Used when the server's
    /// UIDVALIDITY changes, which invalidates every UID we hold for it, so the
    /// cache must be rebuilt from scratch rather than reconciled.
    public func clearMessages(accountID: String, mailboxName: String) async throws {
        try await dbQueue.write { db in
            _ = try MessageRow
                .filter(Column("accountID") == accountID && Column("mailboxName") == mailboxName)
                .deleteAll(db)
        }
    }

    /// The UID-validity last recorded for a mailbox, or nil if none is stored yet
    /// (a mailbox never synced). Compared against the server's current value to
    /// decide whether the cache can be reconciled or must be rebuilt.
    public func uidValidity(accountID: String, mailboxName: String) async throws -> Int64? {
        try await dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT uidValidity FROM mailbox WHERE accountID = ? AND name = ?",
                arguments: [accountID, mailboxName]
            )
        }
    }

    /// Record the server's current UID-validity for a mailbox. The mailbox row
    /// must already exist (sync upserts it first); this only stamps the value,
    /// rather than going through `upsert(Mailbox)`, because the domain `Mailbox`
    /// type intentionally carries no IMAP bookkeeping.
    public func setUIDValidity(_ validity: Int64, accountID: String, mailboxName: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET uidValidity = ? WHERE accountID = ? AND name = ?",
                arguments: [validity, accountID, mailboxName]
            )
        }
    }

    /// Persist fetched text bodies, keyed by message id. Used by the lazy-body
    /// path when a conversation is opened, so the bodies are cached and the next
    /// open is offline.
    public func storeBodies(_ bodiesByMessageID: [String: String]) async throws {
        guard !bodiesByMessageID.isEmpty else { return }
        try await dbQueue.write { db in
            for (id, text) in bodiesByMessageID {
                try db.execute(
                    sql: "UPDATE message SET bodyText = ? WHERE id = ?",
                    arguments: [text, id]
                )
            }
        }
    }

    /// Recompute the conversation grouping for an account from all its stored
    /// messages and persist the result: rewrite the thread rows and stamp each
    /// message with its thread id. A full recompute is correct (a new message
    /// can bridge two previously separate threads) and fast at this scale.
    public func rethread(accountID: String) async throws {
        try await dbQueue.write { db in
            let rows = try MessageRow
                .filter(Column("accountID") == accountID)
                .fetchAll(db)
            let threads = Threader.thread(rows.map(\.message))

            try ThreadRow.filter(Column("accountID") == accountID).deleteAll(db)

            var threadByMessage: [String: String] = [:]
            for thread in threads {
                try ThreadRow(thread, accountID: accountID).insert(db)
                for message in thread.messages { threadByMessage[message.id] = thread.id }
            }
            for row in rows where row.threadID != threadByMessage[row.id] {
                try db.execute(
                    sql: "UPDATE message SET threadID = ? WHERE id = ?",
                    arguments: [threadByMessage[row.id], row.id]
                )
            }
        }
    }

    // MARK: Reads

    /// The inbox: thread summaries for an account, most recent activity first.
    public func threadSummaries(accountID: String) async throws -> [ThreadSummary] {
        try await dbQueue.read { db in
            try ThreadRow
                .filter(Column("accountID") == accountID)
                .order(Column("lastActivity").desc)
                .fetchAll(db)
                .map(\.summary)
        }
    }

    /// Messages in a thread that still need a body fetched: those with no cached
    /// body and a known server UID. Returns the row id (to cache the fetched
    /// text under), the UID to fetch, and the mailbox to select. An empty result
    /// means the conversation is fully cached and can be shown offline.
    public func messagesNeedingBodies(threadID: String) async throws -> [(id: String, uid: UInt32, mailbox: String)] {
        try await dbQueue.read { db in
            try MessageRow
                .filter(Column("threadID") == threadID && Column("bodyText") == nil && Column("uid") != nil)
                .fetchAll(db)
                .compactMap { row in
                    row.uid.map { (id: row.id, uid: UInt32(truncatingIfNeeded: $0), mailbox: row.mailboxName) }
                }
        }
    }

    /// A full conversation: the thread and its messages, oldest first.
    public func thread(id: String) async throws -> Thread? {
        try await dbQueue.read { db in
            guard let row = try ThreadRow.fetchOne(db, key: id) else { return nil }
            let messages = try MessageRow
                .filter(Column("threadID") == id)
                .fetchAll(db)
                .map(\.message)
                .chronological()
            return Thread(
                id: row.id,
                subject: row.subject,
                messages: messages,
                participants: row.participants,
                lastActivity: row.lastActivity
            )
        }
    }

    // MARK: Schema

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("emailAddress", .text).notNull()
                t.column("displayName", .text)
                t.column("imapHost", .text).notNull()
                t.column("imapPort", .integer).notNull()
                t.column("smtpHost", .text).notNull()
                t.column("smtpPort", .integer).notNull()
                t.column("username", .text).notNull()
            }
            try db.create(table: "mailbox") { t in
                t.column("accountID", .text).notNull()
                t.column("name", .text).notNull()
                t.column("role", .text)
                t.primaryKey(["accountID", "name"])
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull().indexed()
                t.column("mailboxName", .text).notNull()
                t.column("uid", .integer)
                t.column("messageID", .text)
                t.column("inReplyTo", .text)
                t.column("referenceIDs", .text).notNull()
                t.column("subject", .text)
                t.column("fromAddress", .text)
                t.column("fromName", .text)
                t.column("toParticipants", .text).notNull()
                t.column("date", .datetime)
                t.column("flags", .text).notNull()
                t.column("bodyText", .text)
                t.column("threadID", .text).indexed()
            }
            try db.create(table: "thread") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull().indexed()
                t.column("subject", .text).notNull()
                t.column("lastActivity", .datetime)
                t.column("isUnread", .boolean).notNull()
                t.column("messageCount", .integer).notNull()
                t.column("participants", .text).notNull()
            }
        }
        // Cc was added with reply-all (M3): a message now carries its Cc list so a
        // reply can preserve the original To/Cc split. Additive, with an empty-array
        // default so existing synced rows migrate without a re-fetch; a later sync
        // backfills the real Cc as it re-saves each header.
        migrator.registerMigration("v2-cc") { db in
            try db.alter(table: "message") { t in
                t.add(column: "ccParticipants", .text).notNull().defaults(to: "[]")
            }
        }
        // Sync reconciliation (M3+): a mailbox now remembers the server's
        // UIDVALIDITY so a later sync can tell a renumbered mailbox (rebuild the
        // cache) from a reconcilable one (prune deleted UIDs). Nullable: an
        // existing row predates the value and gets it on the next sync.
        migrator.registerMigration("v3-uidvalidity") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "uidValidity", .integer)
            }
        }
        return migrator
    }()
}
