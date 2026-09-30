// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The parser against real invites, dumped from a mailbox by scripts/ics-dump.sh
// and redacted (addresses to numbered placeholders, names to "Person N", the
// venue and street changed). Where InviteParserTests pins each rule with a
// hand-shaped fixture, these pin what Outlook and Google actually send.

import XCTest
@testable import ZirbeCore

final class InviteFixtureTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func fixture(_ name: String) throws -> Invite {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ics", subdirectory: "Fixtures/Invites"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(InviteParser.parse(iCalendar: text, defaultTimeZone: .init(identifier: "UTC")!))
    }

    private func instant(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testOutlookInviteInWindowsCentralTime() throws {
        let invite = try fixture("outlook-request-seq0")
        XCTAssertEqual(invite.method, .request)
        XCTAssertEqual(invite.sequence, 0)
        XCTAssertEqual(invite.summary, "Lunch")
        XCTAssertEqual(invite.location, "TBD")
        XCTAssertEqual(invite.start, instant(2026, 9, 8, 11, 30), "Central Standard Time resolves to America/Chicago")
        XCTAssertEqual(invite.end, instant(2026, 9, 8, 12, 45))
        XCTAssertEqual(invite.timeZoneID, "America/Chicago")
        XCTAssertEqual(invite.organizer?.label, "Person 1")
        XCTAssertEqual(invite.attendees.count, 1)
        XCTAssertEqual(invite.attendees.first?.status, .needsAction)
        XCTAssertNil(invite.joinURL, "an empty X-MICROSOFT-SKYPETEAMSMEETINGURL is no link")
    }

    func testOutlookUpdatesShareTheUIDAndRaiseTheSequence() throws {
        let first = try fixture("outlook-request-seq0")
        let second = try fixture("outlook-request-seq1")
        let third = try fixture("outlook-request-seq2")
        XCTAssertEqual(first.uid, second.uid)
        XCTAssertEqual(second.uid, third.uid)
        XCTAssertEqual([first.sequence, second.sequence, third.sequence], [0, 1, 2])
        XCTAssertEqual(second.location?.hasPrefix("Harbor Grill"), true, "the first update added a venue")
        XCTAssertEqual(third.start, instant(2026, 9, 9, 11, 30), "the second update moved the day")
        XCTAssertEqual(third.end, instant(2026, 9, 9, 13, 15))
    }

    func testOutlookTeamsInviteCarriesTheJoinLink() throws {
        let invite = try fixture("outlook-teams-request")
        XCTAssertEqual(invite.location, "Microsoft Teams Meeting")
        XCTAssertEqual(invite.joinURL?.host, "teams.microsoft.com")
        XCTAssertEqual(invite.joinURL?.path.hasPrefix("/l/meetup-join/"), true)
        XCTAssertEqual(invite.description?.contains("Microsoft Teams meeting"), true)
    }

    func testGoogleWeeklyInvite() throws {
        let invite = try fixture("google-request-weekly")
        XCTAssertEqual(invite.summary, "test recurring from Google")
        XCTAssertEqual(invite.recurrence, "Weekly on Wednesday")
        XCTAssertEqual(invite.timeZoneID, "America/Chicago", "Google sends an Olson TZID")
        XCTAssertEqual(invite.start, instant(2026, 9, 9, 15, 15))
        XCTAssertEqual(invite.uid.hasSuffix("@google.com"), true, "Google UIDs look like addresses and must survive redaction")
        XCTAssertEqual(invite.organizer?.address, "user1@gmail.com")
    }
}
