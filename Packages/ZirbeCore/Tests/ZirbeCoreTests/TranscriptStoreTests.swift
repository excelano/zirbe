// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import XCTest
@testable import ZirbeCore

final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zirbe-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let voice = MessageAttachment(filename: "Voice Message.m4a", mimeType: "audio/mp4", partID: "2")

    private func storeWithVoiceMessage() async throws -> (MailStore, Account, Message) {
        let store = try MailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        let acct = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        try await store.upsert(acct)
        let message = Message(
            messageID: "<v@x>",
            uid: 1,
            subject: "Hi",
            from: Participant(address: "p@x.com"),
            date: Date(timeIntervalSince1970: 60),
            flags: [.seen]
        )
        try await store.save([message], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([message.id: (text: "", hasHTML: false, attachments: [voice])], accountID: acct.id)
        try await store.rethread(accountID: acct.id)
        return (store, acct, message)
    }

    func testATranscriptIsReadBackWithItsMessage() async throws {
        let (store, acct, message) = try await storeWithVoiceMessage()
        try await store.storeTranscript("Running ten minutes late", messageID: message.id, accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        let summary = try XCTUnwrap(summaries.first)
        let thread = try await store.thread(id: summary.id, accountID: acct.id)
        XCTAssertEqual(thread?.messages.first?.transcript, "Running ten minutes late")
    }

    func testATranscriptIsSearchable() async throws {
        let (store, acct, message) = try await storeWithVoiceMessage()
        try await store.storeTranscript("Running ten minutes late", messageID: message.id, accountID: acct.id)

        let hits = try await store.searchThreads(accountID: acct.id, query: "minutes")
        XCTAssertEqual(hits.map(\.subject), ["Hi"])
    }

    func testATranscriptBecomesThePreviewOfAMessageWithNoText() async throws {
        let (store, acct, message) = try await storeWithVoiceMessage()
        try await store.storeTranscript("Running ten minutes late", messageID: message.id, accountID: acct.id)
        try await store.rethread(accountID: acct.id)

        let summary = try await store.threadSummaries(accountID: acct.id).first
        XCTAssertEqual(summary?.preview, "Running ten minutes late")
    }

    func testAHeaderResaveAndABodyRefetchKeepTheTranscript() async throws {
        let (store, acct, message) = try await storeWithVoiceMessage()
        try await store.storeTranscript("Running ten minutes late", messageID: message.id, accountID: acct.id)

        try await store.save([message], accountID: acct.id, mailboxName: "INBOX")
        try await store.storeBodies([message.id: (text: "", hasHTML: false, attachments: [voice])], accountID: acct.id)
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id)
        let summary = try XCTUnwrap(summaries.first)
        let thread = try await store.thread(id: summary.id, accountID: acct.id)
        XCTAssertEqual(thread?.messages.first?.transcript, "Running ten minutes late")
        XCTAssertEqual(summary.preview, "Running ten minutes late")
        let hits = try await store.searchThreads(accountID: acct.id, query: "minutes")
        XCTAssertEqual(hits.count, 1)
    }
}
