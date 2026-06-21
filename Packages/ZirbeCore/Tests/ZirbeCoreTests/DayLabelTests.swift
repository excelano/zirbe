import XCTest
@testable import ZirbeCore

final class DayLabelTests: XCTestCase {
    /// A fixed calendar so the labels don't depend on the machine's locale or
    /// zone: Gregorian, UTC, en_US.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        return cal
    }()

    private func date(_ iso8601Day: String, _ time: String = "09:00:00") -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: "\(iso8601Day)T\(time)Z")!
    }

    /// Noon on 2026-06-20 (a Saturday), the "now" the labels are measured against.
    private lazy var now = date("2026-06-20", "12:00:00")

    func testToday() {
        XCTAssertEqual(DayLabel.text(for: date("2026-06-20"), now: now, calendar: calendar), "Today")
    }

    func testYesterday() {
        XCTAssertEqual(DayLabel.text(for: date("2026-06-19"), now: now, calendar: calendar), "Yesterday")
    }

    func testWithinPastWeekIsWeekdayName() {
        // 2026-06-17 is a Wednesday, three days back: shows the weekday.
        XCTAssertEqual(DayLabel.text(for: date("2026-06-17"), now: now, calendar: calendar), "Wednesday")
    }

    func testOlderThisYearIsShortDate() {
        XCTAssertEqual(DayLabel.text(for: date("2026-01-05"), now: now, calendar: calendar), "Jan 5")
    }

    func testPriorYearCarriesTheYear() {
        XCTAssertEqual(DayLabel.text(for: date("2025-11-30"), now: now, calendar: calendar), "Nov 30, 2025")
    }

    func testSevenDaysBackFallsToShortDate() {
        // Past the weekday window (only 2...6 days back get a weekday name).
        XCTAssertEqual(DayLabel.text(for: date("2026-06-13"), now: now, calendar: calendar), "Jun 13")
    }
}
