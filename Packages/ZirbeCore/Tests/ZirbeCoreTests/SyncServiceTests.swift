// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// SyncService against the in-memory server and sender: reconciliation (prune,
// UIDVALIDITY rebuild, the fetch window, the watermark reseed, the blocklist),
// folder discovery and lazy folder sync, body and attachment fetches, the send
// and draft filing rules, the per-thread mutations grouped by mailbox, and the
// IDLE watch. Every case asserts both sides: what the server was told and what
// the store holds afterward.

import XCTest
import ZirbeMail
@testable import ZirbeCore

final class SyncServiceTests: XCTestCase {
    private let account = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    private let password = "pw"

    private var store: MailStore!
    private var server: FakeMailServer!
    private var sender: FakeMailSender!
    private var sync: SyncService!

    override func setUp() async throws {
        store = try MailStore()
        server = FakeMailServer()
        sender = FakeMailSender()
        sync = SyncService(account: account, store: store, engine: server, sender: sender)
    }

    // MARK: Fixtures

    private func incoming(
        _ subject: String,
        id: String,
        from: String = "Pat <pat@x.com>",
        inReplyTo: String? = nil,
        minutes: Int = 0,
        flags: [String] = []
    ) -> MailEnvelope {
        MailEnvelope(
            subject: subject,
            from: from,
            to: ["me@x.com"],
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            messageID: id,
            inReplyTo: inReplyTo,
            references: inReplyTo.map { [$0] } ?? [],
            flags: flags
        )
    }

    private func newDraft(subject: String = "Hello", body: String = "Hi there") -> OutgoingDraft {
        OutgoingDraft.new(
            from: account,
            to: [Participant(address: "pat@x.com")],
            subject: subject,
            body: body,
            sentAt: Date(timeIntervalSince1970: 5_000)
        )
    }

    private func savedDraft(body: String, id: String = "<draft@x>") -> OutgoingDraft {
        OutgoingDraft.draft(
            from: account,
            to: [Participant(address: "pat@x.com")],
            subject: "Draft",
            body: body,
            messageID: id,
            savedAt: Date(timeIntervalSince1970: 5_000)
        )
    }

    private func inboxSummaries() async throws -> [ThreadSummary] {
        try await store.threadSummaries(accountID: account.id, mailboxName: "INBOX")
    }

    private func allSummaries() async throws -> [ThreadSummary] {
        try await store.threadSummaries(accountID: account.id)
    }

    /// The one thread in the store, for tests that seed a single conversation.
    private func onlyThread() async throws -> ZirbeCore.Thread {
        let summaries = try await allSummaries()
        XCTAssertEqual(summaries.count, 1, "expected exactly one thread")
        let id = try XCTUnwrap(summaries.first?.id)
        let thread = try await store.thread(id: id)
        return try XCTUnwrap(thread)
    }

    /// A conversation split across INBOX and Archive: Pat's opener in the inbox
    /// and a reply the user filed away. Both folders synced.
    private func seedThreadAcrossTwoFolders() async throws -> ZirbeCore.Thread {
        await server.add(incoming("Plan", id: "<a@x>", minutes: 0))
        await server.add(incoming("Re: Plan", id: "<b@x>", inReplyTo: "<a@x>", minutes: 5), to: "Archive")
        try await sync.syncInbox(password: password)
        try await sync.syncFolder(mailbox: "Archive", role: .archive, password: password)
        let thread = try await onlyThread()
        XCTAssertEqual(thread.messages.count, 2)
        return thread
    }

    // MARK: Reconciliation

    func testFirstSyncCachesTheInboxAndItsIdentity() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        await server.add(incoming("Budget", id: "<b@x>", minutes: 1))

        let summaries = try await sync.syncInbox(password: password)

