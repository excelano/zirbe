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
    var hasHTML: Bool
    var attachments: [MessageAttachment]
    var threadID: String?
    /// Delivery state, persisted so a failed-to-send bubble survives a relaunch.
    /// Stored as the `SendState` raw value; defaults to `sent` for every row that
    /// predates the column and every message that came from the server.
    var sendState: String
    /// A reaction emoji when this message is a tapback rather than a chat message,
    /// else nil. Persisted so a received or sent reaction shows as a badge without
    /// re-reading the header, and so the unread and notification queries can filter
    /// reactions out at the database.
    var reaction: String?

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
        self.hasHTML = message.hasHTML
        self.attachments = message.attachments
        self.threadID = nil
        self.sendState = message.sendState.rawValue
        self.reaction = message.reaction
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
            bodyText: bodyText,
            hasHTML: hasHTML,
            attachments: attachments,
            sendState: SendState(rawValue: sendState) ?? .sent,
            reaction: reaction
        )
    }
}

/// A two-column projection of `message` for the unread-count read: just the
/// mailbox and the flags JSON, so counting unseen mail never decodes a full
/// `MessageRow` (body text, participant and attachment blobs). GRDB decodes the
/// `flags` column the same way `MessageRow` does.
private struct UnreadProbe: Decodable, FetchableRecord {
    var mailboxName: String
    var flags: [Flag]
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
    var isFlagged: Bool
    var messageCount: Int
    var participants: [Participant]
    /// A one-line preview of the thread's newest message, computed from its
    /// cached body so the inbox list reads it directly without parsing per row.
    /// Recomputed on every rethread; nil until that body is fetched.
    var snippet: String?

    init(_ thread: Thread, accountID: String) {
        self.id = thread.id
        self.accountID = accountID
        self.subject = thread.subject
        self.lastActivity = thread.lastActivity
        self.isUnread = thread.isUnread
        self.isFlagged = thread.isFlagged
        self.messageCount = thread.messageCount
        self.participants = thread.participants
        // The preview is the newest chat message, never a reaction: a tapback
        // shouldn't become the inbox row's glance.
        let latest = thread.conversationMessages.max {
            ($0.date ?? .distantPast) < ($1.date ?? .distantPast)
        }
        let glance = latest?.bodyText.map { QuotedText.snippet($0) } ?? ""
        self.snippet = glance.isEmpty ? nil : glance
    }

