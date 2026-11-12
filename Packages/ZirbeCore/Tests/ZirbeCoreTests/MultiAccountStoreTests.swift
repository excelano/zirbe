// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import XCTest
import GRDB
@testable import ZirbeCore

final class MultiAccountStoreTests: XCTestCase {
    private let work = Account(emailAddress: "me@work.com", imapHost: "imap.work.com", smtpHost: "smtp.work.com")
    private let home = Account(emailAddress: "me@home.com", imapHost: "imap.home.com", smtpHost: "smtp.home.com")

    private func shared(uid: UInt32 = 1) -> Message {
        Message(
            messageID: "<lunch@x>",
            uid: uid,
            subject: "Lunch",
            from: Participant(address: "dana@x.com"),
            to: [Participant(address: "me@work.com"), Participant(address: "me@home.com")],
            date: Date(timeIntervalSince1970: 60),
            flags: []
        )
    }

    private func reply() -> Message {
        Message(
            messageID: "<lunch-2@x>",
            uid: 2,
            inReplyTo: "<lunch@x>",
            references: ["<lunch@x>"],
            subject: "Re: Lunch",
            from: Participant(address: "sam@x.com"),
            to: [Participant(address: "me@work.com"), Participant(address: "dana@x.com")],
            date: Date(timeIntervalSince1970: 120),
            flags: []
        )
    }

    private func storeWithSharedMail() async throws -> MailStore {
        let store = try MailStore()
        for account in [work, home] {
            try await store.upsert(account)
            try await store.save([shared(uid: account == work ? 7 : 3)], accountID: account.id, mailboxName: "INBOX")
            try await store.rethread(accountID: account.id)
        }
        return store
    }

    func testTheSameMessageIsKeptOncePerAccount() async throws {
        let store = try await storeWithSharedMail()

        for (account, uid) in [(work, UInt32(7)), (home, UInt32(3))] {
            let summaries = try await store.threadSummaries(accountID: account.id, mailboxName: "INBOX")
            XCTAssertEqual(summaries.map(\.subject), ["Lunch"], account.emailAddress)
            let ref = try await store.messageRef(id: shared().id, accountID: account.id)
            XCTAssertEqual(ref?.uid, uid, account.emailAddress)
        }
    }

    func testAThreadRootedAtSharedMailRethreadsInBothAccounts() async throws {
        let store = try await storeWithSharedMail()
        try await store.save([reply()], accountID: work.id, mailboxName: "INBOX")
        try await store.rethread(accountID: work.id)
        try await store.rethread(accountID: home.id)

        let threadID = shared().id
        let workThread = try await store.thread(id: threadID, accountID: work.id)
        let homeThread = try await store.thread(id: threadID, accountID: home.id)
        XCTAssertEqual(workThread?.messages.count, 2)
        XCTAssertEqual(homeThread?.messages.count, 1)
    }

    func testReadingInOneAccountLeavesTheOtherUnread() async throws {
        let store = try await storeWithSharedMail()
        try await store.setSeen(true, threadIDs: [shared().id], accountID: work.id)
        try await store.rethread(accountID: work.id)

        let workUnread = try await store.threadSummaries(accountID: work.id).first?.isUnread
        let homeUnread = try await store.threadSummaries(accountID: home.id).first?.isUnread
        XCTAssertEqual(workUnread, false)
        XCTAssertEqual(homeUnread, true)
    }

    func testTrashingInOneAccountKeepsTheOthersCopyAndItsSearchEntry() async throws {
        let store = try await storeWithSharedMail()
        for account in [work, home] {
            try await store.storeBodies([shared().id: (text: "Tacos at noon?", hasHTML: false, attachments: [])], accountID: account.id)
        }

        try await store.deleteThreads(threadIDs: [shared().id], accountID: work.id)
        try await store.rethread(accountID: work.id)

        let workSummaries = try await store.threadSummaries(accountID: work.id)
        XCTAssertTrue(workSummaries.isEmpty)
        let workHits = try await store.searchThreads(accountID: work.id, query: "tacos")
        XCTAssertTrue(workHits.isEmpty)
        let homeHits = try await store.searchThreads(accountID: home.id, query: "tacos")
        XCTAssertEqual(homeHits.map(\.subject), ["Lunch"])
    }

