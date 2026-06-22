import XCTest
@testable import ZirbeCore

final class NewMailNotificationTests: XCTestCase {
    private func item(
        thread: String? = "t1",
        name: String? = nil,
        address: String? = "p@x.com",
        subject: String? = "Hello"
    ) -> NewMailItem {
        NewMailItem(threadID: thread, senderName: name, senderAddress: address, subject: subject)
    }

    func testEmptyIsNone() {
        XCTAssertEqual(NewMailNotification.plan(for: []), .none)
    }

    func testSingleArrivalIsOneBanner() {
        let plan = NewMailNotification.plan(for: [item(name: "Pat Lee", subject: "Lunch?")])
        XCTAssertEqual(plan, .items([
            NewMailNotification.Pending(threadID: "t1", title: "Pat Lee", body: "Lunch?")
        ]))
    }

    func testAtCapIsPerMessage() {
        let items = [
            item(thread: "a", name: "A", subject: "1"),
            item(thread: "b", name: "B", subject: "2"),
            item(thread: "c", name: "C", subject: "3"),
        ]
        guard case let .items(banners) = NewMailNotification.plan(for: items) else {
            return XCTFail("expected per-message banners at the cap")
        }
        XCTAssertEqual(banners.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(banners.map(\.body), ["1", "2", "3"])
    }

    func testOverCapCollapsesToSummary() {
        let items = (1...4).map { item(thread: "t\($0)", subject: "s\($0)") }
        XCTAssertEqual(NewMailNotification.plan(for: items), .summary(count: 4))
    }

    func testNameFallsBackToAddressThenStandIn() {
        let noName = NewMailNotification.plan(for: [item(name: nil, address: "raw@x.com")])
        XCTAssertEqual(noName, .items([
            NewMailNotification.Pending(threadID: "t1", title: "raw@x.com", body: "Hello")
        ]))

        let noSender = NewMailNotification.plan(for: [item(name: "  ", address: "")])
        XCTAssertEqual(noSender, .items([
            NewMailNotification.Pending(threadID: "t1", title: "New message", body: "Hello")
        ]))
    }

    func testMissingSubjectGetsStandIn() {
        let plan = NewMailNotification.plan(for: [item(name: "Pat", subject: "   ")])
        XCTAssertEqual(plan, .items([
            NewMailNotification.Pending(threadID: "t1", title: "Pat", body: "(no subject)")
        ]))
    }
}
