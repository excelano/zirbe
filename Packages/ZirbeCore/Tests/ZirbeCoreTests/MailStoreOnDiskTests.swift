import XCTest
import GRDB
@testable import ZirbeCore

/// The on-disk store. Every other test runs against the in-memory database, which
/// is a `DatabaseQueue`; the store the app actually ships opens a `DatabasePool`
/// from a path, so the migrations and the read/write paths are covered here on the
/// type that really runs.
final class MailStoreOnDiskTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zirbe-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path() -> String {
        directory.appendingPathComponent("mail.sqlite").path
    }

    /// A file-backed store migrates, writes, and reads back — and leaves a `-wal`
    /// beside the database, which is the observable proof that readers are no longer
    /// serialized behind the writer.
    func testFileBackedStoreMigratesAndUsesWAL() async throws {
        let dbPath = path()
        let store = try MailStore(path: dbPath)
        let acct = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        try await store.upsert(acct)

        let message = Message(
            messageID: "<a@x>",
            subject: "Lunch",
            from: Participant(address: "p@x.com"),
            date: Date(timeIntervalSince1970: 60),
            flags: [.seen]
        )
        try await store.save([message], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([message.id: (text: "One works.", hasHTML: false, attachments: [])])
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(summaries.map(\.subject), ["Lunch"])
        XCTAssertEqual(summaries.first?.preview, "One works.")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dbPath + "-wal"),
            "the on-disk store runs in WAL, so reads don't wait on the writer"
        )
    }

    /// Reopening the same file keeps what was written, and re-running the migrator
    /// over an already-migrated database is a no-op rather than an error.
    func testReopeningAnExistingDatabaseKeepsItsContents() async throws {
        let dbPath = path()
        let acct = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        do {
            let store = try MailStore(path: dbPath)
            try await store.upsert(acct)
            let message = Message(
                messageID: "<a@x>",
                subject: "Lunch",
                from: Participant(address: "p@x.com"),
                date: Date(timeIntervalSince1970: 60),
                flags: [.seen]
            )
            try await store.save([message], accountID: acct.id, mailboxName: "INBOX")
            try await store.rethread(accountID: acct.id)
        }

        let reopened = try MailStore(path: dbPath)
        let summaries = try await reopened.threadSummaries(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(summaries.map(\.subject), ["Lunch"])
    }

    /// The upgrade a shipped install actually performs: a database written by the
    /// old queue-backed store, in rollback-journal mode, opened by the pool. SQLite
    /// converts the journal mode in place and the mail already cached has to come
    /// through it intact.
    func testAnExistingRollbackJournalDatabaseConvertsAndKeepsItsMail() async throws {
        let dbPath = path()
        let acct = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")

        // The store as the previous release left it: a DatabaseQueue on disk.
        do {
            let legacy = try DatabaseQueue(path: dbPath)
            try MailStore.migrator.migrate(legacy)
            try await legacy.write { db in
                try acct.save(db)
                try db.execute(
                    sql: """
                        INSERT INTO message
                            (id, accountID, mailboxName, referenceIDs, toParticipants, ccParticipants,
                             flags, bodyText, snippet, hasHTML, attachments, sendState, subject, messageID, date)
                        VALUES (?, ?, 'INBOX', '[]', '[]', '[]', '[]', ?, ?, 0, '[]', 'sent', 'Lunch', ?, ?)
                        """,
                    arguments: ["mid:<a@x>", acct.id, "One works.", "One works.", "<a@x>", Date(timeIntervalSince1970: 60)]
                )
            }
            let mode = try await legacy.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }
            XCTAssertNotEqual(mode, "wal", "the fixture has to start in the mode the old store used")
        }

        let upgraded = try MailStore(path: dbPath)
        try await upgraded.rethread(accountID: acct.id)
        let summaries = try await upgraded.threadSummaries(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(summaries.map(\.subject), ["Lunch"], "mail cached before the upgrade survives it")
        XCTAssertEqual(summaries.first?.preview, "One works.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-wal"), "and the file is now in WAL")
    }

    /// Two stores against one file, which is what the app and its background refresh
    /// actually do. WAL is what lets the second one read while the first writes.
    func testASecondStoreOnTheSameFileSeesCommittedWork() async throws {
        let dbPath = path()
        let acct = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")

        let foreground = try MailStore(path: dbPath)
        let background = try MailStore(path: dbPath)

        try await foreground.upsert(acct)
        let message = Message(
            messageID: "<a@x>",
            subject: "Lunch",
            from: Participant(address: "p@x.com"),
            date: Date(timeIntervalSince1970: 60),
            flags: [.seen]
        )
        try await foreground.save([message], accountID: acct.id, mailboxName: "INBOX")
        try await foreground.rethread(accountID: acct.id)

        let seen = try await background.threadSummaries(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(seen.map(\.subject), ["Lunch"], "the other connection sees committed work")
    }
}
