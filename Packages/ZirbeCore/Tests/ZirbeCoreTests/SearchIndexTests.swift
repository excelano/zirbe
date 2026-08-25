import XCTest
import GRDB
@testable import ZirbeCore

/// The FTS5 search index: what it matches now that search is term-based rather
/// than a substring scan, and — the part that can rot quietly — whether it stays
/// in step with every path that writes or removes a message.
final class SearchIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zirbe-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path() -> String { directory.appendingPathComponent("mail.sqlite").path }

    private func account() -> Account {
        Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func msg(
        id: String,
        subject: String,
        from: String,
        fromName: String? = nil,
        to: [Participant] = [],
        minutes: Int,
        body: String? = nil
    ) -> Message {
        Message(
            messageID: id,
            uid: UInt32(minutes),
            subject: subject,
            from: Participant(address: from, displayName: fromName),
            to: to,
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: [.seen],
            bodyText: body
        )
    }

    /// How many rows the index holds, read on a separate connection so the test
    /// sees the table itself rather than what a query happens to join away.
    private func indexedRows(at dbPath: String) throws -> Int {
        let queue = try DatabaseQueue(path: dbPath)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messageSearch") ?? 0
        }
    }

    // MARK: Matching

    func testAWordMatchesFromItsStart() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        try await store.save(
            [msg(id: "<a@x>", subject: "Q3 Budget", from: "p@x.com", minutes: 1)],
            accountID: acct.id, mailboxName: "INBOX"
        )
        try await store.rethread(accountID: acct.id)

        for typed in ["b", "budg", "budget", "BUDGET"] {
            let hits = try await store.searchThreads(accountID: acct.id, query: typed)
            XCTAssertEqual(hits.map(\.subject), ["Q3 Budget"], "typing \"\(typed)\" should find it")
        }
    }

    /// The deliberate change from the old `LIKE '%…%'`: a term index matches whole
    /// words and word beginnings, not the middle of a word.
    func testMatchingStartsAtAWordAndNotMidWord() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        try await store.save(
            [msg(id: "<a@x>", subject: "Q3 Budget", from: "p@x.com", minutes: 1)],
            accountID: acct.id, mailboxName: "INBOX"
        )
        try await store.rethread(accountID: acct.id)

        let hits = try await store.searchThreads(accountID: acct.id, query: "udget")
        XCTAssertTrue(hits.isEmpty, "a search resumed mid-word no longer matches")
    }

    func testAccentsAreIgnoredBothWays() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        try await store.save(
            [msg(id: "<a@x>", subject: "Déjeuner", from: "p@x.com", minutes: 1)],
            accountID: acct.id, mailboxName: "INBOX"
        )
        try await store.rethread(accountID: acct.id)

        for typed in ["dejeuner", "Déjeuner", "dejeun"] {
            let hits = try await store.searchThreads(accountID: acct.id, query: typed)
            XCTAssertEqual(hits.map(\.subject), ["Déjeuner"], "\"\(typed)\" should match")
        }
    }

    /// Every word has to be on the same message, so adding a word narrows.
    func testEveryWordMustMatchTheSameMessage() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        try await store.save([
            msg(id: "<a@x>", subject: "Q3 Budget", from: "dana@x.com", fromName: "Dana", minutes: 2),
            msg(id: "<b@x>", subject: "Lunch", from: "pat@x.com", fromName: "Pat", minutes: 1),
        ], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let together = try await store.searchThreads(accountID: acct.id, query: "budget dana")
        XCTAssertEqual(together.map(\.subject), ["Q3 Budget"], "subject and sender on one message")

        let apart = try await store.searchThreads(accountID: acct.id, query: "budget pat")
        XCTAssertTrue(apart.isEmpty, "words spread across different messages don't match")
    }

    func testAQueryOfOnlyPunctuationFindsNothing() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        try await store.save(
            [msg(id: "<a@x>", subject: "Q3 Budget", from: "p@x.com", minutes: 1)],
            accountID: acct.id, mailboxName: "INBOX"
        )
        try await store.rethread(accountID: acct.id)

        for typed in ["   ", "\"", "*", "-", "(", "^"] {
            let hits = try await store.searchThreads(accountID: acct.id, query: typed)
            XCTAssertTrue(hits.isEmpty, "\"\(typed)\" is not a search, and must not throw either")
        }
    }

    /// Recipients are indexed as names and addresses, never as the JSON keys they
    /// are stored under — otherwise "display" would match everything.
    func testRecipientsAreIndexedWithoutTheirStorageKeys() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        try await store.save([
            msg(
                id: "<a@x>", subject: "Lunch", from: "p@x.com",
                to: [Participant(address: "sam@x.com", displayName: "Sam Rivera")], minutes: 1
            ),
        ], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let byName = try await store.searchThreads(accountID: acct.id, query: "rivera")
        XCTAssertEqual(byName.map(\.subject), ["Lunch"])
        for noise in ["displayName", "address"] {
            let hits = try await store.searchThreads(accountID: acct.id, query: noise)
            XCTAssertTrue(hits.isEmpty, "\"\(noise)\" is storage, not content")
        }
    }

    // MARK: Staying in step

    func testAStoredBodyBecomesSearchable() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        let one = msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 1)
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let before = try await store.searchThreads(accountID: acct.id, query: "tacos")
        XCTAssertTrue(before.isEmpty)

        try await store.storeBodies([one.id: (text: "Want to grab tacos?", hasHTML: false, attachments: [])])
        let hits = try await store.searchThreads(accountID: acct.id, query: "tacos")
        XCTAssertEqual(hits.map(\.subject), ["Lunch"])
    }

    /// A sync re-saves the same message as headers only. The body it isn't carrying
    /// has to stay searchable, and a changed subject has to become searchable.
    func testAHeaderOnlyResaveKeepsTheBodyAndRefreshesTheHeaders() async throws {
        let store = try MailStore(path: path())
        let acct = account()
        try await store.upsert(acct)
        var one = msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 1)
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([one.id: (text: "Want to grab tacos?", hasHTML: false, attachments: [])])
        try await store.rethread(accountID: acct.id)

        one.subject = "Dinner"
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let byBody = try await store.searchThreads(accountID: acct.id, query: "tacos")
        XCTAssertEqual(byBody.count, 1, "the body the re-save didn't carry is still indexed")
        let bySubject = try await store.searchThreads(accountID: acct.id, query: "dinner")
        XCTAssertEqual(bySubject.count, 1, "the new subject is indexed")
        let oldSubject = try await store.searchThreads(accountID: acct.id, query: "lunch")
        XCTAssertTrue(oldSubject.isEmpty, "and the old one is gone")
    }

    func testTrashingAThreadRemovesItsMessagesFromTheIndex() async throws {
        let dbPath = path()
        let store = try MailStore(path: dbPath)
        let acct = account()
        try await store.upsert(acct)
        let one = msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 1, body: "tacos")
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        XCTAssertEqual(try indexedRows(at: dbPath), 1)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(summaries.first?.id)
        try await store.deleteThread(threadID: threadID)

        XCTAssertEqual(try indexedRows(at: dbPath), 0, "the index doesn't keep trashed mail")
        let gone = try await store.searchThreads(accountID: acct.id, query: "tacos")
        XCTAssertTrue(gone.isEmpty)
    }

    func testPruningMailTheServerDroppedRemovesItFromTheIndex() async throws {
        let dbPath = path()
        let store = try MailStore(path: dbPath)
        let acct = account()
        try await store.upsert(acct)
        try await store.save([
            msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 1),
            msg(id: "<b@x>", subject: "Budget", from: "p@x.com", minutes: 2),
        ], accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(try indexedRows(at: dbPath), 2)

        // The server now reports only the first message's UID.
        _ = try await store.pruneMessages(accountID: acct.id, mailboxName: "INBOX", keepingUIDs: [1])
        try await store.rethread(accountID: acct.id)

        XCTAssertEqual(try indexedRows(at: dbPath), 1)
        let pruned = try await store.searchThreads(accountID: acct.id, query: "budget")
        XCTAssertTrue(pruned.isEmpty)
        let kept = try await store.searchThreads(accountID: acct.id, query: "lunch")
        XCTAssertEqual(kept.count, 1)
    }

    func testAUIDValidityRebuildClearsTheIndexToo() async throws {
        let dbPath = path()
        let store = try MailStore(path: dbPath)
        let acct = account()
        try await store.upsert(acct)
        try await store.save(
            [msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 1)],
            accountID: acct.id, mailboxName: "INBOX"
        )
        XCTAssertEqual(try indexedRows(at: dbPath), 1)

        try await store.clearMessages(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(try indexedRows(at: dbPath), 0)
    }

    // MARK: Upgrade

    /// Mail cached before the index existed has to be searchable straight after the
    /// upgrade, not only once it has been synced again.
    func testTheUpgradeBackfillsMailAlreadyCached() async throws {
        let dbPath = path()
        let acct = account()

        do {
            let legacy = try DatabaseQueue(path: dbPath)
            try MailStore.migrator.migrate(legacy, upTo: "v17-message-snippet")
            try await legacy.write { db in
                try acct.save(db)
                try db.execute(
                    sql: """
                        INSERT INTO message
                            (id, accountID, mailboxName, uid, messageID, referenceIDs, toParticipants,
                             ccParticipants, flags, hasHTML, attachments, sendState, subject, fromAddress,
                             fromName, bodyText, snippet, date)
                        VALUES (?, ?, 'INBOX', 1, ?, '[]', ?, '[]', '[]', 0, '[]', 'sent', ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "mid:<a@x>", acct.id, "<a@x>",
                        #"[{"address":"sam@x.com","displayName":"Sam Rivera"}]"#,
                        "Q3 Budget", "dana@x.com", "Dana", "Want to grab tacos?", "Want to grab tacos?",
                        Date(timeIntervalSince1970: 60),
                    ]
                )
            }
        }

        let upgraded = try MailStore(path: dbPath)
        try await upgraded.rethread(accountID: acct.id)

        for (field, query) in [
            ("subject", "budget"), ("sender name", "dana"), ("sender address", "dana@x.com"),
            ("recipient", "rivera"), ("body", "tacos"),
        ] {
            let hits = try await upgraded.searchThreads(accountID: acct.id, query: query)
            XCTAssertEqual(hits.count, 1, "\(field) should be searchable after the upgrade")
        }
    }
}