    func testABodyStoredInOneAccountIsNotSearchableInTheOther() async throws {
        let store = try await storeWithSharedMail()
        try await store.storeBodies([shared().id: (text: "Tacos at noon?", hasHTML: false, attachments: [])], accountID: work.id)

        let workHits = try await store.searchThreads(accountID: work.id, query: "tacos")
        let homeHits = try await store.searchThreads(accountID: home.id, query: "tacos")
        XCTAssertEqual(workHits.count, 1)
        XCTAssertTrue(homeHits.isEmpty)
    }

    func testTheKeyUpgradeKeepsCachedMail() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zirbe-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("mail.sqlite").path

        do {
            let legacy = try DatabaseQueue(path: dbPath)
            try MailStore.migrator.migrate(legacy, upTo: "v19-message-invite")
            try await legacy.write { [work] db in
                try work.insertIntoLegacySchema(db)
                try db.execute(
                    sql: """
                        INSERT INTO message
                            (id, accountID, mailboxName, uid, messageID, referenceIDs, toParticipants,
                             ccParticipants, flags, hasHTML, attachments, sendState, subject, fromAddress,
                             bodyText, snippet, date, threadID)
                        VALUES ('mid:<lunch@x>', ?, 'INBOX', 7, '<lunch@x>', '[]', '[]', '[]', '[]', 0, '[]',
                                'sent', 'Lunch', 'dana@x.com', 'Tacos at noon?', 'Tacos at noon?', ?, 'mid:<lunch@x>')
                        """,
                    arguments: [work.id, Date(timeIntervalSince1970: 60)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO messageSearch (messageID, subject, sender, participants, body)
                        VALUES ('mid:<lunch@x>', 'Lunch', 'dana@x.com', '', 'Tacos at noon?')
                        """
                )
                try db.execute(
                    sql: """
                        INSERT INTO thread (id, accountID, subject, lastActivity, isUnread, messageCount, participants, snippet)
                        VALUES ('mid:<lunch@x>', ?, 'Lunch', ?, 1, 1, '[]', 'Tacos at noon?')
                        """,
                    arguments: [work.id, Date(timeIntervalSince1970: 60)]
                )
                try db.execute(
                    sql: "INSERT INTO pinnedThread (accountID, threadID) VALUES (?, 'mid:<lunch@x>')",
                    arguments: [work.id]
                )
            }
        }

        let upgraded = try MailStore(path: dbPath)
        let summaries = try await upgraded.threadSummaries(accountID: work.id, mailboxName: "INBOX")
        XCTAssertEqual(summaries.map(\.subject), ["Lunch"])
        XCTAssertEqual(summaries.first?.isPinned, true)
        XCTAssertEqual(summaries.first?.preview, "Tacos at noon?")
        let thread = try await upgraded.thread(id: "mid:<lunch@x>", accountID: work.id)
        XCTAssertEqual(thread?.messages.first?.bodyText, "Tacos at noon?")
        let hits = try await upgraded.searchThreads(accountID: work.id, query: "tacos")
        XCTAssertEqual(hits.count, 1)
        let accounts = try await upgraded.accounts()
        XCTAssertEqual(accounts.map(\.color), [.blue])
        XCTAssertNil(accounts.first?.label)

        try await upgraded.deleteThreads(threadIDs: ["mid:<lunch@x>"], accountID: work.id)
        try await upgraded.rethread(accountID: work.id)
        let after = try await upgraded.searchThreads(accountID: work.id, query: "tacos")
        XCTAssertTrue(after.isEmpty)
    }
}
