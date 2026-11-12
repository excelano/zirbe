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
        to: [String] = [],
        cc: [String] = [],
        minutes: Int = 0,
        seen: Bool = true,
        reaction: String? = nil
    ) -> Message {
        Message(
            messageID: id,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            from: Participant(address: from),
            to: to.map { Participant(address: $0) },
            cc: cc.map { Participant(address: $0) },
            date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
            flags: seen ? [.seen] : [],
            reaction: reaction
        )
    }

    // MARK: - Private replies

    private let me = "me@x.com"

    private func shapes(_ threads: [ZirbeCore.Thread]) -> [[String]] {
        threads.map { thread in
            ([thread.context].compactMap { $0 } + thread.messages).compactMap(\.messageID)
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func testPrivateRepliesToABlindCopiedMessageBecomeTheirOwnConversations() {
        let root = msg(id: "<root>", from: "relay@x.net", to: [me], minutes: 0, seen: false)
        let peter = msg(id: "<peter>", inReplyTo: "<root>", references: ["<root>"], from: "peter@x.com", to: [me], minutes: 1, seen: false)
        let joel = msg(id: "<joel>", inReplyTo: "<root>", references: ["<root>"], from: "joel@x.com", to: [me], minutes: 2)
        let toJoel = msg(id: "<to-joel>", inReplyTo: "<joel>", references: ["<root>", "<joel>"], from: me, to: ["joel@x.com"], minutes: 3)
        let toPeter = msg(id: "<to-peter>", inReplyTo: "<peter>", references: ["<root>", "<peter>"], from: me, to: ["peter@x.com"], minutes: 4)

        let threads = Threader.thread([root, peter, joel, toJoel, toPeter], ownAddresses: [me])
        XCTAssertEqual(shapes(threads), [
            ["<root>"],
            ["<root>", "<joel>", "<to-joel>"],
            ["<root>", "<peter>", "<to-peter>"],
        ])
        let original = threads.first { $0.context == nil }!
        let withPeter = threads.first { $0.messages.first?.messageID == "<peter>" }!
        XCTAssertEqual(original.id, "mid:<root>")
        XCTAssertEqual(withPeter.id, "mid:<root>/mid:<peter>")
        XCTAssertEqual(withPeter.context?.messageID, "<root>")
        XCTAssertEqual(Set(withPeter.participants.map(\.address)), ["peter@x.com", me])
        XCTAssertTrue(withPeter.isUnread)
    }

    func testRepliesToEveryoneStayOneConversationEvenWhenTheyCross() {
        let a = msg(id: "<a>", from: "ana@x.com", to: [me, "ben@x.com"], minutes: 0)
        let b = msg(id: "<b>", inReplyTo: "<a>", references: ["<a>"], from: "ben@x.com", to: [me, "ana@x.com"], minutes: 1)
        let c = msg(id: "<c>", inReplyTo: "<a>", references: ["<a>"], from: me, to: ["ana@x.com", "ben@x.com"], minutes: 2)
        let d = msg(id: "<d>", inReplyTo: "<b>", references: ["<a>", "<b>"], from: "ana@x.com", to: [me, "ben@x.com"], cc: ["cy@x.com"], minutes: 3)
        let e = msg(id: "<e>", inReplyTo: "<d>", references: ["<a>", "<b>", "<d>"], from: "cy@x.com", to: [me], cc: ["ana@x.com"], minutes: 4)

        let threads = Threader.thread([a, b, c, d, e], ownAddresses: [me])
        XCTAssertEqual(shapes(threads), [["<a>", "<b>", "<c>", "<d>", "<e>"]])
    }

    func testAPrivateReplyFromAGroupStartsASideConversation() {
        let a = msg(id: "<a>", from: "ana@x.com", to: [me, "ben@x.com", "cy@x.com"], minutes: 0)
        let b = msg(id: "<b>", inReplyTo: "<a>", references: ["<a>"], from: "ben@x.com", to: [me, "ana@x.com", "cy@x.com"], minutes: 1)
        let c = msg(id: "<c>", inReplyTo: "<a>", references: ["<a>"], from: "cy@x.com", to: [me], minutes: 2)
        let d = msg(id: "<d>", inReplyTo: "<c>", references: ["<a>", "<c>"], from: me, to: ["cy@x.com"], minutes: 3)

        let threads = Threader.thread([a, b, c, d], ownAddresses: [me])
        XCTAssertEqual(shapes(threads), [["<a>", "<b>"], ["<a>", "<c>", "<d>"]])
    }

    func testAReactionStaysWithTheMessageItAnswers() {
        let root = msg(id: "<root>", from: "relay@x.net", to: [me], minutes: 0)
        let thumbs = msg(id: "<r>", inReplyTo: "<root>", references: ["<root>"], from: "peter@x.com", to: [me], minutes: 1, reaction: "👍")

        let threads = Threader.thread([root, thumbs], ownAddresses: [me])
        XCTAssertEqual(shapes(threads), [["<root>", "<r>"]])
    }

    func testAnAddressOfMineIsNotSomeoneAReplyCanLeaveOut() {
        let shared = "hello@x.org"
        let a = msg(id: "<a>", from: "ilyas@x.com", to: [shared], minutes: 0)
        let b = msg(id: "<b>", inReplyTo: "<a>", references: ["<a>"], from: me, to: ["ilyas@x.com"], cc: [shared], minutes: 1)
        let c = msg(id: "<c>", inReplyTo: "<b>", references: ["<a>", "<b>"], from: "ilyas@x.com", to: [me], minutes: 2)

        XCTAssertEqual(shapes(Threader.thread([a, b, c], ownAddresses: [me, shared])), [["<a>", "<b>", "<c>"]])
        XCTAssertEqual(shapes(Threader.thread([a, b, c], ownAddresses: [me])), [["<a>", "<b>"], ["<b>", "<c>"]])
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
