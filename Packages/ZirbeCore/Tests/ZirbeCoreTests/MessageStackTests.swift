import XCTest
@testable import ZirbeCore

/// How messages group into runs and where day separators fall. This drives the
/// tail, the sender name, the spacing between runs, and the date dividers — all of
/// it previously derived inline in the view and untested.
final class MessageStackTests: XCTestCase {
    private let me = "me@x.com"
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Days since the epoch, at noon UTC, so a shift of hours can't cross midnight.
    private func day(_ n: Int, hour: Int = 12) -> Date {
        Date(timeIntervalSince1970: TimeInterval(n * 86_400 + hour * 3_600))
    }

    private func msg(_ id: String, from: String, at date: Date?) -> Message {
        Message(
            messageID: "<\(id)@x>",
            subject: "Lunch",
            from: Participant(address: from),
            date: date,
            flags: [.seen]
        )
    }

    private func rows(_ messages: [Message]) -> [StackedMessage] {
        MessageStack.rows(messages, ownedBy: me, calendar: calendar)
    }

    func testARunEndsWhenTheSenderChanges() {
        let stacked = rows([
            msg("a", from: "p@x.com", at: day(1, hour: 9)),
            msg("b", from: "p@x.com", at: day(1, hour: 10)),
            msg("c", from: me, at: day(1, hour: 11)),
        ])

        // Only the last message of each run carries the tail.
        XCTAssertEqual(stacked.map(\.hasTail), [false, true, true])
        // The sender's name shows once, atop their run, and never on your own.
        XCTAssertEqual(stacked.map(\.showSender), [true, false, false])
        XCTAssertEqual(stacked.map(\.isOwn), [false, false, true])
    }

    func testAloneMessageBothOpensAndClosesItsRun() {
        let stacked = rows([msg("a", from: "p@x.com", at: day(1))])
        XCTAssertEqual(stacked.map(\.hasTail), [true])
        XCTAssertEqual(stacked.map(\.showSender), [true])
    }

    /// The first message opens a run but takes no spacing above it — there is
    /// nothing above it to be spaced from.
    func testTheFirstRunTakesNoSpacingAboveIt() {
        let stacked = rows([
            msg("a", from: "p@x.com", at: day(1, hour: 9)),
            msg("b", from: me, at: day(1, hour: 10)),
            msg("c", from: me, at: day(1, hour: 11)),
            msg("d", from: "p@x.com", at: day(1, hour: 12)),
        ])
        XCTAssertEqual(stacked.map(\.needsRunSpacing), [false, true, false, true])
    }

    func testTheFirstDatedMessageOpensADay() {
        let stacked = rows([msg("a", from: "p@x.com", at: day(1))])
        XCTAssertEqual(stacked.first?.daySeparator, day(1))
    }

    func testASeparatorFallsOnlyWhereTheCalendarDayChanges() {
        let stacked = rows([
            msg("a", from: "p@x.com", at: day(1, hour: 9)),
            msg("b", from: "p@x.com", at: day(1, hour: 23)),
            msg("c", from: "p@x.com", at: day(2, hour: 1)),
        ])
        XCTAssertNotNil(stacked[0].daySeparator, "the first dated message opens a day")
        XCTAssertNil(stacked[1].daySeparator, "same day, no divider")
        XCTAssertEqual(stacked[2].daySeparator, day(2, hour: 1), "a new day gets one")
    }

    /// A message with no date can't caption a separator, and mustn't swallow the
    /// day boundary for the message after it either.
    func testAnUndatedMessageCarriesNoSeparatorAndHidesNoBoundary() {
        let stacked = rows([
            msg("a", from: "p@x.com", at: day(1)),
            msg("b", from: "p@x.com", at: nil),
            msg("c", from: "p@x.com", at: day(2)),
        ])
        XCTAssertNil(stacked[1].daySeparator, "no date, no divider")
        XCTAssertEqual(stacked[2].daySeparator, day(2), "the day still turns over across it")
    }

    func testAnEmptyConversationLaysOutEmpty() {
        XCTAssertTrue(rows([]).isEmpty)
    }

    /// Identity is the message's, so SwiftUI keeps bubbles stable across a reload.
    func testRowIdentityIsTheMessageIdentity() {
        let one = msg("a", from: "p@x.com", at: day(1))
        XCTAssertEqual(rows([one]).first?.id, one.id)
    }
}
