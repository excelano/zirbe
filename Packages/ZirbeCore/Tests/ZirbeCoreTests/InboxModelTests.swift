// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// InboxModel against the in-memory server and sender: the session (sign-in,
// refresh, cached load, sign-out), the send guardrails and the reply target,
// reactions, new conversations and forwards, the draft round trip, read, flag,
// and pin, the bulk mutations with their optimistic row removal and rollback,
// folder switching, blocking, search, and the live-refresh watch. The model is
// main-actor isolated, so the whole suite runs there.

import XCTest
import ZirbeMail
@testable import ZirbeCore

@MainActor
final class InboxModelTests: XCTestCase {
    private let account = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    private let pat = Participant(address: "pat@x.com")
    private let notConnected = "Connect an account first."

    private var store: MailStore!
    private var server: FakeMailServer!
    private var sender: FakeMailSender!
    private var model: InboxModel!

    override func setUp() async throws {
        store = try MailStore()
        server = FakeMailServer()
        sender = FakeMailSender()
        let sync = SyncService(account: account, store: store, engine: server, sender: sender)
        model = InboxModel(account: account, store: store, sync: sync)
    }

    // MARK: Fixtures

    private func incoming(
        _ subject: String,
        id: String,
        from: String = "Pat <pat@x.com>",
        inReplyTo: String? = nil,
        minutes: Int = 0,
        seen: Bool = false
    ) -> MailEnvelope {
        MailEnvelope(
            subject: subject,
            from: from,
            to: ["me@x.com"],
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            messageID: id,
            inReplyTo: inReplyTo,
            references: inReplyTo.map { [$0] } ?? [],
            flags: seen ? ["\\Seen"] : []
        )
    }

    /// Seed one inbox conversation and sign in, returning it opened.
    private func signInWithPlan() async throws -> ZirbeCore.Thread {
        await server.add(incoming("Plan", id: "<a@x>"), body: MessageBody(text: "Lunch?", hasHTML: false))
        try await model.signIn(password: "pw")
        return try await openFirstConversation()
    }

    private func openFirstConversation() async throws -> ZirbeCore.Thread {
        let id = try XCTUnwrap(model.summaries.first?.id)
        let thread = await model.conversation(id: id)
        return try XCTUnwrap(thread)
    }

    private func summary(_ subject: String) throws -> ThreadSummary {
        try XCTUnwrap(model.summaries.first { $0.subject == subject }, "no row titled \(subject)")
    }

    private func allSummaries() async throws -> [ThreadSummary] {
        try await store.threadSummaries(accountID: account.id)
    }

    private func draftSummaries() async throws -> [ThreadSummary] {
        try await store.threadSummaries(accountID: account.id, mailboxName: "Drafts")
    }

    /// Poll until `condition` holds or a short deadline passes, for the few
    /// cases that cross into a detached task (the live watch, sign-out).
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: Session

