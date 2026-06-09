import XCTest
@testable import ZirbeCore

final class MailStoreTests: XCTestCase {
    private func account() -> Account {
        Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func msg(
        id: String,
        references: [String] = [],
        subject: String?,
        from: String,
        minutes: Int,
        seen: Bool = true
    ) -> Message {
        Message(
            messageID: id,
            references: references,
            subject: subject,
            from: Participant(address: from),
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: seen ? [.seen] : []
        )
    }

    func testSaveRethreadAndQuery() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let a = msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 0)
        let b = msg(id: "<b@x>", references: ["<a@x>"], subject: "Re: Lunch", from: "q@x.com", minutes: 1, seen: false)
        let z = msg(id: "<z@x>", subject: "Invoice", from: "r@x.com", minutes: 5)
        try await store.save([a, b, z], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 2)
        // Invoice (minute 5) is more recent than Lunch (minute 1), so it sorts first.
        XCTAssertEqual(summaries.map(\.subject), ["Invoice", "Lunch"])

        let lunch = try XCTUnwrap(summaries.first { $0.subject == "Lunch" })
        XCTAssertTrue(lunch.isUnread)            // reply b is unseen
        XCTAssertEqual(lunch.messageCount, 2)
        XCTAssertEqual(Set(lunch.participants.map(\.address)), ["p@x.com", "q@x.com"])

        let convo = try await store.thread(id: lunch.id)
        XCTAssertEqual(convo?.messages.map(\.messageID), ["<a@x>", "<b@x>"])
    }

    func testReSavingIsIdempotent() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let a = msg(id: "<a@x>", subject: "Hi", from: "p@x.com", minutes: 0)
        try await store.save([a], accountID: acct.id, mailboxName: "INBOX")
        try await store.save([a], accountID: acct.id, mailboxName: "INBOX") // same message again
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.messageCount, 1)
    }

    func testFlagUpdateOnReSyncFlipsUnread() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let unseen = msg(id: "<a@x>", subject: "Ping", from: "p@x.com", minutes: 0, seen: false)
        try await store.save([unseen], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.isUnread, true)

        // Re-fetch shows it read now: same id, updated flags.
        let seen = msg(id: "<a@x>", subject: "Ping", from: "p@x.com", minutes: 0, seen: true)
        try await store.save([seen], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.isUnread, false)
    }

    func testPersistsAcrossReopen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zirbe-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let acct = account()

        do {
            let store = try MailStore(path: path)
            try await store.upsert(acct)
            let a = msg(id: "<a@x>", subject: "Persist", from: "p@x.com", minutes: 0)
            try await store.save([a], accountID: acct.id, mailboxName: "INBOX")
            try await store.rethread(accountID: acct.id)
        }

        let reopened = try MailStore(path: path)
        let summaries = try await reopened.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.subject, "Persist")
    }

    func testThreadIdentityStableWhenMissingRootArrivesLater() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // Only a reply arrives first; its root <a@x> is referenced but absent.
        let reply = msg(id: "<b@x>", references: ["<a@x>"], subject: "Re: Plan", from: "q@x.com", minutes: 1)
        try await store.save([reply], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let firstID = try await store.threadSummaries(accountID: acct.id).first?.id
        XCTAssertEqual(firstID, "mid:<a@x>")

        // The root arrives in a later sync; the thread id must not change.
        let root = msg(id: "<a@x>", subject: "Plan", from: "p@x.com", minutes: 0)
        try await store.save([root], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.id, firstID)
        XCTAssertEqual(summaries.first?.messageCount, 2)
    }

    func testBodyCachingAndPreservation() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // A header-only message with a server UID and no body yet.
        let header = Message(
            messageID: "<a@x>",
            uid: 42,
            subject: "Body test",
            from: Participant(address: "p@x.com"),
            date: Date(timeIntervalSince1970: 0),
            flags: [.seen]
        )
        try await store.save([header], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(summaries.first?.id)

        // It reports needing a body, with the UID and mailbox to fetch from.
        let needs = try await store.messagesNeedingBodies(threadID: threadID)
        XCTAssertEqual(needs.map(\.uid), [42])
        XCTAssertEqual(needs.first?.mailbox, "INBOX")

        // Cache the fetched body: it no longer needs one and the conversation shows it.
        try await store.storeBodies([header.id: "Hello there"])
        let afterCache = try await store.messagesNeedingBodies(threadID: threadID)
        XCTAssertTrue(afterCache.isEmpty)
        var convo = try await store.thread(id: threadID)
        XCTAssertEqual(convo?.messages.first?.bodyText, "Hello there")

        // A later header re-sync carries no body; the cached body must survive it.
        try await store.save([header], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        convo = try await store.thread(id: threadID)
        XCTAssertEqual(convo?.messages.first?.bodyText, "Hello there")
    }
}
