// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Proof that the transport seam holds: SyncService and InboxModel run end to end
// against the in-memory server and sender, with no network. These are the smoke
// tests for the seam itself; the sync and model behaviors get their own suites.

import XCTest
import ZirbeMail
@testable import ZirbeCore

final class TransportSeamTests: XCTestCase {
    private let account = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")

    /// A service and model wired to fresh fakes over an in-memory store.
    @MainActor
    private func makeStack() throws -> (server: FakeMailServer, sender: FakeMailSender, sync: SyncService, model: InboxModel) {
        let store = try MailStore()
        let server = FakeMailServer()
        let sender = FakeMailSender()
        let sync = SyncService(account: account, store: store, engine: server, sender: sender)
        let model = InboxModel(account: account, store: store, sync: sync)
        return (server, sender, sync, model)
    }

    /// The first inbox conversation, loaded the way the view does.
    @MainActor
    private func openFirstConversation(in model: InboxModel) async throws -> ZirbeCore.Thread {
        let id = try XCTUnwrap(model.summaries.first?.id)
        let thread = await model.conversation(id: id)
        return try XCTUnwrap(thread)
    }

    private func incoming(_ subject: String, from: String = "Pat <pat@x.com>", id: String) -> MailEnvelope {
        MailEnvelope(
            subject: subject,
            from: from,
            to: ["me@x.com"],
            date: Date(timeIntervalSince1970: 1_000),
            messageID: id
        )
    }

    @MainActor
    func testSyncInboxReadsTheFakeServer() async throws {
        let (server, _, sync, _) = try makeStack()
        await server.add(incoming("Plan", id: "<a@x>"), body: MessageBody(text: "Lunch?", hasHTML: false))
        await server.add(incoming("Budget", id: "<b@x>"))

        let summaries = try await sync.syncInbox(password: "pw")

        XCTAssertEqual(summaries.map(\.subject).sorted(), ["Budget", "Plan"])
        let session = await server.session
        XCTAssertEqual(session?.username, account.username)
        XCTAssertEqual(session?.password, "pw")
        // The snippet backfill fetched the body for the newest message of each
        // thread, over the same connection.
        let fetched = await server.calls(.fetchTextBodies)
        XCTAssertEqual(fetched.count, 1)
    }

    @MainActor
    func testReplyGoesOutThroughTheFakeSender() async throws {
        let (server, sender, _, model) = try makeStack()
        await server.add(incoming("Plan", id: "<a@x>"), body: MessageBody(text: "Lunch?", hasHTML: false))
        try await model.signIn(password: "pw")
        let thread = try await openFirstConversation(in: model)

        let replied = await model.sendReply(to: thread, body: "Yes")
        let updated = try XCTUnwrap(replied)

        let sent = await sender.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.to.map(\.address), ["pat@x.com"])
        XCTAssertEqual(sent.first?.inReplyTo, "<a@x>")
        XCTAssertEqual(updated.messages.count, 2)
        XCTAssertEqual(updated.messages.last?.sendState, .sent)
        // The Sent copy reached the server's Sent folder.
        let copies = await server.sentCopies.map(\.messageID)
        XCTAssertEqual(copies, [sent.first?.messageID])
    }

    @MainActor
    func testRefusedSendLeavesAnUndeliveredBubbleThatRetries() async throws {
        let (server, sender, _, model) = try makeStack()
        await server.add(incoming("Plan", id: "<a@x>"))
        try await model.signIn(password: "pw")
        let thread = try await openFirstConversation(in: model)

        await sender.failNext()
        let replied = await model.sendReply(to: thread, body: "Yes")
        let bubble = try XCTUnwrap(replied?.messages.last)
        let bubbleID = try XCTUnwrap(bubble.messageID)
        XCTAssertEqual(bubble.sendState, .failed)
        XCTAssertTrue(model.canRetry(messageID: bubbleID))
        let sentAfterFailure = await sender.sent
        XCTAssertTrue(sentAfterFailure.isEmpty)

        let retriedThread = await model.retrySend(messageID: bubbleID, in: thread.id)
        let retried = try XCTUnwrap(retriedThread)
        XCTAssertEqual(retried.messages.count, 2)
        XCTAssertEqual(retried.messages.last?.sendState, .sent)
        XCTAssertFalse(model.canRetry(messageID: bubbleID))
        let attempts = await sender.attempts.map(\.messageID)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first, attempts.last, "a retry reuses the Message-ID so the Sent copy can't double")
    }
}
