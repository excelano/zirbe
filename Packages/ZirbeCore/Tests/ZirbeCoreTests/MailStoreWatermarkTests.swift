import XCTest
@testable import ZirbeCore

final class MailStoreWatermarkTests: XCTestCase {
    private func account() -> Account {
        Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
    }

    private func msg(id: String, uid: UInt32, subject: String, from: String = "p@x.com", seen: Bool = false) -> Message {
        Message(
            messageID: id,
            uid: uid,
            subject: subject,
            from: Participant(address: from),
            date: Date(timeIntervalSince1970: TimeInterval(uid) * 60),
            flags: seen ? [.seen] : []
        )
    }

    func testArrivalsBeforeAnyMarkAreUnseenInUIDOrder() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        try await store.save([
            msg(id: "<a@x>", uid: 1, subject: "A"),
            msg(id: "<b@x>", uid: 2, subject: "B", seen: true),
            msg(id: "<c@x>", uid: 3, subject: "C"),
        ], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)

        let arrivals = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertEqual(arrivals.map(\.subject), ["A", "C"]) // B is seen; ordered by uid
        XCTAssertNotNil(arrivals.first?.threadID)            // stamped by the rethread
    }

    func testMarkSuppressesThenNewerArrivalSurfaces() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        try await store.save([msg(id: "<a@x>", uid: 5, subject: "A")], accountID: acct.id, mailboxName: "INBOX")
        try await store.markNotificationWatermark(accountID: acct.id)
        let afterMark = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertTrue(afterMark.isEmpty)

        try await store.save([msg(id: "<b@x>", uid: 9, subject: "B")], accountID: acct.id, mailboxName: "INBOX")
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertEqual(arrivals.map(\.subject), ["B"])
    }

    func testSeedOnFirstMarkSilencesWholeInbox() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        try await store.save([
            msg(id: "<a@x>", uid: 1, subject: "A"),
            msg(id: "<b@x>", uid: 2, subject: "B"),
        ], accountID: acct.id, mailboxName: "INBOX")
        try await store.markNotificationWatermark(accountID: acct.id)
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertTrue(arrivals.isEmpty)
    }

    func testNonInboxMailIsNotAnArrival() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        try await store.save([msg(id: "<a@x>", uid: 1, subject: "Archived")], accountID: acct.id, mailboxName: "Archive")
        try await store.rethread(accountID: acct.id)
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertTrue(arrivals.isEmpty)
    }

    func testLocalMessageWithoutUIDIsNotAnArrival() async throws {
        let store = try MailStore()
        let acct = account()
        try await store.upsert(acct)
        let local = Message(messageID: "<local@x>", subject: "Draft", from: Participant(address: "me@x.com"), date: Date(timeIntervalSince1970: 0))
        try await store.save([local], accountID: acct.id, mailboxName: "INBOX")
        try await store.rethread(accountID: acct.id)
        let arrivals = try await store.unnotifiedInboxArrivals(accountID: acct.id)
        XCTAssertTrue(arrivals.isEmpty)
    }
}
