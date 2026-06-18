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

        // Cache the fetched body: it no longer needs one and the conversation
        // shows it, with the HTML-original flag and the attachments recorded
        // alongside the text.
        let attachment = MessageAttachment(filename: "report.pdf", mimeType: "application/pdf", partID: "2")
        try await store.storeBodies([header.id: (text: "Hello there", hasHTML: true, attachments: [attachment])])
        let afterCache = try await store.messagesNeedingBodies(threadID: threadID)
        XCTAssertTrue(afterCache.isEmpty)
        var convo = try await store.thread(id: threadID)
        XCTAssertEqual(convo?.messages.first?.bodyText, "Hello there")
        XCTAssertEqual(convo?.messages.first?.hasHTML, true)
        XCTAssertEqual(convo?.messages.first?.attachments, [attachment])

        // A later header re-sync carries no body; the cached body, its HTML flag,
        // and its attachments must all survive it, not reset to nil/false/empty.
        try await store.save([header], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        convo = try await store.thread(id: threadID)
        XCTAssertEqual(convo?.messages.first?.bodyText, "Hello there")
        XCTAssertEqual(convo?.messages.first?.hasHTML, true)
        XCTAssertEqual(convo?.messages.first?.attachments, [attachment])
    }

    func testMessageRefResolvesUIDAndMailbox() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // A server message has a ref; a local-only copy (no UID) resolves to nil.
        let server = uidMsg(id: "<a@x>", uid: 88, subject: "Has original", minutes: 0)
        let local = msg(id: "<b@x>", subject: "Local only", from: "me@x.com", minutes: 1)
        try await store.save([server], accountID: acct.id, mailboxName: "INBOX")
        try await store.save([local], accountID: acct.id, mailboxName: "Sent")

        let ref = try await store.messageRef(id: server.id)
        XCTAssertEqual(ref?.uid, 88)
        XCTAssertEqual(ref?.mailbox, "INBOX")

        let localRef = try await store.messageRef(id: local.id)
        XCTAssertNil(localRef)

        let unknownRef = try await store.messageRef(id: "mid:<nope@x>")
        XCTAssertNil(unknownRef)
    }

    // MARK: - Sync reconciliation

    private func uidMsg(id: String, uid: UInt32, subject: String, minutes: Int) -> Message {
        Message(
            messageID: id,
            uid: uid,
            subject: subject,
            from: Participant(address: "p@x.com"),
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: [.seen]
        )
    }

    func testPruneRemovesServerDeletedMessages() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        try await store.upsert(Mailbox(accountID: acct.id, name: "INBOX", role: .inbox))

        let a = uidMsg(id: "<a@x>", uid: 1, subject: "Alpha", minutes: 0)
        let b = uidMsg(id: "<b@x>", uid: 2, subject: "Bravo", minutes: 1)
        let c = uidMsg(id: "<c@x>", uid: 3, subject: "Charlie", minutes: 2)
        try await store.save([a, b, c], accountID: acct.id, mailboxName: "INBOX")

        // The server now reports only UIDs 1 and 3; UID 2 was deleted elsewhere.
        let pruned = try await store.pruneMessages(accountID: acct.id, mailboxName: "INBOX", keepingUIDs: [1, 3])
        XCTAssertEqual(pruned, 1)
        try await store.rethread(accountID: acct.id)

        let subjects = try await store.threadSummaries(accountID: acct.id).map(\.subject)
        XCTAssertEqual(Set(subjects), ["Alpha", "Charlie"])
    }

    func testPruneIsScopedToMailbox() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // The same UID can exist in two mailboxes; pruning INBOX must not reach Sent.
        let inbox = uidMsg(id: "<i@x>", uid: 1, subject: "Inbox item", minutes: 0)
        let sent = uidMsg(id: "<s@x>", uid: 1, subject: "Sent item", minutes: 1)
        try await store.save([inbox], accountID: acct.id, mailboxName: "INBOX")
        try await store.save([sent], accountID: acct.id, mailboxName: "Sent")

        let pruned = try await store.pruneMessages(accountID: acct.id, mailboxName: "INBOX", keepingUIDs: [])
        XCTAssertEqual(pruned, 1)
        try await store.rethread(accountID: acct.id)

        let subjects = try await store.threadSummaries(accountID: acct.id).map(\.subject)
        XCTAssertEqual(subjects, ["Sent item"])
    }

    func testPrunePreservesMessagesWithoutUID() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // A locally-composed copy has no server UID and is not the server's to delete.
        let local = msg(id: "<local@x>", subject: "Draft reply", from: "me@x.com", minutes: 0)
        try await store.save([local], accountID: acct.id, mailboxName: "INBOX")

        let pruned = try await store.pruneMessages(accountID: acct.id, mailboxName: "INBOX", keepingUIDs: [])
        XCTAssertEqual(pruned, 0)
        try await store.rethread(accountID: acct.id)
        let remaining = try await store.threadSummaries(accountID: acct.id).count
        XCTAssertEqual(remaining, 1)
    }

    func testClearMessagesIsScopedToMailbox() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let inbox = uidMsg(id: "<i@x>", uid: 1, subject: "Inbox item", minutes: 0)
        let sent = uidMsg(id: "<s@x>", uid: 9, subject: "Sent item", minutes: 1)
        try await store.save([inbox], accountID: acct.id, mailboxName: "INBOX")
        try await store.save([sent], accountID: acct.id, mailboxName: "Sent")

        try await store.clearMessages(accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let subjects = try await store.threadSummaries(accountID: acct.id).map(\.subject)
        XCTAssertEqual(subjects, ["Sent item"])
    }

    func testSetSeenFlipsThreadUnread() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let unseen = msg(id: "<a@x>", subject: "Ping", from: "p@x.com", minutes: 0, seen: false)
        try await store.save([unseen], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let initial = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(initial.first?.id)

        try await store.setSeen(true, threadID: threadID)
        try await store.rethread(accountID: acct.id)
        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.isUnread, false)

        try await store.setSeen(false, threadID: threadID)
        try await store.rethread(accountID: acct.id)
        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.isUnread, true)
    }

    func testSetFlaggedFlipsThreadFlagged() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let m = msg(id: "<a@x>", subject: "Ping", from: "p@x.com", minutes: 0)
        try await store.save([m], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let initial = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(initial.first?.id)
        XCTAssertEqual(initial.first?.isFlagged, false)

        try await store.setFlagged(true, threadID: threadID)
        try await store.rethread(accountID: acct.id)
        var summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.isFlagged, true)

        try await store.setFlagged(false, threadID: threadID)
        try await store.rethread(accountID: acct.id)
        summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.first?.isFlagged, false)
    }

    func testFlaggedAndUnreadAreIndependent() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // A read, unflagged message: flagging it must not make it unread, and
        // marking it unread must not flag it.
        let m = msg(id: "<a@x>", subject: "Ping", from: "p@x.com", minutes: 0, seen: true)
        try await store.save([m], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let initial = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(initial.first?.id)

        try await store.setFlagged(true, threadID: threadID)
        try await store.rethread(accountID: acct.id)
        let flagged = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(flagged.first?.isFlagged, true)
        XCTAssertEqual(flagged.first?.isUnread, false)

        try await store.setSeen(false, threadID: threadID)
        try await store.rethread(accountID: acct.id)
        let unread = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(unread.first?.isUnread, true)
        XCTAssertEqual(unread.first?.isFlagged, true)
    }

    func testSetFlaggedMarksEveryMessageInThread() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let a = msg(id: "<a@x>", subject: "Lunch", from: "p@x.com", minutes: 0)
        let b = msg(id: "<b@x>", references: ["<a@x>"], subject: "Re: Lunch", from: "q@x.com", minutes: 1)
        try await store.save([a, b], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let summaries = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(summaries.first?.id)

        try await store.setFlagged(true, threadID: threadID)
        let loaded = try await store.thread(id: threadID)
        let thread = try XCTUnwrap(loaded)
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertTrue(thread.messages.allSatisfy(\.isFlagged))
        XCTAssertTrue(thread.isFlagged)
    }

    func testDeleteThreadRemovesOnlyThatThread() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let keep = msg(id: "<a@x>", subject: "Keep", from: "p@x.com", minutes: 0)
        let drop = msg(id: "<b@x>", subject: "Drop", from: "q@x.com", minutes: 1)
        try await store.save([keep, drop], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let beforeDelete = try await store.threadSummaries(accountID: acct.id)
        let dropID = try XCTUnwrap(beforeDelete.first { $0.subject == "Drop" }?.id)

        try await store.deleteThread(threadID: dropID)
        try await store.rethread(accountID: acct.id)

        let subjects = try await store.threadSummaries(accountID: acct.id).map(\.subject)
        XCTAssertEqual(subjects, ["Keep"])
    }

    func testMessageRefsReturnsOnlyUIDBackedMessages() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // One server message (UID 7 in INBOX) and one local-only copy (no UID),
        // threaded together.
        let server = uidMsg(id: "<a@x>", uid: 7, subject: "Plan", minutes: 0)
        let local = Message(
            messageID: "<b@x>",
            references: ["<a@x>"],
            subject: "Re: Plan",
            from: Participant(address: "me@x.com"),
            date: Date(timeIntervalSince1970: 60),
            flags: [.seen]
        )
        try await store.save([server], accountID: acct.id, mailboxName: "INBOX")
        try await store.save([local], accountID: acct.id, mailboxName: "Sent")
        try await store.rethread(accountID: acct.id)
        let threaded = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(threaded.first?.id)

        let refs = try await store.messageRefs(threadID: threadID)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.uid, 7)
        XCTAssertEqual(refs.first?.mailbox, "INBOX")
    }

    func testUIDValidityRoundTrips() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // No mailbox row yet, then a row whose validity column is still unset.
        let none = try await store.uidValidity(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertNil(none)
        try await store.upsert(Mailbox(accountID: acct.id, name: "INBOX", role: .inbox))
        let unset = try await store.uidValidity(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertNil(unset)

        try await store.setUIDValidity(123456, accountID: acct.id, mailboxName: "INBOX")
        let stored = try await store.uidValidity(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(stored, 123456)

        // Re-upserting the mailbox row must not clobber the recorded validity.
        try await store.upsert(Mailbox(accountID: acct.id, name: "INBOX", role: .inbox))
        let afterUpsert = try await store.uidValidity(accountID: acct.id, mailboxName: "INBOX")
        XCTAssertEqual(afterUpsert, 123456)
    }

    func testCcPersistsAndJoinsParticipants() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        // A message addressed To one person and Cc'ing two others.
        let m = Message(
            messageID: "<a@x>",
            subject: "Kickoff",
            from: Participant(address: "p@x.com"),
            to: [Participant(address: "q@x.com")],
            cc: [Participant(address: "r@x.com"), Participant(address: "s@x.com")],
            date: Date(timeIntervalSince1970: 0),
            flags: [.seen]
        )
        try await store.save([m], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        // Cc survives the store round-trip, kept distinct from To.
        let summaries = try await store.threadSummaries(accountID: acct.id)
        let threadID = try XCTUnwrap(summaries.first?.id)
        let convo = try await store.thread(id: threadID)
        let stored = try XCTUnwrap(convo?.messages.first)
        XCTAssertEqual(stored.to.map(\.address), ["q@x.com"])
        XCTAssertEqual(stored.cc.map(\.address), ["r@x.com", "s@x.com"])

        // Cc recipients count as conversation participants alongside From/To.
        let participants = try XCTUnwrap(convo?.participants)
        XCTAssertEqual(Set(participants.map(\.address)), ["p@x.com", "q@x.com", "r@x.com", "s@x.com"])
    }

    // MARK: - Search

    /// Seed three distinct conversations and return the store. Each carries a
    /// different searchable field so a query can target one in isolation: a
    /// subject, a named sender, a cached body, and a Cc'd recipient.
    private func searchStore() async throws -> (MailStore, Account) {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)

        let budget = Message(
            messageID: "<budget@x>", subject: "Q3 Budget",
            from: Participant(address: "fin@x.com", displayName: "Dana Finance"),
            to: [Participant(address: "me@x.com")],
            date: Date(timeIntervalSince1970: 300), flags: [.seen],
            bodyText: "The forecast spreadsheet is attached for review."
        )
        let lunch = Message(
            messageID: "<lunch@x>", subject: "Lunch Thursday",
            from: Participant(address: "pat@x.com", displayName: "Pat"),
            to: [Participant(address: "me@x.com")],
            cc: [Participant(address: "sam@x.com", displayName: "Sam Rivera")],
            date: Date(timeIntervalSince1970: 200), flags: [.seen],
            bodyText: "Want to grab tacos?"
        )
        let invoice = Message(
            messageID: "<invoice@x>", subject: "Invoice 50% off",
            from: Participant(address: "sales@x.com", displayName: "Acme"),
            to: [Participant(address: "me@x.com")],
            date: Date(timeIntervalSince1970: 100), flags: [.seen],
            bodyText: "Pay within 30 days."
        )
        try await store.save([budget, lunch, invoice], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        return (store, acct)
    }

    func testSearchMatchesSubject() async throws {
        let (store, acct) = try await searchStore()
        let hits = try await store.searchThreads(accountID: acct.id, query: "budget")
        XCTAssertEqual(hits.map(\.subject), ["Q3 Budget"])
    }

    func testSearchMatchesSenderNameAndAddress() async throws {
        let (store, acct) = try await searchStore()
        let byName = try await store.searchThreads(accountID: acct.id, query: "dana")
        XCTAssertEqual(byName.map(\.subject), ["Q3 Budget"])
        let byAddress = try await store.searchThreads(accountID: acct.id, query: "pat@x.com")
        XCTAssertEqual(byAddress.map(\.subject), ["Lunch Thursday"])
    }

    func testSearchMatchesCachedBody() async throws {
        let (store, acct) = try await searchStore()
        let hits = try await store.searchThreads(accountID: acct.id, query: "tacos")
        XCTAssertEqual(hits.map(\.subject), ["Lunch Thursday"])
    }

    func testSearchMatchesRecipient() async throws {
        let (store, acct) = try await searchStore()
        let hits = try await store.searchThreads(accountID: acct.id, query: "sam rivera")
        XCTAssertEqual(hits.map(\.subject), ["Lunch Thursday"])
    }

    func testSearchIsCaseInsensitive() async throws {
        let (store, acct) = try await searchStore()
        let hits = try await store.searchThreads(accountID: acct.id, query: "FORECAST")
        XCTAssertEqual(hits.map(\.subject), ["Q3 Budget"])
    }

    func testSearchOrdersByActivityAndIsThreadLevel() async throws {
        let (store, acct) = try await searchStore()
        // All three bodies/subjects contain a period-free word? Use a token in
        // every message: each subject is distinct, but "me@x.com" is on every
        // message's To, so the query returns all three threads, newest first.
        let hits = try await store.searchThreads(accountID: acct.id, query: "me@x.com")
        XCTAssertEqual(hits.map(\.subject), ["Q3 Budget", "Lunch Thursday", "Invoice 50% off"])
    }

    func testSearchTreatsWildcardCharactersLiterally() async throws {
        let (store, acct) = try await searchStore()
        // The literal "50%" must match only the invoice, not act as a LIKE
        // wildcard that matches everything.
        let hits = try await store.searchThreads(accountID: acct.id, query: "50%")
        XCTAssertEqual(hits.map(\.subject), ["Invoice 50% off"])
    }

    func testSearchEmptyQueryReturnsNothing() async throws {
        let (store, acct) = try await searchStore()
        let blank = try await store.searchThreads(accountID: acct.id, query: "   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testSearchIsScopedToTheAccount() async throws {
        let (store, acct) = try await searchStore()
        // A second account with its own matching mail must not leak into the first
        // account's results.
        let other = Account(emailAddress: "other@y.com", imapHost: "imap.y.com", smtpHost: "smtp.y.com")
        try await store.upsert(other)
        let theirs = Message(
            messageID: "<o@y>", subject: "Budget secrets",
            from: Participant(address: "z@y.com"),
            date: Date(timeIntervalSince1970: 999), flags: [.seen]
        )
        try await store.save([theirs], accountID: other.id, mailboxName: "INBOX")
        try await store.rethread(accountID: other.id)

        let hits = try await store.searchThreads(accountID: acct.id, query: "budget")
        XCTAssertEqual(hits.map(\.subject), ["Q3 Budget"])
    }
}
