import XCTest
@testable import ZirbeCore

/// In-conversation search: which messages match a query, the one-per-message
/// result, the case- and diacritic-insensitive matching, and the snippet window
/// (context, ellipses, and the highlight offset that survives an elided head).
final class ConversationSearchTests: XCTestCase {
    private func message(_ id: String, from name: String, body: String, at seconds: TimeInterval = 0) -> Message {
        Message(
            messageID: id,
            from: Participant(address: "\(name.lowercased())@x.com", displayName: name),
            date: Date(timeIntervalSince1970: seconds),
            bodyText: body
        )
    }

    func testMatchesOnlyMessagesContainingTheQuery() {
        let messages = [
            message("<1@x>", from: "Pat", body: "Here is the budget for Q3."),
            message("<2@x>", from: "Sam", body: "Sounds good, thanks."),
            message("<3@x>", from: "Pat", body: "The budget was approved."),
        ]
        let hits = ConversationSearch.hits(for: "budget", in: messages)
        XCTAssertEqual(hits.map(\.messageID), ["mid:<1@x>", "mid:<3@x>"])
    }

    func testOneHitPerMessageEvenWithSeveralOccurrences() {
        let messages = [message("<1@x>", from: "Pat", body: "budget budget budget")]
        XCTAssertEqual(ConversationSearch.hits(for: "budget", in: messages).count, 1)
    }

    func testBlankQueryYieldsNothing() {
        let messages = [message("<1@x>", from: "Pat", body: "anything")]
        XCTAssertTrue(ConversationSearch.hits(for: "   ", in: messages).isEmpty)
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let messages = [message("<1@x>", from: "José", body: "Café closes at five.")]
        let hits = ConversationSearch.hits(for: "cafe", in: messages)
        XCTAssertEqual(hits.count, 1)
        // The matched span still covers the accented word as written.
        let hit = hits[0]
        let start = hit.snippet.index(hit.snippet.startIndex, offsetBy: hit.highlightStart)
        let end = hit.snippet.index(start, offsetBy: hit.highlightLength)
        XCTAssertEqual(String(hit.snippet[start..<end]), "Café")
    }

    func testResultCarriesSenderAndDate() {
        let messages = [message("<1@x>", from: "Pat", body: "the budget", at: 100)]
        let hit = ConversationSearch.hits(for: "budget", in: messages)[0]
        XCTAssertEqual(hit.sender.label, "Pat")
        XCTAssertEqual(hit.date, Date(timeIntervalSince1970: 100))
    }

    func testSnippetElidesLongContextAndKeepsHighlightAligned() {
        let head = String(repeating: "x ", count: 60)   // 120 chars of lead-in
        let tail = String(repeating: "y ", count: 60)
        let messages = [message("<1@x>", from: "Pat", body: "\(head)needle\(tail)")]
        let hit = ConversationSearch.hits(for: "needle", in: messages, contextRadius: 10)[0]
        XCTAssertTrue(hit.snippet.hasPrefix("…"), "a cut head gets a leading ellipsis")
        XCTAssertTrue(hit.snippet.hasSuffix("…"), "a cut tail gets a trailing ellipsis")
        // The highlight offset points at the query despite the prepended ellipsis.
        let start = hit.snippet.index(hit.snippet.startIndex, offsetBy: hit.highlightStart)
        let end = hit.snippet.index(start, offsetBy: hit.highlightLength)
        XCTAssertEqual(String(hit.snippet[start..<end]), "needle")
    }

    func testShortBodyKeepsWholeSnippetWithoutEllipses() {
        let messages = [message("<1@x>", from: "Pat", body: "the budget is fine")]
        let hit = ConversationSearch.hits(for: "budget", in: messages)[0]
        XCTAssertEqual(hit.snippet, "the budget is fine")
        XCTAssertFalse(hit.snippet.contains("…"))
    }

    func testQuotedHistoryIsNotSearched() {
        // A reply whose new words don't match but whose quoted trailer does: the
        // fold drops the quote before matching, so this is not a hit.
        let body = "Thanks!\n\nOn Jan 1, Pat wrote:\n> the secret budget line"
        let messages = [message("<1@x>", from: "Sam", body: body)]
        XCTAssertTrue(ConversationSearch.hits(for: "secret", in: messages).isEmpty)
    }
}
