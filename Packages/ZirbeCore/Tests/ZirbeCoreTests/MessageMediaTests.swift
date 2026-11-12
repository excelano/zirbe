// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import GRDB
import XCTest
@testable import ZirbeCore
import ZirbeMail

final class MessageMediaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zirbe-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() async throws -> (MailStore, Account) {
        let store = try MailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        let acct = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        try await store.upsert(acct)
        return (store, acct)
    }

    private func envelope(uid: UInt32, subject: String, partTypes: [String]) -> MailEnvelope {
        MailEnvelope(
            uid: uid,
            subject: subject,
            from: "p@x.com",
            date: Date(timeIntervalSince1970: TimeInterval(uid) * 60),
            messageID: "<\(uid)@x>",
            partTypes: partTypes
        )
    }

    func testMediaIsReadFromMIMETypes() {
        XCTAssertEqual(MessageMedia(mimeTypes: ["text/plain", "Audio/MP4"]), .audio)
        XCTAssertEqual(MessageMedia(mimeTypes: ["video/mp4; name=a.mp4", "audio/mpeg"]), [.audio, .video])
        XCTAssertEqual(MessageMedia(mimeTypes: ["image/jpeg", "application/pdf"]), [])
    }

    func testAThreadCarriesTheMediaOfItsMessages() async throws {
        let (store, acct) = try await store()
        let voice = Message(envelope(uid: 1, subject: "Voice", partTypes: ["text/plain", "audio/mp4"]))
        let video = Message(envelope(uid: 2, subject: "Video", partTypes: ["video/mp4"]))
        let plain = Message(envelope(uid: 3, subject: "Plain", partTypes: ["text/plain"]))
        try await store.save([voice, video, plain], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let summaries = try await store.threadSummaries(accountID: acct.id, mailboxName: "INBOX")
        let bySubject = Dictionary(uniqueKeysWithValues: summaries.map { ($0.subject, $0.media) })
        XCTAssertEqual(bySubject["Voice"], .audio)
        XCTAssertEqual(bySubject["Video"], .video)
        XCTAssertEqual(bySubject["Plain"], [])
    }

    func testAStoredBodyAddsTheMediaOfItsAttachments() async throws {
        let (store, acct) = try await store()
        let older = Message(envelope(uid: 1, subject: "Voice", partTypes: []))
        try await store.save([older], accountID: acct.id, mailboxName: "INBOX")
        let voice = MessageAttachment(filename: "Voice Message.m4a", mimeType: "audio/mp4", partID: "2")
        try await store.storeBodies([older.id: (text: "", hasHTML: false, attachments: [voice])], accountID: acct.id)
        try await store.rethread(accountID: acct.id)

        let summary = try await store.threadSummaries(accountID: acct.id, mailboxName: "INBOX").first
        XCTAssertEqual(summary?.media, .audio)
    }

    func testAHeaderResaveKeepsTheMediaItsBodyFound() async throws {
        let (store, acct) = try await store()
        let older = Message(envelope(uid: 1, subject: "Voice", partTypes: []))
        try await store.save([older], accountID: acct.id, mailboxName: "INBOX")
        let voice = MessageAttachment(filename: "Voice Message.m4a", mimeType: "audio/mp4", partID: "2")
        try await store.storeBodies([older.id: (text: "", hasHTML: false, attachments: [voice])], accountID: acct.id)
        try await store.save([older], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let summary = try await store.threadSummaries(accountID: acct.id, mailboxName: "INBOX").first
        XCTAssertEqual(summary?.media, .audio)
    }

    func testUpgradingReadsTheMediaOfBodiesAlreadyCached() throws {
        let dbQueue = try DatabaseQueue()
        try MailStore.migrator.migrate(dbQueue, upTo: "v24-media")
        let voice = MessageAttachment(filename: "Voice Message.m4a", mimeType: "audio/mp4", partID: "2")
        let attachments = String(decoding: try JSONEncoder().encode([voice]), as: UTF8.self)
        try dbQueue.write { db in
            for (id, json) in [("<a@x>", attachments), ("<b@x>", "[]")] {
                try db.execute(
                    sql: """
                        INSERT INTO message
                            (id, accountID, mailboxName, referenceIDs, toParticipants, ccParticipants,
                             flags, bodyText, hasHTML, attachments, sendState)
                        VALUES (?, 'acct', 'INBOX', '[]', '[]', '[]', '[]', '', 0, ?, 'sent')
                        """,
                    arguments: [id, json]
                )
            }
        }

        try MailStore.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT media FROM message WHERE id = '<a@x>'"), MessageMedia.audio.rawValue)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT media FROM message WHERE id = '<b@x>'"), 0)
        }
    }

    func testALocalSentCopyCarriesTheMediaOfWhatWasAttached() {
        let message = Message(
            subject: "Hi",
            attachments: [MessageAttachment(filename: "Video-1.mp4", mimeType: "video/mp4", partID: "")]
        )
        XCTAssertEqual(message.media, .video)
    }
}
