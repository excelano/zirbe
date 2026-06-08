import XCTest
@testable import ZirbeCore

final class ThreaderTests: XCTestCase {
    // Helper: a message with a date `minutes` after a fixed epoch.
    private func msg(
        id: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String? = "Lunch",
        from: String = "a@x.com",
        minutes: Int = 0,
        seen: Bool = true
    ) -> Message {
        Message(
            messageID: id,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            from: Participant(address: from),
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: seen ? [.seen] : []
        )
    }

    func testLinearChainThreadsTogether() {
        let a = msg(id: "<a@x>", minutes: 0)
        let b = msg(id: "<b@x>", inReplyTo: "<a@x>", references: ["<a@x>"], subject: "Re: Lunch", minutes: 1)
        let c = msg(id: "<c@x>", inReplyTo: "<b@x>", references: ["<a@x>", "<b@x>"], subject: "Re: Lunch", minutes: 2)

        let threads = Threader.thread([c, a, b]) // deliberately out of order
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messages.map(\.messageID), ["<a@x>", "<b@x>", "<c@x>"])
    }

    func testInReplyToAloneStillThreads() {
        // No References header at all, only In-Reply-To.
        let a = msg(id: "<a@x>", minutes: 0)
        let b = msg(id: "<b@x>", inReplyTo: "<a@x>", references: [], subject: "Re: Lunch", minutes: 1)

        let threads = Threader.thread([a, b])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messages.count, 2)
    }

    func testMissingRootStillFormsOneThread() {
        // The original <a@x> was never received; two replies reference it.
        let b = msg(id: "<b@x>", references: ["<a@x>"], subject: "Re: Lunch", minutes: 1)
        let c = msg(id: "<c@x>", references: ["<a@x>", "<b@x>"], subject: "Re: Lunch", minutes: 2)

        let threads = Threader.thread([b, c])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messages.count, 2)
        // Thread identity is the missing root's Message-ID, so it stays stable.
        XCTAssertEqual(threads[0].id, "mid:<a@x>")
    }

    func testUnrelatedMessagesStaySeparate() {
        let a = msg(id: "<a@x>", subject: "Lunch")
        let z = msg(id: "<z@x>", subject: "Invoice", from: "b@y.com")

        let threads = Threader.thread([a, z])
        XCTAssertEqual(threads.count, 2)
    }

    func testSubjectTitleStripsRePrefix() {
        let a = msg(id: "<a@x>", subject: "Lunch", minutes: 0)
        let b = msg(id: "<b@x>", references: ["<a@x>"], subject: "Re: Lunch", minutes: 1)

        let threads = Threader.thread([a, b])
        XCTAssertEqual(threads[0].subject, "Lunch")
    }

    func testThreadIsUnreadWhenAnyMessageUnseen() {
        let a = msg(id: "<a@x>", minutes: 0, seen: true)
        let b = msg(id: "<b@x>", references: ["<a@x>"], minutes: 1, seen: false)

        let threads = Threader.thread([a, b])
        XCTAssertTrue(threads[0].isUnread)
    }

    func testParticipantsAreUnionedAndDeduped() {
        let a = Message(
            messageID: "<a@x>", subject: "Lunch",
            from: Participant(address: "alice@x.com", displayName: "Alice"),
            to: [Participant(address: "bob@x.com")],
            date: Date(timeIntervalSince1970: 0), flags: [.seen]
        )
        let b = Message(
            messageID: "<b@x>", references: ["<a@x>"], subject: "Re: Lunch",
            from: Participant(address: "bob@x.com", displayName: "Bob"),
            to: [Participant(address: "ALICE@x.com")], // different case, same person
            date: Date(timeIntervalSince1970: 60), flags: [.seen]
        )
        let threads = Threader.thread([a, b])
        XCTAssertEqual(Set(threads[0].participants.map(\.address)), ["alice@x.com", "bob@x.com"])
    }

    func testCyclicReferencesDoNotHang() {
        // a references b, b references a. Must not loop forever or crash.
        let a = msg(id: "<a@x>", references: ["<b@x>"], minutes: 0)
        let b = msg(id: "<b@x>", references: ["<a@x>"], minutes: 1)
        let threads = Threader.thread([a, b])
        XCTAssertEqual(threads.flatMap(\.messages).count, 2)
    }

    func testSubjectMergeOffByDefault() {
        // Same subject, no shared headers: should be two threads by default.
        let a = msg(id: "<a@x>", subject: "Status", from: "a@x.com")
        let b = msg(id: "<b@y>", subject: "Re: Status", from: "b@y.com")
        XCTAssertEqual(Threader.thread([a, b]).count, 2)
        // With merging on, they collapse.
        XCTAssertEqual(Threader.thread([a, b], mergeBySubject: true).count, 1)
    }
}