        XCTAssertEqual(summaries.map(\.subject), ["Budget", "Plan"], "most recent activity first")
        let validity = try await store.uidValidity(accountID: account.id, mailboxName: "INBOX")
        XCTAssertEqual(validity, 1000)
        let mailboxes = try await store.mailboxes(accountID: account.id)
        XCTAssertEqual(mailboxes.first { $0.name == "INBOX" }?.role, .inbox)
        let calls = await server.calls
        XCTAssertEqual(calls.first, .connect(username: account.username))
    }

    func testDeletionMadeElsewhereIsPrunedOnTheNextSync() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        let gone = await server.add(incoming("Spam", id: "<b@x>", minutes: 1))
        try await sync.syncInbox(password: password)

        await server.delete(uid: gone)
        let summaries = try await sync.syncInbox(password: password)

        XCTAssertEqual(summaries.map(\.subject), ["Plan"])
    }

    func testUIDValidityChangeRebuildsTheCacheUnderTheNewNumbering() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        await server.add(incoming("Budget", id: "<b@x>", minutes: 1))
        try await sync.syncInbox(password: password)
        // Someone deletes Plan, then the server renumbers.
        await server.delete(uid: 1)
        await server.renumber()

        let summaries = try await sync.syncInbox(password: password)

        XCTAssertEqual(summaries.map(\.subject), ["Budget"])
        let validity = try await store.uidValidity(accountID: account.id, mailboxName: "INBOX")
        XCTAssertEqual(validity, 1001)
        let ref = try await store.messageRef(id: "mid:<b@x>")
        XCTAssertEqual(ref?.uid, 1, "the cached row carries the reissued UID, not the stale one")
    }

    func testRenumberReseedsTheNotificationMarkSoOnlyLaterMailNotifies() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        try await sync.syncInbox(password: password)
        try await store.markNotificationWatermark(accountID: account.id)

        await server.renumber()
        try await sync.syncInbox(password: password)
        let rebuilt = try await store.unnotifiedInboxArrivals(accountID: account.id)
        XCTAssertTrue(rebuilt.isEmpty, "the rebuilt inbox is not announced wholesale")

        await server.add(incoming("New", id: "<n@x>", minutes: 2))
        try await sync.syncInbox(password: password)
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: account.id)
        XCTAssertEqual(arrivals.map(\.subject), ["New"])
    }

    func testMailOlderThanTheFetchWindowSurvivesPruning() async throws {
        for i in 0..<3 {
            await server.add(incoming("Old \(i)", id: "<o\(i)@x>", minutes: i))
        }
        try await sync.syncInbox(password: password, limit: 3)
        await server.add(incoming("New", id: "<n@x>", minutes: 10))

        let summaries = try await sync.syncInbox(password: password, limit: 2)

        XCTAssertEqual(summaries.count, 4, "the keep-set is the server's full UID list, not the window")
        let fetches = await server.calls(.fetchRecentEnvelopes)
        XCTAssertEqual(fetches.last, .fetchRecentEnvelopes(mailbox: "INBOX", limit: 2))
    }

    func testSnippetBackfillFetchesOnlyTheNewestMessagePerThread() async throws {
        await server.add(incoming("Plan", id: "<a@x>", minutes: 0), body: MessageBody(text: "first", hasHTML: false))
        await server.add(incoming("Re: Plan", id: "<b@x>", inReplyTo: "<a@x>", minutes: 5), body: MessageBody(text: "second", hasHTML: true))

        let summaries = try await sync.syncInbox(password: password)

        XCTAssertEqual(summaries.first?.preview, "second")
        let fetches = await server.calls(.fetchTextBodies)
        XCTAssertEqual(fetches, [.fetchTextBodies(mailbox: "INBOX", uids: [2])])
        let thread = try await onlyThread()
        XCTAssertEqual(thread.messages.map(\.bodyText), [nil, "second"])
        XCTAssertEqual(thread.messages.last?.hasHTML, true)
    }

    func testSnippetBackfillFailureDoesNotSinkTheSync() async throws {
        await server.add(incoming("Plan", id: "<a@x>"), body: MessageBody(text: "first", hasHTML: false))
        await server.fail(.fetchTextBodies)

        let summaries = try await sync.syncInbox(password: password)

        XCTAssertEqual(summaries.map(\.subject), ["Plan"])
        XCTAssertNil(summaries.first?.preview)
    }

    func testConnectionFailureLeavesTheStoreUntouched() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        await server.fail(.connect)

        do {
            try await sync.syncInbox(password: password)
            XCTFail("expected the connect failure to propagate")
        } catch let error as FakeMailServer.ScriptedFailure {
            XCTAssertEqual(error.operation, .connect)
        }
        let summaries = try await inboxSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    func testBlockedSenderMailIsJunkedDuringTheInboxSync() async throws {
        try await store.upsert(account)
        try await store.setBlocked(true, address: "spam@x.com", accountID: account.id)
        await server.add(incoming("Plan", id: "<a@x>"))
        await server.add(incoming("Deal", id: "<s@x>", from: "Spam <spam@x.com>", minutes: 1))

        let summaries = try await sync.syncInbox(password: password)

        XCTAssertEqual(summaries.map(\.subject), ["Plan"])
        let inbox = await server.messages(in: "INBOX").map(\.subject)
        XCTAssertEqual(inbox, ["Plan"])
        let junk = await server.messages(in: "Junk").map(\.subject)
        XCTAssertEqual(junk, ["Deal"])
        let junked = await server.calls(.markJunk)
        XCTAssertEqual(junked, [.markJunk(mailbox: "INBOX", uids: [2])])
    }

    // MARK: Folders

    func testSyncFolderScopesItsListToThatFolder() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        await server.add(incoming("Filed", id: "<f@x>"), to: "Archive")
        try await sync.syncInbox(password: password)

        let archived = try await sync.syncFolder(mailbox: "Archive", role: .archive, password: password)

        XCTAssertEqual(archived.map(\.subject), ["Filed"])
        let inbox = try await inboxSummaries()
        XCTAssertEqual(inbox.map(\.subject), ["Plan"])
        let mailboxes = try await store.mailboxes(accountID: account.id)
        XCTAssertEqual(mailboxes.first { $0.name == "Archive" }?.role, .archive)
    }

    func testDiscoverFoldersMapsRolesAndDropsContainers() async throws {
        await server.addFolder(MailboxInfo(name: "Projects", hierarchyDelimiter: "/"))
        await server.addFolder(MailboxInfo(name: "[Gmail]", isSelectable: false))

        let discovered = try await sync.discoverFolders(password: password)

        let byName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
        XCTAssertEqual(byName["INBOX"]?.role, .inbox)
        XCTAssertEqual(byName["Junk"]?.role, .junk)
        XCTAssertNil(byName["Projects"]?.role)
        XCTAssertEqual(byName["Projects"]?.hierarchyDelimiter, "/")
        XCTAssertNil(byName["[Gmail]"], "a container-only folder holds no mail to browse")
        let cached = try await store.mailboxes(accountID: account.id).map(\.name)
        XCTAssertEqual(Set(cached), Set(discovered.map(\.name)))
    }

    // MARK: Bodies and attachments

    func testLoadConversationFetchesMissingBodiesOnceThenReadsTheCache() async throws {
        await server.add(incoming("Plan", id: "<a@x>", minutes: 0), body: MessageBody(text: "first", hasHTML: false))
        await server.add(incoming("Re: Plan", id: "<b@x>", inReplyTo: "<a@x>", minutes: 5), body: MessageBody(text: "second", hasHTML: false))
        try await sync.syncInbox(password: password)
        let id = try await onlyThread().id

        let firstOpen = try await sync.loadConversation(id: id, password: password)
        let opened = try XCTUnwrap(firstOpen)
        XCTAssertEqual(opened.messages.map(\.bodyText), ["first", "second"])
        let fetchesAfterOpen = await server.calls(.fetchTextBodies)
        XCTAssertEqual(fetchesAfterOpen.last, .fetchTextBodies(mailbox: "INBOX", uids: [1]), "only the body the backfill skipped")

        _ = try await sync.loadConversation(id: id, password: password)
        let fetchesAfterReopen = await server.calls(.fetchTextBodies)
        XCTAssertEqual(fetchesAfterReopen.count, fetchesAfterOpen.count, "a second open is served from the store")

        let unknown = try await sync.loadConversation(id: "nope", password: password)
        XCTAssertNil(unknown)
    }

    func testFetchHTMLBodyCarriesInlineImages() async throws {
        let logo = Data([0x89, 0x50])
        await server.add(
            incoming("Plan", id: "<a@x>"),
            html: HTMLBody(html: "<p>hi</p>", images: [InlineImagePart(contentID: "logo", mimeType: "image/png", data: logo)])
        )
        await server.add(incoming("Plain", id: "<p@x>", minutes: 1))
        try await sync.syncInbox(password: password)

        let fetched = try await sync.fetchHTMLBody(messageID: "mid:<a@x>", password: password)
        let body = try XCTUnwrap(fetched)
        XCTAssertEqual(body.html, "<p>hi</p>")
        XCTAssertEqual(body.inlineImages.map(\.contentID), ["logo"])
        XCTAssertEqual(body.inlineImages.first?.data, logo)

        let plain = try await sync.fetchHTMLBody(messageID: "mid:<p@x>", password: password)
        XCTAssertNil(plain, "a message without HTML yields nothing")
        let unknown = try await sync.fetchHTMLBody(messageID: "mid:<zzz@x>", password: password)
        XCTAssertNil(unknown)
    }

    func testFetchAttachmentPullsThePartOverTheSession() async throws {
        let bytes = Data("hello".utf8)
        let uid = await server.add(incoming("Plan", id: "<a@x>"))
        await server.addAttachment(bytes, to: "INBOX", uid: uid, partID: "2")
        try await sync.syncInbox(password: password)

        let data = try await sync.fetchAttachment(messageID: "mid:<a@x>", partID: "2", password: password)
        XCTAssertEqual(data, bytes)

        do {
            _ = try await sync.fetchAttachment(messageID: "mid:<a@x>", partID: "9", password: password)
            XCTFail("a missing part throws from the engine")
        } catch MailEngineError.partNotFound {}

        let unknown = try await sync.fetchAttachment(messageID: "mid:<zzz@x>", partID: "2", password: password)
        XCTAssertNil(unknown, "an unknown message has nothing to fetch")
    }

    // MARK: Sending

    func testSendFilesALocalCopyAndAServerSentCopy() async throws {
        let draft = newDraft()

        try await sync.send(draft, password: password)

        let delivered = await sender.sent.map(\.messageID)
        XCTAssertEqual(delivered, [draft.messageID])
        let copies = await server.sentCopies.map(\.messageID)
        XCTAssertEqual(copies, [draft.messageID])
        let thread = try await onlyThread()
        XCTAssertEqual(thread.messages.first?.sendState, .sent)
        XCTAssertEqual(thread.subject, "Hello")
        let inbox = try await inboxSummaries()
        XCTAssertTrue(inbox.isEmpty, "a sent-only conversation stays out of the inbox")
    }

    func testRefusedSendStoresNothing() async throws {
        await sender.failNext()

        do {
            try await sync.send(newDraft(), password: password)
            XCTFail("expected the SMTP failure to propagate")
        } catch is FakeMailSender.ScriptedFailure {}

        let summaries = try await allSummaries()
        XCTAssertTrue(summaries.isEmpty)
        let copies = await server.sentCopies
        XCTAssertTrue(copies.isEmpty, "nothing reaches Sent for mail that never went")
    }

    func testFailedSentCopyKeepsTheLocalCopy() async throws {
        await server.fail(.saveToSent)

        try await sync.send(newDraft(), password: password)

        let thread = try await onlyThread()
        XCTAssertEqual(thread.messages.first?.sendState, .sent, "the mail went; the server copy is a reconciliation detail")
        let copies = await server.sentCopies
        XCTAssertTrue(copies.isEmpty)
    }

    func testRecordLocalFlipsAFailedBubbleToSentInPlace() async throws {
        let draft = newDraft()

        try await sync.recordLocal(draft, state: .failed)
        let failed = try await onlyThread()
        XCTAssertEqual(failed.messages.map(\.sendState), [.failed])

        try await sync.recordLocal(draft, state: .sent)
        let sent = try await onlyThread()
        XCTAssertEqual(sent.messages.map(\.sendState), [.sent], "the same Message-ID upserts one row")
    }

    // MARK: Drafts

    func testSaveDraftReplacesThePriorServerCopyOnEdit() async throws {
        let first = try await sync.saveDraft(savedDraft(body: "v1"), password: password)
        XCTAssertEqual(first, 1)

        let second = try await sync.saveDraft(savedDraft(body: "v2"), password: password)

        XCTAssertEqual(second, 2)
        let appends = await server.calls(.saveToDrafts)
        XCTAssertEqual(appends, [
            .saveToDrafts(messageID: "<draft@x>", replacing: nil),
            .saveToDrafts(messageID: "<draft@x>", replacing: 1),
        ])
        let serverDrafts = await server.uids(in: "Drafts")
        XCTAssertEqual(serverDrafts, [2], "the edit replaced the old copy rather than stacking")
        let local = try await store.threadSummaries(accountID: account.id, mailboxName: "Drafts")
        XCTAssertEqual(local.count, 1)
        let thread = try await onlyThread()
        XCTAssertEqual(thread.messages.first?.bodyText, "v2")
    }

    func testRefusedDraftAppendStoresNothing() async throws {
        await server.fail(.saveToDrafts)

        do {
            try await sync.saveDraft(savedDraft(body: "v1"), password: password)
            XCTFail("expected the APPEND failure to propagate")
        } catch is FakeMailServer.ScriptedFailure {}

        let local = try await store.threadSummaries(accountID: account.id, mailboxName: "Drafts")
        XCTAssertTrue(local.isEmpty)
    }

    func testDeleteDraftExpungesTheServerCopyAndDropsTheThread() async throws {
        try await sync.saveDraft(savedDraft(body: "v1"), password: password)
        let id = try await onlyThread().id

        try await sync.deleteDraft(threadID: id, password: password)

        let removed = await server.calls(.removeDraft)
        XCTAssertEqual(removed, [.removeDraft(uid: 1)])
        let serverDrafts = await server.uids(in: "Drafts")
        XCTAssertTrue(serverDrafts.isEmpty)
        let summaries = try await allSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: Flags

    func testSetReadReachesEveryFolderTheThreadSpans() async throws {
        let thread = try await seedThreadAcrossTwoFolders()

        try await sync.setRead(threadID: thread.id, seen: true, password: password)

        let calls = await server.calls(.setSeen)
        XCTAssertEqual(Set(calls), [
            .setSeen(true, mailbox: "INBOX", uids: [1]),
            .setSeen(true, mailbox: "Archive", uids: [1]),
        ])
        let inboxFlags = await server.messages(in: "INBOX").first?.flags
        XCTAssertEqual(inboxFlags, ["\\Seen"])
        let summary = try await allSummaries().first
        XCTAssertEqual(summary?.isUnread, false)

        try await sync.setRead(threadID: thread.id, seen: false, password: password)
        let reread = try await allSummaries().first
        XCTAssertEqual(reread?.isUnread, true)
    }

    func testSetFlaggedReachesEveryFolderTheThreadSpans() async throws {
        let thread = try await seedThreadAcrossTwoFolders()

        try await sync.setFlagged(threadID: thread.id, flagged: true, password: password)

        let calls = await server.calls(.setFlagged)
        XCTAssertEqual(Set(calls), [
            .setFlagged(true, mailbox: "INBOX", uids: [1]),
            .setFlagged(true, mailbox: "Archive", uids: [1]),
        ])
        let archiveFlags = await server.messages(in: "Archive").first?.flags
        XCTAssertEqual(archiveFlags, ["\\Flagged"])
        let summary = try await allSummaries().first
        XCTAssertEqual(summary?.isFlagged, true)
    }

    // MARK: Moves

    func testTrashMovesEveryMessageAndDropsTheThread() async throws {
        let thread = try await seedThreadAcrossTwoFolders()

        try await sync.trash(threadID: thread.id, password: password)

        let inbox = await server.uids(in: "INBOX")
        let archive = await server.uids(in: "Archive")
        let trash = await server.messages(in: "Trash").map(\.subject)
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertTrue(archive.isEmpty)
        XCTAssertEqual(Set(trash), ["Plan", "Re: Plan"])
        let summaries = try await allSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    func testArchiveJunkAndMoveFileIntoTheirFolders() async throws {
        await server.add(incoming("A", id: "<a@x>", minutes: 0))
        await server.add(incoming("J", id: "<j@x>", minutes: 1))
        await server.add(incoming("M", id: "<m@x>", minutes: 2))
        let summaries = try await sync.syncInbox(password: password)
        let ids = Dictionary(uniqueKeysWithValues: summaries.map { ($0.subject, $0.id) })

        try await sync.archive(threadID: ids["A"]!, password: password)
        try await sync.junk(threadID: ids["J"]!, password: password)
        try await sync.move(threadID: ids["M"]!, to: "Projects", password: password)

        let archive = await server.messages(in: "Archive").map(\.subject)
        let junk = await server.messages(in: "Junk").map(\.subject)
        let projects = await server.messages(in: "Projects").map(\.subject)
        let inbox = await server.uids(in: "INBOX")
        XCTAssertEqual(archive, ["A"])
        XCTAssertEqual(junk, ["J"])
        XCTAssertEqual(projects, ["M"])
        XCTAssertTrue(inbox.isEmpty)
        let remaining = try await inboxSummaries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testServerRefusalLeavesTheStoreIntact() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        let synced = try await sync.syncInbox(password: password)
        let id = try XCTUnwrap(synced.first?.id)
        await server.fail(.trash)

        do {
            try await sync.trash(threadID: id, password: password)
            XCTFail("expected the server refusal to propagate")
        } catch is FakeMailServer.ScriptedFailure {}

        let summaries = try await inboxSummaries()
        XCTAssertEqual(summaries.map(\.subject), ["Plan"], "the local copy stays until the server agrees")
        let inbox = await server.uids(in: "INBOX")
        XCTAssertEqual(inbox, [1])
    }

    func testLocalOnlyThreadIsDroppedWithoutAServerCall() async throws {
        try await sync.recordLocal(newDraft(), state: .failed)
        let id = try await onlyThread().id

        try await sync.trash(threadID: id, password: password)

        let trashed = await server.calls(.trash)
        XCTAssertTrue(trashed.isEmpty, "a never-delivered bubble has no server copy to move")
        let summaries = try await allSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    func testBulkCallersCanDeferTheRethread() async throws {
        await server.add(incoming("A", id: "<a@x>", minutes: 0))
        await server.add(incoming("B", id: "<b@x>", minutes: 1))
        let ids = try await sync.syncInbox(password: password).map(\.id)

        for id in ids {
            try await sync.trash(threadID: id, password: password, rethread: false)
        }
        try await sync.rethread()

        let summaries = try await inboxSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: Watching

    func testWatchInboxYieldsOnServerChangesAndEndsWhenStopped() async throws {
        let changes = try await sync.watchInbox(password: password)
        var iterator = changes.makeAsyncIterator()
        let watching = await server.isWatching
        XCTAssertTrue(watching)

        await server.tick()
        let first: Void? = await iterator.next()
        XCTAssertNotNil(first)

        await sync.stopWatching()
        let end: Void? = await iterator.next()
        XCTAssertNil(end, "stopping the watch finishes the stream")
        let stillWatching = await server.isWatching
        XCTAssertFalse(stillWatching)
    }

    func testDisconnectClosesTheSession() async throws {
        try await sync.syncInbox(password: password)
        let before = await server.session
        XCTAssertNotNil(before)

        await sync.disconnect()

        let after = await server.session
        XCTAssertNil(after)
    }
}
