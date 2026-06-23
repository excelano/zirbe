// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The persistence side of the failed-send bubble: a locally-composed message
// carries a send state that survives a round-trip through the store, defaults to
// `sent` for everything else, and flips in place (keyed by Message-ID) when a
// retry finally delivers.

import XCTest
@testable import ZirbeCore

final class MailStoreSendStateTests: XCTestCase {
    private func account() -> Account {
        Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func localMessage(id: String, state: SendState) -> Message {
        Message(
            messageID: id,
            subject: "Re: Plan",
            from: Participant(address: "me@x.com"),
            to: [Participant(address: "pat@x.com")],
            date: Date(timeIntervalSince1970: 0),
            flags: [.seen],
            bodyText: "my reply",
            sendState: state
        )
    }

    /// Read back the only message in the store via the thread it rethreaded into.
    private func storedMessage(in store: MailStore, accountID: String) async throws -> Message? {
        let summaries = try await store.threadSummaries(accountID: accountID)
        guard let id = summaries.first?.id else { return nil }
        return try await store.thread(id: id)?.messages.first
    }

    func testFailedStateSurvivesARoundTrip() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        try await store.save([localMessage(id: "<f@x>", state: .failed)], accountID: acct.id, mailboxName: "Sent")
        try await store.rethread(accountID: acct.id)

        let read = try await storedMessage(in: store, accountID: acct.id)
        XCTAssertEqual(read?.sendState, .failed)
        XCTAssertTrue(read?.didFailToSend == true)
    }

    func testServerSyncedMailDefaultsToSent() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        // A received message, saved with no explicit state, reads as delivered.
        try await store.save([
            Message(messageID: "<r@x>", uid: 1, subject: "Hi", from: Participant(address: "pat@x.com"),
                    date: Date(timeIntervalSince1970: 0))
        ], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let read = try await storedMessage(in: store, accountID: acct.id)
        XCTAssertEqual(read?.sendState, .sent)
    }

    func testRetrySuccessFlipsTheSameRowToSent() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        // First attempt fails: the bubble is recorded as failed.
        try await store.save([localMessage(id: "<f@x>", state: .failed)], accountID: acct.id, mailboxName: "Sent")
        try await store.rethread(accountID: acct.id)
        let before = try await storedMessage(in: store, accountID: acct.id)
        XCTAssertEqual(before?.sendState, .failed)

        // Retry delivers: re-recording the same Message-ID upserts the one row.
        try await store.save([localMessage(id: "<f@x>", state: .sent)], accountID: acct.id, mailboxName: "Sent")
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        XCTAssertEqual(summaries.count, 1) // flipped in place, not doubled
        let after = try await storedMessage(in: store, accountID: acct.id)
        XCTAssertEqual(after?.sendState, .sent)
    }
}