    var summary: ThreadSummary {
        ThreadSummary(
            id: id,
            subject: subject,
            participants: participants,
            lastActivity: lastActivity,
            isUnread: isUnread,
            isFlagged: isFlagged,
            messageCount: messageCount,
            preview: snippet
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
    var hierarchyDelimiter: String?

    init(_ mailbox: Mailbox) {
        self.accountID = mailbox.accountID
        self.name = mailbox.name
        self.role = mailbox.role?.rawValue
        self.hierarchyDelimiter = mailbox.hierarchyDelimiter
    }

    var mailbox: Mailbox {
        Mailbox(
            accountID: accountID,
            name: name,
            role: role.flatMap(MailboxRole.init(rawValue:)),
            hierarchyDelimiter: hierarchyDelimiter
        )
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

    /// Every persisted account, for restoring a session on launch. Today there
    /// is at most one; returning a list keeps the door open for multiple.
    public func accounts() async throws -> [Account] {
        try await dbQueue.read { db in try Account.fetchAll(db) }
    }

    /// Every folder discovered for an account, for the mailbox switcher. Returns
    /// the cached rows only; an unvisited folder is still listed (folder discovery
    /// upserts every name) even before its messages are synced. Names sort
    /// alphabetically here; role-based ordering ("Inbox" first) is the UI's job.
    public func mailboxes(accountID: String) async throws -> [Mailbox] {
        try await dbQueue.read { db in
            try MailboxRow
                .filter(Column("accountID") == accountID)
                .order(Column("name"))
                .fetchAll(db)
                .map(\.mailbox)
        }
    }

    /// Wipe the whole store back to an empty, migrated state. Used on sign-out,
    /// where the privacy posture calls for leaving no cached mail behind.
    public func eraseAll() async throws {
        try await dbQueue.erase()
        try Self.migrator.migrate(dbQueue)
    }

    public func upsert(_ mailbox: Mailbox) async throws {
        try await dbQueue.write { db in try MailboxRow(mailbox).save(db) }
    }

    /// Insert or update the given messages. Existing rows (matched by id) are
    /// refreshed, so re-fetching the same mail is idempotent. A re-synced header
    /// carries no body, so a body already cached for that message (its text, its
    /// `hasHTML` flag, and its attachments, all set together when the body was
    /// fetched) is preserved rather than reset.
    public func save(_ messages: [Message], accountID: String, mailboxName: String) async throws {
        try await dbQueue.write { db in
            for message in messages {
                var row = MessageRow(message, accountID: accountID, mailboxName: mailboxName)
                if row.bodyText == nil, let existing = try MessageRow.fetchOne(db, key: row.id) {
                    row.bodyText = existing.bodyText
                    row.hasHTML = existing.hasHTML
                    row.attachments = existing.attachments
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
            // Read only id + uid to decide what's stale, so a prune (every sync)
            // never decodes bodyText or the JSON blobs of rows it's just testing.
            // The keep-set can be large, so the membership test stays in Swift;
            // only the small stale set is bound into the delete.
            let candidates = try Row.fetchAll(
                db,
                sql: "SELECT id, uid FROM message WHERE accountID = ? AND mailboxName = ? AND uid IS NOT NULL",
                arguments: [accountID, mailboxName]
            )
            let staleIDs = candidates.compactMap { row -> String? in
                keepingUIDs.contains(row["uid"] as Int64) ? nil : row["id"]
            }
            guard !staleIDs.isEmpty else { return 0 }
            try MessageRow.filter(staleIDs.contains(Column("id"))).deleteAll(db)
            return staleIDs.count
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

    /// The server references (UID and mailbox) of a thread's messages that have a
    /// UID, so the sync can mark or move them on the server. A locally-composed
    /// copy with no UID is omitted; it has nothing to act on server-side.
    public func messageRefs(threadID: String) async throws -> [(uid: UInt32, mailbox: String)] {
        try await dbQueue.read { db in
            try MessageRow
                .filter(Column("threadID") == threadID && Column("uid") != nil)
                .fetchAll(db)
                .compactMap { row in row.uid.map { (uid: UInt32(truncatingIfNeeded: $0), mailbox: row.mailboxName) } }
        }
    }

    /// Set or clear the `\Seen` flag on every message in a thread, locally. The
    /// caller rethreads after, so the thread's unread state (derived from its
    /// messages) updates. The server is told separately by the sync.
    public func setSeen(_ seen: Bool, threadID: String) async throws {
        try await dbQueue.write { db in
            let rows = try MessageRow.filter(Column("threadID") == threadID).fetchAll(db)
            for var row in rows {
                var flags = Set(row.flags)
                if seen { flags.insert(.seen) } else { flags.remove(.seen) }
                row.flags = Array(flags)
                try row.save(db)
            }
        }
    }

    /// Set or clear the `\Flagged` flag on every message in a thread, locally.
    /// The caller rethreads after, so the thread's flagged state (derived from
    /// its messages) updates. The server is told separately by the sync.
    public func setFlagged(_ flagged: Bool, threadID: String) async throws {
        try await dbQueue.write { db in
            let rows = try MessageRow.filter(Column("threadID") == threadID).fetchAll(db)
            for var row in rows {
                var flags = Set(row.flags)
                if flagged { flags.insert(.flagged) } else { flags.remove(.flagged) }
                row.flags = Array(flags)
                try row.save(db)
            }
        }
    }

    /// Pin or unpin a conversation. Purely local, keyed by thread id within the
    /// account: a row present means pinned. The reads sort pinned threads to the
    /// top. Survives a rethread (which the thread rows don't), since this table is
    /// keyed by the stable thread id rather than rebuilt from messages.
    public func setPinned(_ pinned: Bool, threadID: String, accountID: String) async throws {
        try await dbQueue.write { db in
            if pinned {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO pinnedThread (accountID, threadID) VALUES (?, ?)",
                    arguments: [accountID, threadID]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM pinnedThread WHERE accountID = ? AND threadID = ?",
                    arguments: [accountID, threadID]
                )
            }
        }
    }

    /// Delete every message in a thread, locally. Used when a conversation is
    /// trashed: after the server move, the local copies go too. The caller
    /// rethreads after, which drops the now-empty thread from the inbox.
    public func deleteThread(threadID: String) async throws {
        try await dbQueue.write { db in
            _ = try MessageRow.filter(Column("threadID") == threadID).deleteAll(db)
        }
    }

    /// Delete specific messages by id, locally. Used after the sync moves a
    /// blocked sender's INBOX mail to Junk on the server: the local copies go
    /// too, so blocked mail leaves the inbox. The caller rethreads after.
    public func deleteMessages(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await dbQueue.write { db in
            _ = try MessageRow.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    /// Block or unblock a sender for an account: a row present means the address
    /// is blocked. Purely local app state, keyed by the normalized (lowercased)
    /// address within the account. The sync consults it to auto-junk that
    /// sender's INBOX mail. Survives a rethread, since it hangs off the address
    /// rather than a message or thread row.
    public func setBlocked(_ blocked: Bool, address: String, accountID: String) async throws {
        let normalized = address.lowercased()
        try await dbQueue.write { db in
            if blocked {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO blockedSender (accountID, address) VALUES (?, ?)",
                    arguments: [accountID, normalized]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM blockedSender WHERE accountID = ? AND address = ?",
                    arguments: [accountID, normalized]
                )
            }
        }
    }

    /// The blocked sender addresses for an account, normalized and sorted, for
    /// the management list. Empty when nothing is blocked.
    public func blockedSenders(accountID: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT address FROM blockedSender WHERE accountID = ? ORDER BY address",
                arguments: [accountID]
            )
        }
    }

    /// The server references (id and UID) of the account's INBOX messages whose
    /// sender is blocked, so the sync can move them to Junk and then drop the
    /// local copies. Address matching is case-insensitive, mirroring how the
    /// blocklist is stored normalized. A locally-composed copy with no UID is
    /// omitted; it has nothing to act on server-side.
    public func blockedInboxRefs(accountID: String) async throws -> [(id: String, uid: UInt32)] {
        try await dbQueue.read { db in
            let blocked = try String.fetchAll(
                db,
                sql: "SELECT address FROM blockedSender WHERE accountID = ?",
                arguments: [accountID]
            )
            guard !blocked.isEmpty else { return [] }
            // Filter to blocked senders in SQL and read only id + uid, so the INBOX
            // isn't fully decoded every sync just to find a handful of blocked
            // rows. Addresses are stored normalized, so a lowercased column match
            // is exact; the blocklist is small, so the IN list is well within
            // SQLite's parameter limit.
            let placeholders = databaseQuestionMarks(count: blocked.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, uid FROM message
                WHERE accountID = ? AND mailboxName = ? AND uid IS NOT NULL
                  AND LOWER(fromAddress) IN (\(placeholders))
                """, arguments: StatementArguments([accountID, Self.inboxMailbox] + blocked))
            return rows.map { (id: $0["id"], uid: UInt32(truncatingIfNeeded: $0["uid"] as Int64)) }
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

    /// Advance the new-mail notification high-water mark to the highest INBOX UID
    /// now cached, marking everything up to it as "already known". Called after
    /// every sync the user is present for (a foreground refresh or the IDLE watch)
    /// and after the background poll has read its new arrivals, so a later poll
    /// only notifies for UIDs above this. Seeds to the current top on the first
    /// sync, so a freshly connected account doesn't notify for its whole inbox.
    public func markNotificationWatermark(accountID: String) async throws {
        try await dbQueue.write { db in
            let maxUID = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(uid) FROM message WHERE accountID = ? AND mailboxName = ?",
                arguments: [accountID, Self.inboxMailbox]
            ) ?? 0
            try db.execute(sql: """
                INSERT INTO syncState (accountID, lastNotifiedUID) VALUES (?, ?)
                ON CONFLICT(accountID) DO UPDATE SET lastNotifiedUID = excluded.lastNotifiedUID
                """, arguments: [accountID, maxUID])
        }
    }


    /// Persist fetched bodies, keyed by message id: the display text, whether an
    /// HTML version exists, and the user-facing attachments. Used by the lazy-body
    /// path when a conversation is opened, so the bodies are cached and the next
    /// open is offline. Attachments are stored as JSON in the same row, matching
    /// how `MessageRow` reads them back.
    public func storeBodies(_ bodiesByMessageID: [String: (text: String, hasHTML: Bool, attachments: [MessageAttachment])]) async throws {
        guard !bodiesByMessageID.isEmpty else { return }
        let encoder = JSONEncoder()
        try await dbQueue.write { db in
            for (id, body) in bodiesByMessageID {
                let attachmentsJSON = String(decoding: try encoder.encode(body.attachments), as: UTF8.self)
                try db.execute(
                    sql: "UPDATE message SET bodyText = ?, hasHTML = ?, attachments = ? WHERE id = ?",
                    arguments: [body.text, body.hasHTML, attachmentsJSON, id]
                )
            }
        }
    }

    /// The server reference (UID and mailbox) of one message, for the lazy Web
    /// View fetch. Nil when the message is unknown or has no UID (a purely local
    /// copy, which has no server-side HTML to open).
    public func messageRef(id: String) async throws -> (uid: UInt32, mailbox: String)? {
        try await dbQueue.read { db in
            guard let row = try MessageRow.fetchOne(db, key: id), let uid = row.uid else { return nil }
            return (uid: UInt32(truncatingIfNeeded: uid), mailbox: row.mailboxName)
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
            // A thread's id is its root Message-ID, which changes when a late-
            // arriving earlier ancestor re-roots the tree. Track the old→new id of
            // each re-rooted thread (a changed row still carries its prior thread id
            // here) so local-only state keyed by thread id can be moved with it.
            var oldToNew: [String: String] = [:]
            for row in rows where row.threadID != threadByMessage[row.id] {
                let newID = threadByMessage[row.id]
                try db.execute(
                    sql: "UPDATE message SET threadID = ? WHERE id = ?",
                    arguments: [newID, row.id]
                )
                if let old = row.threadID, let newID { oldToNew[old] = newID }
            }
            // Follow pins across the re-root, so a pinned conversation keeps its pin
            // instead of silently dropping out of the pinned group. Nothing else is
            // keyed by thread id (read/flag/reaction ride on message rows).
            try Self.repin(across: oldToNew, in: db, accountID: accountID)
        }
    }

    /// Rewrite `pinnedThread` rows whose thread id changed in a rethread, moving
    /// each pin from the old id to the new one. A no-op when nothing re-rooted.
    private static func repin(across oldToNew: [String: String], in db: Database, accountID: String) throws {
        guard !oldToNew.isEmpty else { return }
        let pinned = try String.fetchAll(
            db,
            sql: "SELECT threadID FROM pinnedThread WHERE accountID = ?",
            arguments: [accountID]
        )
        for old in pinned {
            guard let new = oldToNew[old], new != old else { continue }
            try db.execute(
                sql: "DELETE FROM pinnedThread WHERE accountID = ? AND threadID = ?",
                arguments: [accountID, old]
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO pinnedThread (accountID, threadID) VALUES (?, ?)",
                arguments: [accountID, new]
            )
        }
    }

    // MARK: Reads

    /// The inbox: thread summaries for an account, pinned conversations first and
    /// the rest by most recent activity.
    public func threadSummaries(accountID: String) async throws -> [ThreadSummary] {
        try await dbQueue.read { db in
            let rows = try ThreadRow.filter(Column("accountID") == accountID).fetchAll(db)
            return try Self.ordered(rows, pinnedIn: db, accountID: accountID)
        }
    }

    /// One folder's view: the thread summaries of every conversation that has a
    /// message filed in `mailboxName`, most recent activity first. Threading stays
    /// on, so a conversation that spans folders (a reply you sent now also living
    /// in Sent) appears in each folder it touches, carrying its whole thread. The
    /// inbox home view passes `INBOX` here, so it shows every INBOX conversation
    /// (the Messages-style list) without pulling in junk-only or sent-only threads.
    public func threadSummaries(accountID: String, mailboxName: String) async throws -> [ThreadSummary] {
        try await dbQueue.read { db in
            let threadIDs = try String.fetchSet(db, sql: """
                SELECT DISTINCT threadID FROM message
                WHERE accountID = ? AND mailboxName = ? AND threadID IS NOT NULL
                """, arguments: [accountID, mailboxName])
            guard !threadIDs.isEmpty else { return [] }
            let rows = try ThreadRow
                .filter(Column("accountID") == accountID && threadIDs.contains(Column("id")))
                .fetchAll(db)
            return try Self.ordered(rows, pinnedIn: db, accountID: accountID)
        }
    }

    /// Turn thread rows into summaries, marking the pinned ones from the
    /// `pinnedThread` table and sorting pinned conversations to the top, each group
    /// by most recent activity. Shared by the inbox and per-folder reads so both
    /// order the same way. Search results are ordered separately (by recency), so
    /// they don't route through here.
    private static func ordered(_ rows: [ThreadRow], pinnedIn db: Database, accountID: String) throws -> [ThreadSummary] {
        let pinned = try String.fetchSet(
            db,
            sql: "SELECT threadID FROM pinnedThread WHERE accountID = ?",
            arguments: [accountID]
        )
        return rows
            .map { row -> ThreadSummary in
                var summary = row.summary
                summary.isPinned = pinned.contains(row.id)
                return summary
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
            }
    }

    /// The unread message count of each folder, keyed by mailbox name, for the
    /// folder switcher's badges. Counted from the local cache (a message is unread
    /// when it lacks `\Seen`), so it reflects only what has been synced: an
    /// unvisited folder has no cached messages and so reports no count. This is the
    /// deliberate stand-in for a per-folder STATUS round trip, which the lazy-sync
    /// model avoids; a folder's count becomes exact once it has been opened once.
    public func unreadCounts(accountID: String) async throws -> [String: Int] {
        try await dbQueue.read { db in
            // Only the two columns the count needs, so the full row — the KB-scale
            // `bodyText` and the JSON participant/attachment blobs — is never
            // decoded. This runs after every sync, every IDLE tick, and every
            // mutation, so keeping the read narrow matters. Reactions are excluded
            // in SQL so they never bold a folder; unseen is decided from the small
            // flags JSON rather than a fragile `LIKE`.
            let rows = try UnreadProbe.fetchAll(
                db,
                sql: "SELECT mailboxName, flags FROM message WHERE accountID = ? AND reaction IS NULL",
                arguments: [accountID]
            )
            var counts: [String: Int] = [:]
            for row in rows where !row.flags.contains(.seen) {
                counts[row.mailboxName, default: 0] += 1
            }
            return counts
        }
    }

    /// The INBOX arrivals not yet surfaced as a notification: unseen messages with
    /// a server UID above the stored high-water mark, oldest first. The background
    /// poll reads these, posts for them, then advances the mark
    /// (`markNotificationWatermark`). Scoped to INBOX and to unseen mail, so a
    /// message already read elsewhere, or one re-fetched below the mark, never
    /// re-notifies. Empty when nothing new has landed since the last sync.
    public func unnotifiedInboxArrivals(accountID: String) async throws -> [NewMailItem] {
        try await dbQueue.read { db in
            let watermark = try Int64.fetchOne(
                db,
                sql: "SELECT lastNotifiedUID FROM syncState WHERE accountID = ?",
                arguments: [accountID]
            ) ?? 0
            return try MessageRow
                .filter(Column("accountID") == accountID
                    && Column("mailboxName") == Self.inboxMailbox
                    && Column("uid") != nil
                    && Column("uid") > watermark
                    && Column("reaction") == nil)
                .order(Column("uid"))
                .fetchAll(db)
                .filter { !$0.flags.contains(.seen) }
                .map { row in
                    NewMailItem(
                        threadID: row.threadID,
                        senderName: row.fromName,
                        senderAddress: row.fromAddress,
                        subject: row.subject
                    )
                }
        }
    }

    /// Conversations matching a free-text query, most recent activity first.
    /// Local-only over the store, so it is instant and works offline. A thread
    /// matches when any of its messages matches `query` (case-insensitive
    /// substring) in its subject, its sender (name or address), its recipients,
    /// or its cached body text. Subject and participants are always searchable;
    /// body text only once it has been fetched (it caches when a conversation is
    /// opened, and each thread's newest message is backfilled for the inbox
    /// preview), so body matches are best-effort over what has been downloaded.
    /// An empty query returns nothing.
    public func searchThreads(accountID: String, query: String) async throws -> [ThreadSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(Self.escapedForLike(trimmed))%"
        return try await dbQueue.read { db in
            // Find the threads of any matching message, then load those rows. The
            // `\` escape lets a literal % or _ in the query match itself rather
            // than act as a wildcard.
            let threadIDs = try String.fetchSet(db, sql: """
                SELECT DISTINCT threadID FROM message
                WHERE accountID = :acct AND threadID IS NOT NULL AND (
                    subject LIKE :p ESCAPE '\\' OR
                    fromName LIKE :p ESCAPE '\\' OR
                    fromAddress LIKE :p ESCAPE '\\' OR
                    bodyText LIKE :p ESCAPE '\\' OR
                    toParticipants LIKE :p ESCAPE '\\' OR
                    ccParticipants LIKE :p ESCAPE '\\'
                )
                """, arguments: ["acct": accountID, "p": pattern])
            guard !threadIDs.isEmpty else { return [] }
            return try ThreadRow
                .filter(Column("accountID") == accountID && threadIDs.contains(Column("id")))
                .order(Column("lastActivity").desc)
                .fetchAll(db)
                .map(\.summary)
        }
    }

    /// Escape a user's search text so its `%` and `_` match literally under a
    /// `LIKE … ESCAPE '\'`. The backslash itself is escaped first so it can't
    /// swallow a following character.
    private static func escapedForLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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

    /// The latest message of each thread that still lacks a cached body but has a
    /// server UID, so a sync can fetch just those to fill the inbox preview
    /// snippets. At most one row per thread (the most recent), keeping the extra
    /// fetch proportional to the thread count rather than the message count, and
    /// skipping threads whose newest message is already cached.
    public func latestMessagesNeedingBodies(accountID: String) async throws -> [(id: String, uid: UInt32, mailbox: String)] {
        try await dbQueue.read { db in
            // Only the columns needed to pick each thread's newest chat message and
            // see whether its body is cached, so this per-sync scan never decodes
            // the bodyText or JSON blobs of every message. `bodyText IS NULL` comes
            // back as the needs-body flag. Reactions are excluded so the "latest"
            // is the newest chat message (the inbox preview), never a tapback.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, uid, mailboxName, date, threadID, (bodyText IS NULL) AS needsBody
                FROM message
                WHERE accountID = ? AND threadID IS NOT NULL AND reaction IS NULL
                """, arguments: [accountID])
            return Dictionary(grouping: rows, by: { $0["threadID"] as String })
                .compactMap { _, group -> (id: String, uid: UInt32, mailbox: String)? in
                    guard let latest = group.max(by: {
                        (($0["date"] as Date?) ?? .distantPast) < (($1["date"] as Date?) ?? .distantPast)
                    }) else { return nil }
                    guard (latest["needsBody"] as Int) != 0, let uid = latest["uid"] as Int64? else { return nil }
                    return (id: latest["id"], uid: UInt32(truncatingIfNeeded: uid), mailbox: latest["mailboxName"])
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
        // HTML Web View (M3+): a message remembers whether it carries an HTML
        // alternative, so the conversation view can offer to open it as a web
        // page. Set when the body is fetched; defaults false, so a row
        // synced before this (or never opened) reads as plain until its body
        // loads and stamps the real value.
        migrator.registerMigration("v4-hashtml") { db in
            try db.alter(table: "message") { t in
                t.add(column: "hasHTML", .boolean).notNull().defaults(to: false)
            }
        }
        // Inbox preview snippets: a thread now caches a one-line glance of its
        // newest message for the list row. Nullable and recomputed on every
        // rethread (which rewrites the thread rows wholesale), so existing rows
        // get a snippet on the next sync as their latest body is backfilled.
        migrator.registerMigration("v5-thread-snippet") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "snippet", .text)
            }
        }
        // Attachment chips: a message now caches its user-facing attachments
        // (names and MIME types, as JSON) alongside its body, so the conversation
        // bubble can list them. Defaults to an empty array, so a row synced before
        // this (or never opened) reads as no attachments until its body loads and
        // stamps the real list.
        migrator.registerMigration("v6-message-attachments") { db in
            try db.alter(table: "message") { t in
                t.add(column: "attachments", .text).notNull().defaults(to: "[]")
            }
        }
        // Openable attachments: a chip now carries the MIME part id its bytes are
        // fetched by. Chips cached before this carry none and so can't be opened;
        // clear the cached body of any message that has them so the next open
        // re-fetches and re-extracts the attachments with their part ids. Bodies
        // with no attachments are untouched. Pre-release data only.
        migrator.registerMigration("v7-attachment-partid") { db in
            try db.execute(sql: "UPDATE message SET bodyText = NULL, attachments = '[]' WHERE attachments <> '[]'")
        }
        // Attachment extraction was corrected to drop the trailing inline-text
        // segment a multipart/mixed wraps around a file (Apple Mail's inline-
        // attachment layout), which had leaked as a phantom chip. Clear the cached
        // body of any message that has chips so the corrected extraction re-runs on
        // the next open. Same shape as v7; pre-release data only.
        migrator.registerMigration("v8-reextract-attachments") { db in
            try db.execute(sql: "UPDATE message SET bodyText = NULL, attachments = '[]' WHERE attachments <> '[]'")
        }
        // Flag and star (the `\Flagged` triage marker): the thread row now carries
        // its flagged state, derived from its messages, so the inbox list reads it
        // without loading them. Additive with a false default; the next rethread
        // (the thread table is rewritten wholesale) stamps the real value from the
        // messages' flags.
        migrator.registerMigration("v9-thread-flagged") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "isFlagged", .boolean).notNull().defaults(to: false)
            }
        }
        // Local new-mail notifications: a per-account high-water mark of the
        // highest INBOX UID already surfaced (seen in the foreground or notified),
        // so the background poll notifies only for newer arrivals. Wiped with the
        // rest on sign-out, since `eraseAll` re-runs this migrator from empty.
        migrator.registerMigration("v10-sync-state") { db in
            try db.create(table: "syncState") { t in
                t.primaryKey("accountID", .text)
                t.column("lastNotifiedUID", .integer).notNull().defaults(to: 0)
            }
        }
        // Failed-send state: a locally-composed reply whose SMTP send threw is
        // kept in the conversation as an undelivered bubble. Additive with a
        // `sent` default, so every existing row and every server-synced message
        // reads as delivered; only a failed local copy is ever written `failed`.
        migrator.registerMigration("v11-message-send-state") { db in
            try db.alter(table: "message") { t in
                t.add(column: "sendState", .text).notNull().defaults(to: "sent")
            }
        }
        // A folder now remembers the server's hierarchy delimiter so its display
        // name can be flattened to the leaf using the real separator rather than a
        // guess. Nullable: an existing row predates it and gets it on the next
        // folder discovery, until which its name shows whole.
        migrator.registerMigration("v12-mailbox-delimiter") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "hierarchyDelimiter", .text)
            }
        }
        // Reactions (tapbacks): a message can be a reaction to another, carrying an
        // emoji rather than a chat body. Nullable, so every existing and every
        // ordinary message reads as not-a-reaction; a reaction's emoji is stamped
        // from its `X-Zirbe-Reaction` header when it syncs, or set on the local
        // copy of one Zirbe sends. Reactions are filtered out of the bubble stream
        // and out of the unread and new-mail counts.
        migrator.registerMigration("v13-message-reaction") { db in
            try db.alter(table: "message") { t in
                t.add(column: "reaction", .text)
            }
        }
        // Pinned conversations: local-only app state, so it can't ride on the
        // thread row (which `rethread` deletes and rebuilds from messages every
        // sync). A row here means the thread is pinned; the reads join it in and
        // sort pinned conversations to the top. Keyed by thread id within an
        // account. Wiped on sign-out, since `eraseAll` re-runs this migrator.
        migrator.registerMigration("v14-pinned-thread") { db in
            try db.create(table: "pinnedThread") { t in
                t.column("accountID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.primaryKey(["accountID", "threadID"])
            }
        }
        // Blocked senders: local-only app state listing addresses whose incoming
        // INBOX mail is auto-moved to Junk during sync. Keyed by the normalized
        // (lowercased) address within an account. Nothing rides on a message or
        // thread row, so it survives the rethread that rebuilds those every sync.
        // Wiped on sign-out, since `eraseAll` re-runs this migrator.
        migrator.registerMigration("v15-blocked-sender") { db in
            try db.create(table: "blockedSender") { t in
                t.column("accountID", .text).notNull()
                t.column("address", .text).notNull()
                t.primaryKey(["accountID", "address"])
            }
        }
        // The message table only had single-column indexes on accountID and
        // threadID. The hot reads are mailbox-scoped within an account
        // (threadSummaries, pruneMessages, blockedInboxRefs) and MAX(uid) per
        // mailbox (the notification watermark), all of which scan under the lone
        // accountID index. This composite covers them: leading accountID +
        // mailboxName narrows to a folder, trailing uid serves the range and MAX.
        migrator.registerMigration("v16-message-mailbox-index") { db in
            try db.create(
                index: "message_on_account_mailbox_uid",
                on: "message",
                columns: ["accountID", "mailboxName", "uid"]
            )
        }
        return migrator
    }()

    /// The privileged folder that is synced on launch, watched over IDLE, and
    /// polled in the background. The notification high-water mark is scoped to it.
    private static let inboxMailbox = "INBOX"
}
