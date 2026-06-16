import XCTest
@testable import ZirbeCore

final class QuotedTextTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let gmt = TimeZone(identifier: "GMT")!

    private func message(from: Participant?, date: Date?, body: String?) -> Message {
        Message(messageID: "<a@x>", subject: "Plan", from: from, date: date, bodyText: body)
    }

    // MARK: - Fold (display)

    func testFoldSplitsAtAttributionLine() {
        let body = """
        Sounds good, shipping it.

        On Jan 1, 1970, at 12:00 AM, Pat <pat@x.com> wrote:
        > the original question
        """
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "Sounds good, shipping it.")
        XCTAssertEqual(folded.quoted, "On Jan 1, 1970, at 12:00 AM, Pat <pat@x.com> wrote:\n> the original question")
    }

    func testFoldSplitsAtFirstQuotedLine() {
        let body = "Yes.\n\n> earlier text\n> more earlier text"
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "Yes.")
        XCTAssertEqual(folded.quoted, "> earlier text\n> more earlier text")
    }

    func testFoldKeepsWrappedAttributionTogether() {
        // The attribution spills onto two lines; both belong to the quote.
        let body = """
        Done.

        On Mon, Jan 1, 1970
        Pat <pat@x.com> wrote:
        > original
        """
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "Done.")
        XCTAssertEqual(folded.quoted, "On Mon, Jan 1, 1970\nPat <pat@x.com> wrote:\n> original")
    }

    func testFoldRecognizesOutlookSeparator() {
        let body = "FYI below.\n\n-----Original Message-----\nFrom: Pat"
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "FYI below.")
        XCTAssertEqual(folded.quoted, "-----Original Message-----\nFrom: Pat")
    }

    func testFoldDropsTrailingSignature() {
        // A `-- ` delimited signature is split off the bubble's visible text; the
        // delimiter and the lines under it do not show. No quote here.
        let body = "Sounds good, shipping it.\n\n--\nDavid Anderson\nConsultant"
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "Sounds good, shipping it.")
        XCTAssertNil(folded.quoted)
    }

    func testFoldDropsMobileFooterSignature() {
        let body = "On my way.\n\nSent from my iPhone"
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "On my way.")
        XCTAssertNil(folded.quoted)
    }

    func testFoldReturnsNoQuoteWhenNoneFound() {
        let body = "Just a plain note with no history."
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, body)
        XCTAssertNil(folded.quoted)
    }

    func testFoldOfEntirelyQuotedBodyHasEmptyVisible() {
        let body = "> a forward with no comment\n> second line"
        let folded = QuotedText.fold(body)
        XCTAssertEqual(folded.visible, "")
        XCTAssertEqual(folded.quoted, body)
    }

    // MARK: - Quote trailer (outgoing)

    func testQuoteTrailerHasAttributionAndPrefixedBody() {
        let m = message(
            from: Participant(address: "david@x.com", displayName: "David Anderson"),
            date: Date(timeIntervalSince1970: 0),
            body: "first\n\nthird"
        )
        let trailer = QuotedText.quoteTrailer(for: m, locale: posix, timeZone: gmt)
        XCTAssertEqual(trailer, """
        On Jan 1, 1970, at 12:00 AM, David Anderson <david@x.com> wrote:

        > first
        >
        > third
        """)
    }

    func testQuoteTrailerWithoutDateDropsTheOnClause() {
        let m = message(from: Participant(address: "p@x.com"), date: nil, body: "hi")
        let trailer = QuotedText.quoteTrailer(for: m, locale: posix, timeZone: gmt)
        XCTAssertEqual(trailer, "p@x.com wrote:\n\n> hi")
    }

    func testReplyBodyPlacesUserTextAboveTrailer() {
        let m = message(
            from: Participant(address: "p@x.com", displayName: "Pat"),
            date: Date(timeIntervalSince1970: 0),
            body: "question?"
        )
        let composed = QuotedText.replyBody("  My answer.  ", quoting: m, locale: posix, timeZone: gmt)
        XCTAssertEqual(composed, """
        My answer.

        On Jan 1, 1970, at 12:00 AM, Pat <p@x.com> wrote:

        > question?
        """)
    }
}