    func testSignInSyncsTheInboxAndSettlesTheNotificationMark() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))

        try await model.signIn(password: "pw")

        XCTAssertTrue(model.isConnected)
        XCTAssertFalse(model.isSyncing)
        XCTAssertEqual(model.summaries.map(\.subject), ["Plan"])
        XCTAssertEqual(model.unreadCounts["INBOX"], 1)
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: account.id)
        XCTAssertTrue(arrivals.isEmpty, "mail present at sign-in is already seen, not announced")
    }

    func testFailedSignInDropsThePassword() async throws {
        await server.fail(.connect)

        do {
            try await model.signIn(password: "wrong")
            XCTFail("expected the sync failure to propagate")
        } catch {}

        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isSyncing)
        XCTAssertTrue(model.summaries.isEmpty)
    }

    func testRefreshWithoutAConnectionSetsTheError() async {
        await model.refresh()
        XCTAssertEqual(model.errorMessage, notConnected)
    }

    func testRefreshSurfacesASyncFailureAndKeepsTheList() async throws {
        _ = try await signInWithPlan()
        await server.fail(.connect)

        await model.refresh()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.summaries.map(\.subject), ["Plan"], "the cached list outlives a failed refresh")
        XCTAssertFalse(model.isSyncing)
    }

    func testLoadCachedReadsTheStoreWithoutTheNetwork() async throws {
        try await store.upsert(account)
        try await store.save([Message(incoming("Cached", id: "<c@x>"))], accountID: account.id, mailboxName: "INBOX")
        try await store.rethread(accountID: account.id)

        await model.loadCached()

        XCTAssertEqual(model.summaries.map(\.subject), ["Cached"])
        let calls = await server.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSignOutClearsTheSessionAndDisconnects() async throws {
        _ = try await signInWithPlan()
        await model.selectMailbox(Mailbox(accountID: account.id, name: "Archive", role: .archive))

        model.signOut()

        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertTrue(model.isViewingInbox, "the next sign-in starts at home")
        let disconnected = await eventually { await self.server.session == nil }
        XCTAssertTrue(disconnected)
    }

    // MARK: Replies

    func testReplyGuardrailsLeaveTheDraftAlone() async throws {
        let thread = try await signInWithPlan()

        let empty = await model.sendReply(to: thread, body: "   ")
        XCTAssertNil(empty)
        XCTAssertEqual(model.errorMessage, "Write a message or attach a file before sending.")

        let nobody = await model.sendReply(to: thread, removing: ["pat@x.com"], body: "Hi")
        XCTAssertNil(nobody)
        XCTAssertEqual(model.errorMessage, "A reply needs at least one recipient.")

        let attempts = await sender.attempts
        XCTAssertTrue(attempts.isEmpty)
    }

    func testReplyWithoutAConnectionReturnsNil() async throws {
        let thread = ZirbeCore.Thread(id: "t", subject: "Plan", messages: [Message(incoming("Plan", id: "<a@x>"))], participants: [pat], lastActivity: nil)

        let result = await model.sendReply(to: thread, body: "Hi")

        XCTAssertNil(result)
        XCTAssertEqual(model.errorMessage, notConnected)
    }

    func testReplyAimedAtAnEarlierMessageThreadsOntoIt() async throws {
        await server.add(incoming("Plan", id: "<a@x>", minutes: 0))
        await server.add(incoming("Re: Plan", id: "<b@x>", inReplyTo: "<a@x>", minutes: 5))
        try await model.signIn(password: "pw")
        let thread = try await openFirstConversation()

        let updated = await model.sendReply(to: thread, body: "About the first one", replyingToMessageID: "<a@x>")

        XCTAssertEqual(updated?.messages.count, 3)
        let sent = await sender.sent
        XCTAssertEqual(sent.first?.inReplyTo, "<a@x>", "the swipe target, not the newest message")
    }

    func testRetryAfterARelaunchHasNoDraftToResend() async throws {
        let thread = try await signInWithPlan()

        let result = await model.retrySend(messageID: "<never-held@x>", in: thread.id)

        XCTAssertNil(result)
        XCTAssertFalse(model.canRetry(messageID: "<never-held@x>"))
    }

    // MARK: Reactions

    func testReactionRidesItsHeaderAndLandsAsABadge() async throws {
        let thread = try await signInWithPlan()

        let updated = await model.sendReaction("👍", to: "<a@x>", in: thread)

        let sent = await sender.sent
        XCTAssertEqual(sent.first?.headers[MailHeader.zirbeReaction], "👍")
        XCTAssertEqual(sent.first?.inReplyTo, "<a@x>")
        XCTAssertEqual(updated?.reactions(forMessageID: "<a@x>").map(\.emoji), ["👍"])
        XCTAssertEqual(updated?.conversationMessages.count, 1, "a reaction is a badge, not a bubble")
    }

    func testRefusedReactionSurfacesAnErrorAndChangesNothing() async throws {
        let thread = try await signInWithPlan()
        await sender.failNext()

        let updated = await model.sendReaction("👍", to: "<a@x>", in: thread)

        XCTAssertEqual(model.errorMessage, "Couldn't send your reaction. Try again.")
        XCTAssertEqual(updated?.messages.count, 1)
    }

    func testReactionToAnUnknownTargetIsRefused() async throws {
        let thread = try await signInWithPlan()

        let updated = await model.sendReaction("👍", to: "<missing@x>", in: thread)

        XCTAssertNil(updated)
        let attempts = await sender.attempts
        XCTAssertTrue(attempts.isEmpty)
    }

    // MARK: New conversations and forwards

    func testNewConversationGuardrails() async throws {
        try await model.signIn(password: "pw")

        let bodiless = await model.sendNew(to: [pat], subject: "Hi", body: " ")
        XCTAssertFalse(bodiless)
        XCTAssertEqual(model.errorMessage, "Write a message or attach a file before sending.")

        let unaddressed = await model.sendNew(to: [], subject: "Hi", body: "Hello")
        XCTAssertFalse(unaddressed)
        XCTAssertEqual(model.errorMessage, "Add at least one recipient.")

        model.signOut()
        let offline = await model.sendNew(to: [pat], subject: "Hi", body: "Hello")
        XCTAssertFalse(offline)
        XCTAssertEqual(model.errorMessage, notConnected)
    }

    func testUnnamedConversationGoesOutUnderTheDefaultSubject() async throws {
        try await model.signIn(password: "pw")

        let sent = await model.sendNew(to: [pat], subject: "  ", body: "Hello")

        XCTAssertTrue(sent)
        let delivered = await sender.sent
        XCTAssertEqual(delivered.first?.subject, ConversationDefaults.unnamedSubject)
        let threads = try await allSummaries()
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(model.summaries.isEmpty, "a sent-only conversation stays out of the inbox")
    }

    func testSendingADraftDiscardsItsSavedCopy() async throws {
        try await model.signIn(password: "pw")
        let contextResult = await model.saveDraft(to: [pat], subject: "Hi", body: "half")
        let context = try XCTUnwrap(contextResult)
        let savedDrafts = try await draftSummaries()
        XCTAssertEqual(savedDrafts.count, 1)

        let sent = await model.sendNew(to: [pat], subject: "Hi", body: "finished", discardingDraft: context)

        XCTAssertTrue(sent)
        let remaining = try await draftSummaries()
        XCTAssertTrue(remaining.isEmpty)
        let serverDrafts = await server.uids(in: "Drafts")
        XCTAssertTrue(serverDrafts.isEmpty)
    }

    func testRefusedNewConversationReportsTheError() async throws {
        try await model.signIn(password: "pw")
        await sender.failNext()

        let sent = await model.sendNew(to: [pat], subject: "Hi", body: "Hello")

        XCTAssertFalse(sent)
        XCTAssertNotNil(model.errorMessage)
        let threads = try await allSummaries()
        XCTAssertTrue(threads.isEmpty)
    }

    func testForwardCarriesTheFilesUnderAFwdSubject() async throws {
        let bytes = Data("report".utf8)
        let uid = await server.add(
            incoming("Plan", id: "<a@x>"),
            body: MessageBody(text: "See attached", hasHTML: false, attachments: [AttachmentInfo(filename: "q.pdf", mimeType: "application/pdf", partID: "2")])
        )
        await server.addAttachment(bytes, to: "INBOX", uid: uid, partID: "2")
        try await model.signIn(password: "pw")
        let thread = try await openFirstConversation()
        let message = try XCTUnwrap(thread.messages.first)

        let sent = await model.sendForward(message, in: thread, to: [Participant(address: "sam@x.com")], cc: [], note: "FYI")

        XCTAssertTrue(sent)
        let deliveredResult = await sender.sent.first
        let delivered = try XCTUnwrap(deliveredResult)
        XCTAssertEqual(delivered.subject, "Fwd: Plan")
        XCTAssertEqual(delivered.to.map(\.address), ["sam@x.com"])
        XCTAssertEqual(delivered.attachments.map(\.filename), ["q.pdf"])
        XCTAssertEqual(delivered.attachments.first?.data, bytes)
        XCTAssertTrue(delivered.textBody.hasPrefix("FYI"))
    }

    func testForwardRequiresARecipient() async throws {
        let thread = try await signInWithPlan()
        let message = try XCTUnwrap(thread.messages.first)

        let sent = await model.sendForward(message, in: thread, to: [], cc: [], note: "")

        XCTAssertFalse(sent)
        XCTAssertEqual(model.errorMessage, "Add at least one recipient.")
    }

    // MARK: Drafts

    func testDraftRoundTripsThroughSaveAndLoad() async throws {
        try await model.signIn(password: "pw")

        let contextResult = await model.saveDraft(to: [pat], subject: "Later", body: "half done")

        let context = try XCTUnwrap(contextResult)
        let editResult = await model.loadDraft(threadID: context.threadID)
        let edit = try XCTUnwrap(editResult)

        XCTAssertEqual(edit.context, context)
        XCTAssertEqual(edit.to, [pat])
        XCTAssertEqual(edit.subject, "Later")
        XCTAssertEqual(edit.body, "half done")
    }

    func testEditingADraftReplacesItRatherThanStacking() async throws {
        try await model.signIn(password: "pw")
        let contextResult = await model.saveDraft(to: [pat], subject: "Later", body: "v1")
        let context = try XCTUnwrap(contextResult)

        let again = await model.saveDraft(to: [pat], subject: "Later", body: "v2", editing: context)

        XCTAssertEqual(again, context, "an edit keeps the Message-ID")
        let serverDrafts = await server.uids(in: "Drafts")
        XCTAssertEqual(serverDrafts.count, 1)
        let local = try await draftSummaries()
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local.first?.preview, "v2")
    }

    func testDiscardingADraftRemovesItEverywhere() async throws {
        try await model.signIn(password: "pw")
        let contextResult = await model.saveDraft(to: [pat], subject: "Later", body: "v1")
        let context = try XCTUnwrap(contextResult)

        await model.deleteDraft(context)

        XCTAssertNil(model.errorMessage)
        let local = try await draftSummaries()
        XCTAssertTrue(local.isEmpty)
        let serverDrafts = await server.uids(in: "Drafts")
        XCTAssertTrue(serverDrafts.isEmpty)
    }

    func testDraftActionsWithoutAConnectionSetTheError() async {
        let saved = await model.saveDraft(to: [pat], subject: "x", body: "y")
        XCTAssertNil(saved)
        XCTAssertEqual(model.errorMessage, notConnected)

        let loaded = await model.loadDraft(threadID: "mid:<x@x>")
        XCTAssertNil(loaded)

        await model.deleteDraft(DraftContext(messageID: "<x@x>"))
        XCTAssertEqual(model.errorMessage, notConnected)
    }

    func testRefusedDraftSaveReportsAndStoresNothing() async throws {
        try await model.signIn(password: "pw")
        await server.fail(.saveToDrafts)

        let context = await model.saveDraft(to: [pat], subject: "x", body: "y")

        XCTAssertNil(context)
        XCTAssertNotNil(model.errorMessage)
        let local = try await draftSummaries()
        XCTAssertTrue(local.isEmpty)
    }

    // MARK: Read, flag, pin

    func testOpeningAnUnreadConversationMarksItReadOnce() async throws {
        let thread = try await signInWithPlan()
        XCTAssertTrue(thread.isUnread)

        await model.markReadOnOpen(thread)
        XCTAssertEqual(model.summaries.first?.isUnread, false)
        XCTAssertNil(model.unreadCounts["INBOX"], "a folder with nothing unread carries no badge entry")

        let reopened = try await openFirstConversation()
        await model.markReadOnOpen(reopened)
        let seenCalls = await server.calls(.setSeen)
        XCTAssertEqual(seenCalls.count, 1, "already-read mail costs no round trip")
    }

    func testMarkUnreadAndFlagReflectInTheRows() async throws {
        let thread = try await signInWithPlan()
        await model.markRead(threadID: thread.id, read: true)

        await model.markRead(threadID: thread.id, read: false)
        XCTAssertEqual(model.summaries.first?.isUnread, true)

        await model.markFlagged(threadID: thread.id, flagged: true)
        XCTAssertEqual(model.summaries.first?.isFlagged, true)
        let flags = await server.messages(in: "INBOX").first?.flags
        XCTAssertEqual(Set(flags ?? []), ["\\Flagged"])
    }

    func testPinningReordersLocallyWithNoServerCall() async throws {
        await server.add(incoming("Older", id: "<o@x>", minutes: 0))
        await server.add(incoming("Newer", id: "<n@x>", minutes: 5))
        try await model.signIn(password: "pw")
        XCTAssertEqual(model.summaries.map(\.subject), ["Newer", "Older"])
        let callsBefore = await server.calls.count

        await model.setPinned(threadID: try summary("Older").id, pinned: true)

        XCTAssertEqual(model.summaries.map(\.subject), ["Older", "Newer"])
        XCTAssertEqual(model.summaries.first?.isPinned, true)
        let callsAfter = await server.calls.count
        XCTAssertEqual(callsAfter, callsBefore)
    }

    // MARK: Bulk mutations

    func testTrashDropsTheRowsAndMovesTheMailOnTheServer() async throws {
        for (i, subject) in ["A", "B", "C"].enumerated() {
            await server.add(incoming(subject, id: "<\(subject)@x>", minutes: i))
        }
        try await model.signIn(password: "pw")

        await model.trash(threadIDs: [try summary("A").id, try summary("B").id])

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.summaries.map(\.subject), ["C"])
        let trashed = await server.messages(in: "Trash").map(\.subject)
        XCTAssertEqual(Set(trashed), ["A", "B"])
        XCTAssertEqual(model.unreadCounts["INBOX"], 1)
    }

    func testARefusedTrashBringsTheRowBackWithTheReason() async throws {
        _ = try await signInWithPlan()
        await server.fail(.trash)

        await model.trash(try summary("Plan"))

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.summaries.map(\.subject), ["Plan"], "the optimistic removal is undone by the reload")
        let inbox = await server.uids(in: "INBOX")
        XCTAssertEqual(inbox.count, 1)
    }

    func testArchiveJunkAndMoveEachLeaveTheInbox() async throws {
        for (i, subject) in ["A", "J", "M"].enumerated() {
            await server.add(incoming(subject, id: "<\(subject)@x>", minutes: i))
        }
        try await model.signIn(password: "pw")

        await model.archive(try summary("A"))
        await model.junk(try summary("J"))
        await model.move(try summary("M"), to: "Projects")

        XCTAssertTrue(model.summaries.isEmpty)
        let archive = await server.messages(in: "Archive").map(\.subject)
        let junk = await server.messages(in: "Junk").map(\.subject)
        let projects = await server.messages(in: "Projects").map(\.subject)
        XCTAssertEqual(archive, ["A"])
        XCTAssertEqual(junk, ["J"])
        XCTAssertEqual(projects, ["M"])
    }

    func testConcurrentMutationsTakeTurnsAtTheGate() async throws {
        await server.add(incoming("A", id: "<A@x>", minutes: 0))
        await server.add(incoming("B", id: "<B@x>", minutes: 1))
        try await model.signIn(password: "pw")
        let a = try summary("A").id
        let b = try summary("B").id

        // Both start on the main actor; whichever enters the gate first suspends
        // on the server, and the other must wait rather than interleave.
        async let first: Void = model.trash(threadIDs: [a])
        async let second: Void = model.trash(threadIDs: [b])
        _ = await (first, second)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.summaries.isEmpty)
        let trashed = await server.messages(in: "Trash").map(\.subject)
        XCTAssertEqual(Set(trashed), ["A", "B"])
    }

    func testMutationsWithoutAConnectionSetTheError() async {
        await model.trash(threadIDs: ["t"])
        XCTAssertEqual(model.errorMessage, notConnected)
        await model.archive(threadIDs: ["t"])
        XCTAssertEqual(model.errorMessage, notConnected)
        await model.junk(threadIDs: ["t"])
        XCTAssertEqual(model.errorMessage, notConnected)
        await model.move(threadIDs: ["t"], to: "x")
        XCTAssertEqual(model.errorMessage, notConnected)
        await model.markRead(threadIDs: ["t"], read: true)
        XCTAssertEqual(model.errorMessage, notConnected)
        await model.markFlagged(threadIDs: ["t"], flagged: true)
        XCTAssertEqual(model.errorMessage, notConnected)
        await model.block(address: "spam@x.com")
        XCTAssertEqual(model.errorMessage, notConnected)
    }

    // MARK: Folders

    func testSelectingAFolderSyncsItOnceThenServesTheCache() async throws {
        await server.add(incoming("Plan", id: "<a@x>"))
        await server.add(incoming("Filed", id: "<f@x>"), to: "Archive")
        try await model.signIn(password: "pw")
        let archive = Mailbox(accountID: account.id, name: "Archive", role: .archive)

        await model.selectMailbox(archive)
        XCTAssertEqual(model.currentMailbox.name, "Archive")
        XCTAssertFalse(model.isViewingInbox)
        XCTAssertEqual(model.summaries.map(\.subject), ["Filed"])
        let archiveFetches = await server.calls(.fetchRecentEnvelopes).filter { $0 == .fetchRecentEnvelopes(mailbox: "Archive", limit: 50) }
        XCTAssertEqual(archiveFetches.count, 1)

        await model.selectMailbox(Mailbox(accountID: account.id, name: "INBOX", role: .inbox))
        XCTAssertTrue(model.isViewingInbox)
        XCTAssertEqual(model.summaries.map(\.subject), ["Plan"])
        let inboxFetches = await server.calls(.fetchRecentEnvelopes).filter { $0 == .fetchRecentEnvelopes(mailbox: "INBOX", limit: 50) }
        XCTAssertEqual(inboxFetches.count, 1, "returning home reads the cache, it does not re-sync")
    }

    func testRefreshSyncsTheFolderOnScreen() async throws {
        try await model.signIn(password: "pw")
        await model.selectMailbox(Mailbox(accountID: account.id, name: "Archive", role: .archive))
        await server.add(incoming("Filed", id: "<f@x>"), to: "Archive")

        await model.refresh()

        XCTAssertEqual(model.summaries.map(\.subject), ["Filed"])
    }

    func testFolderDiscoveryFillsTheSwitcherAndFallsBackToTheCache() async throws {
        try await model.signIn(password: "pw")
        await server.addFolder(MailboxInfo(name: "Projects"))

        await model.discoverFolders()
        XCTAssertTrue(model.mailboxes.contains { $0.name == "Projects" })
        XCTAssertEqual(model.mailboxes.first { $0.name == "Junk" }?.role, .junk)

        await server.fail(.listMailboxes)
        await model.discoverFolders()
        XCTAssertTrue(model.mailboxes.contains { $0.name == "Projects" }, "a failed LIST keeps the cached folders")
        XCTAssertNil(model.errorMessage)

        model.signOut()
        XCTAssertTrue(model.mailboxes.isEmpty)
        await model.loadMailboxes()
        XCTAssertTrue(model.mailboxes.contains { $0.name == "Projects" }, "the cache survives sign-out")
    }

    // MARK: Blocking

    func testBlockingASenderJunksTheirMailAndListsThem() async throws {
        await server.add(incoming("Plan", id: "<a@x>", minutes: 0))
        await server.add(incoming("Deal", id: "<s@x>", from: "Spam <spam@x.com>", minutes: 1))
        try await model.signIn(password: "pw")
        XCTAssertEqual(model.summaries.count, 2)

        await model.block(address: "Spam@x.com")

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.summaries.map(\.subject), ["Plan"])
        XCTAssertEqual(model.blockedSenders, ["spam@x.com"])
        let junk = await server.messages(in: "Junk").map(\.subject)
        XCTAssertEqual(junk, ["Deal"])

        await model.unblock(address: "spam@x.com")
        XCTAssertTrue(model.blockedSenders.isEmpty)
    }

    func testBlockingYourselfOrNobodyIsIgnored() async throws {
        try await model.signIn(password: "pw")

        await model.block(address: "ME@x.com")
        await model.block(address: "")
        await model.loadBlockedSenders()

        XCTAssertTrue(model.blockedSenders.isEmpty)
    }

    // MARK: Search

    func testSearchIsLocalAndSkipsBlankQueries() async throws {
        await server.add(incoming("Plan", id: "<a@x>", minutes: 0), body: MessageBody(text: "lunch", hasHTML: false))
        await server.add(incoming("Budget", id: "<b@x>", minutes: 1), body: MessageBody(text: "numbers", hasHTML: false))
        try await model.signIn(password: "pw")
        let callsBefore = await server.calls.count

        let blank = await model.search("   ")
        let hits = await model.search("budget")

        XCTAssertTrue(blank.isEmpty)
        XCTAssertEqual(hits.map(\.subject), ["Budget"])
        let callsAfter = await server.calls.count
        XCTAssertEqual(callsAfter, callsBefore, "search never touches the server")
    }

    // MARK: Web View and attachments

    func testHTMLAndAttachmentFetchesNeedAConnectionAndReportFailures() async throws {
        let offlineHTML = await model.htmlBody(for: "mid:<a@x>")
        XCTAssertNil(offlineHTML)
        XCTAssertEqual(model.errorMessage, notConnected)
        let offlineData = await model.attachmentData(messageID: "mid:<a@x>", partID: "2")
        XCTAssertNil(offlineData)

        let uid = await server.add(incoming("Plan", id: "<a@x>"), html: HTMLBody(html: "<b>hi</b>"))
        await server.addAttachment(Data("x".utf8), to: "INBOX", uid: uid, partID: "2")
        try await model.signIn(password: "pw")

        let html = await model.htmlBody(for: "mid:<a@x>")
        XCTAssertEqual(html?.html, "<b>hi</b>")
        let data = await model.attachmentData(messageID: "mid:<a@x>", partID: "2")
        XCTAssertEqual(data, Data("x".utf8))

        await server.fail(.fetchHTMLBody)
        let failed = await model.htmlBody(for: "mid:<a@x>")
        XCTAssertNil(failed)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: Live refresh

    func testLiveRefreshSyncsOnAServerTickAndStopsCleanly() async throws {
        _ = try await signInWithPlan()

        model.startLiveRefresh()
        model.startLiveRefresh()
        XCTAssertTrue(model.isLiveRefreshing)
        let watching = await eventually { await self.server.isWatching }
        XCTAssertTrue(watching)
        let watches = await server.calls(.idleChanges)
        XCTAssertEqual(watches.count, 1, "starting twice opens one watch")

        await server.add(incoming("New", id: "<n@x>", minutes: 9))
        await server.tick()
        let synced = await eventually { self.model.summaries.count == 2 }
        XCTAssertTrue(synced)

        await model.stopLiveRefresh()
        XCTAssertFalse(model.isLiveRefreshing)
        let stillWatching = await server.isWatching
        XCTAssertFalse(stillWatching)
    }

    func testLiveRefreshIsANoOpWithoutAConnection() async {
        model.startLiveRefresh()
        XCTAssertFalse(model.isLiveRefreshing)
        let watching = await server.isWatching
        XCTAssertFalse(watching)
    }
}
