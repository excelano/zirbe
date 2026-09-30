// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The demo seed must always load: it is what screenshots and the App Review
// demo run on, and a seed that throws leaves the app on its splash screen.

import XCTest
@testable import ZirbeCore

final class DemoDataTests: XCTestCase {
    func testTheSeedLoadsAndThreadsTheMeetingAsOneConversation() async throws {
        let store = try MailStore()
        try await DemoData.seed(into: store)

        let summaries = try await store.threadSummaries(accountID: DemoData.account.id)
        XCTAssertGreaterThan(summaries.count, 3)
        let meeting = try XCTUnwrap(summaries.first { $0.subject.contains("planning call") })
        XCTAssertEqual(meeting.preview, "Pushed it half an hour so Daniel can make it.")
        let loaded = try await store.thread(id: meeting.id)
        let thread = try XCTUnwrap(loaded)
        XCTAssertEqual(thread.messages.count, 3)
        XCTAssertEqual(thread.conversationMessages.count, 1, "the update replaces the invite; the answer is a line")
        XCTAssertEqual(thread.inviteResponses.map(\.text), ["Daniel Okafor accepted"])
    }
}
