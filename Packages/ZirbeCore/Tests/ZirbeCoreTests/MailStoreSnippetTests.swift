import XCTest
import GRDB
@testable import ZirbeCore

/// The inbox row's one-line preview. It is derived from the body once, when the
/// body is stored, and read back on each rethread rather than re-derived, so
/// these cover both that it still appears and that it survives the paths which
/// rewrite a message row without its body.
final class MailStoreSnippetTests: XCTestCase {
    private func account() -> Account {
        Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    /// A synced message. It carries a UID because everything the server hands back
    /// does, and the backfill scan skips rows without one.
    private func msg(id: String, references: [String] = [], from: String, minutes: Int, reaction: String? = nil) -> Message {
        Message(
            messageID: id,
            uid: UInt32(minutes),
            inReplyTo: references.last,
            references: references,
            subject: "Lunch",
            from: Participant(address: from),
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: [.seen],
            reaction: reaction
        )
    }

    /// The header-only row has no preview; storing its body gives the thread one.
    func testPreviewAppearsOnceTheBodyIsStored() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let one = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertNil(summaries.first?.preview, "a synced header carries no body to preview")

        try await store.storeBodies([one.id: (text: "Shall we say one o'clock?", hasHTML: false, attachments: [])])
        try await store.rethread(accountID: acct.id)
        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.preview, "Shall we say one o'clock?")
    }

    /// The preview follows the newest chat message as a thread grows.
    func testPreviewTracksTheNewestMessage() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let first = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        let second = msg(id: "<b@x>", references: ["<a@x>"], from: "me@x.com", minutes: 5)
        try await store.save([first, second], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([
            first.id: (text: "Shall we say one o'clock?", hasHTML: false, attachments: []),
            second.id: (text: "One works.", hasHTML: false, attachments: []),
        ])
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.preview, "One works.")
    }

    /// A tapback is not a glance: the preview stays on the newest real message.
    func testReactionNeverBecomesThePreview() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let real = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        let tapback = msg(id: "<b@x>", references: ["<a@x>"], from: "me@x.com", minutes: 9, reaction: "👍")
        try await store.save([real, tapback], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([
            real.id: (text: "Shall we say one o'clock?", hasHTML: false, attachments: []),
            tapback.id: (text: "Reacted 👍 to \"Shall we say one o'clock?\"", hasHTML: false, attachments: []),
        ])
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.preview, "Shall we say one o'clock?")
    }

    /// A later sync re-saves the same message as headers only, keeping the cached
    /// body. The preview is derived from that body, so it has to be kept with it or
    /// the row would silently go blank on the next sync.
    func testPreviewSurvivesAHeaderOnlyResave() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let one = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([one.id: (text: "Shall we say one o'clock?", hasHTML: false, attachments: [])])
        try await store.rethread(accountID: acct.id)
        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.preview, "Shall we say one o'clock?")

        // What a sync does: the same envelope again, with no body attached.
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.preview, "Shall we say one o'clock?")
    }

    /// A re-save refreshes the headers, so read state changed in another client
    /// lands here — while the cached body and its preview stay put. The two halves
    /// pull against each other: the columns a sync must overwrite and the columns it
    /// must not are the same statement, so they're worth asserting together.
    func testResyncRefreshesFlagsAndKeepsTheBody() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        var one = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        one.flags = []
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([one.id: (text: "Shall we say one o'clock?", hasHTML: false, attachments: [])])
        try await store.rethread(accountID: acct.id)

        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertTrue(summaries.first?.isUnread ?? false)
        XCTAssertEqual(summaries.first?.preview, "Shall we say one o'clock?")

        // The same message again, now read on the server, still header-only.
        one.flags = [.seen]
        try await store.save([one], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertFalse(summaries.first?.isUnread ?? true, "a flag change on the server reaches the cache")
        XCTAssertEqual(summaries.first?.preview, "Shall we say one o'clock?", "and the body it doesn't carry is left alone")
    }

    /// The sync's body backfill moves the row's preview into place on its own, so
    /// the second full rethread it used to need is gone. Deliberately never
    /// rethreads after storing the body: if the preview shows up here, it got there
    /// by the targeted update and nothing else.
    func testBackfilledBodyUpdatesThePreviewWithoutARethread() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let first = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        let latest = msg(id: "<b@x>", references: ["<a@x>"], from: "p@x.com", minutes: 5)
        try await store.save([first, latest], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertNil(summaries.first?.preview, "no body yet, so no preview")

        // What the sync does: fetch the one message per thread the row previews.
        let needing = try await store.latestMessagesNeedingBodies(accountID: acct.id)
        XCTAssertEqual(needing.map(\.id), [latest.id], "the backfill targets the newest message")

        try await store.storeBodies([latest.id: (text: "One works.", hasHTML: false, attachments: [])])
        try await store.refreshThreadSnippets(fromLatestMessages: [latest.id])

        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.preview, "One works.")
    }

    /// The targeted update touches the thread the message belongs to and no other.
    func testTheRefreshLeavesOtherThreadsAlone() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let mine = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        let other = msg(id: "<z@x>", from: "r@x.com", minutes: 5)
        try await store.save([mine, other], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([
            mine.id: (text: "One works.", hasHTML: false, attachments: []),
            other.id: (text: "Different conversation.", hasHTML: false, attachments: []),
        ])
        try await store.rethread(accountID: acct.id)
        try await store.refreshThreadSnippets(fromLatestMessages: [mine.id])

        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first { $0.id.contains("a@x") }?.preview, "One works.")
        XCTAssertEqual(
            summaries.first { $0.id.contains("z@x") }?.preview,
            "Different conversation.",
            "the other thread keeps the preview the rethread gave it"
        )
    }

    /// The preview shows the sender's own words, not the quoted history under them.
    func testPreviewFoldsTheQuoteTrailer() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let reply = msg(id: "<a@x>", from: "p@x.com", minutes: 1)
        try await store.save([reply], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([reply.id: (
            text: "One works.\n\nOn Monday, p@x.com wrote:\n> Shall we say one o'clock?\n",
            hasHTML: false,
            attachments: []
        )])
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        let preview = try XCTUnwrap(summaries.first?.preview)
        XCTAssertEqual(preview, "One works.")
    }
}

/// The v17 upgrade. A database that predates the stored preview holds bodies but
/// no previews; the migration has to derive them, or every conversation already
/// synced would show a blank inbox row until its body happened to be fetched again.
final class MessageSnippetMigrationTests: XCTestCase {
    func testUpgradeBackfillsPreviewsFromCachedBodies() throws {
        let dbQueue = try DatabaseQueue()

        // A store as it stood before the preview column existed.
        try MailStore.migrator.migrate(dbQueue, upTo: "v16-message-mailbox-index")
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message
                        (id, accountID, mailboxName, referenceIDs, toParticipants, ccParticipants,
                         flags, bodyText, hasHTML, attachments, sendState)
                    VALUES (?, ?, ?, '[]', '[]', '[]', '[]', ?, 0, '[]', 'sent')
                    """,
                arguments: [
                    "<a@x>", "acct", "INBOX",
                    "One works.\n\nOn Monday, p@x.com wrote:\n> Shall we say one o'clock?\n",
                ]
            )
            // And a header-only row, which has nothing to derive from.
            try db.execute(
                sql: """
                    INSERT INTO message
                        (id, accountID, mailboxName, referenceIDs, toParticipants, ccParticipants,
                         flags, hasHTML, attachments, sendState)
                    VALUES (?, ?, ?, '[]', '[]', '[]', '[]', 0, '[]', 'sent')
                    """,
                arguments: ["<b@x>", "acct", "INBOX"]
            )
        }

        try MailStore.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let withBody = try String.fetchOne(db, sql: "SELECT snippet FROM message WHERE id = '<a@x>'")
            XCTAssertEqual(withBody, "One works.", "a cached body is previewed, quote folded")
            let headerOnly = try String.fetchOne(db, sql: "SELECT snippet FROM message WHERE id = '<b@x>'")
            XCTAssertNil(headerOnly, "a header-only row has no body to preview")
        }
    }
}
