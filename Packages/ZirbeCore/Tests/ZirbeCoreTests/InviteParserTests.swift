// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The iCalendar parser against the shapes Outlook and Google Calendar emit:
// folded lines, escaped text, Windows and Olson time zones, all-day and UTC
// forms, DURATION, attendees and their answers, updates by sequence,
// cancellations, replies, recurrence rendering, join links, and malformed
// input. These fixtures are modeled on real output; the real, redacted invites
// from the ics-dump command replace or join them as they arrive.

import XCTest
@testable import ZirbeCore

final class InviteParserTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func instant(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func parse(_ text: String, zone: TimeZone? = nil) -> Invite? {
        InviteParser.parse(iCalendar: text.replacingOccurrences(of: "\n", with: "\r\n"), defaultTimeZone: zone ?? berlin)
    }

    // MARK: Outlook

    private let outlookTeams = """
    BEGIN:VCALENDAR
    METHOD:REQUEST
    PRODID:Microsoft Exchange Server 2010
    VERSION:2.0
    BEGIN:VTIMEZONE
    TZID:Eastern Standard Time
    BEGIN:STANDARD
    DTSTART:16010101T020000
    TZOFFSETFROM:-0400
    TZOFFSETTO:-0500
    RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11
    END:STANDARD
    BEGIN:DAYLIGHT
    DTSTART:16010101T020000
    TZOFFSETFROM:-0500
    TZOFFSETTO:-0400
    RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3
    END:DAYLIGHT
    END:VTIMEZONE
    BEGIN:VEVENT
    ORGANIZER;CN=Pat Organizer:mailto:pat@x.com
    ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Me:mailto:me
     @x.com
    ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Sam Smith:mailto:sam@x.com
    DESCRIPTION:Quarterly review\\, part one.\\nAgenda attached.\\n\\n_____________
     ___________________________________________\\nMicrosoft Teams meeting\\nJoin on
      your computer: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d\\n
    UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4
    SUMMARY:Q3 Review\\; budget
    DTSTART;TZID=Eastern Standard Time:20260915T140000
    DTEND;TZID=Eastern Standard Time:20260915T150000
    CLASS:PUBLIC
    PRIORITY:5
    DTSTAMP:20260901T120000Z
    TRANSP:OPAQUE
    STATUS:CONFIRMED
    SEQUENCE:0
    LOCATION:Room 4B\\, HQ
    X-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.microsoft.com/l/meetup-join/1
     9%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22t%22%7d
    X-ALT-DESC;FMTTYPE=text/html:<html><body><p>Quarterly review</p></body></html>
    END:VEVENT
    END:VCALENDAR
    """

    func testOutlookTeamsInviteParsesEveryField() throws {
        let invite = try XCTUnwrap(parse(outlookTeams))

        XCTAssertEqual(invite.method, .request)
        XCTAssertEqual(invite.uid, "040000008200E00074C5B7101A82E00800000000A1B2C3D4")
        XCTAssertEqual(invite.sequence, 0)
        XCTAssertEqual(invite.summary, "Q3 Review; budget", "escaped semicolon unescaped")
        XCTAssertEqual(invite.location, "Room 4B, HQ", "escaped comma unescaped")
        XCTAssertEqual(invite.start, instant(2026, 9, 15, 14, 0, in: newYork), "a Windows TZID resolves through the table")
        XCTAssertEqual(invite.end, instant(2026, 9, 15, 15, 0, in: newYork))
        XCTAssertEqual(invite.timeZoneID, "America/New_York")
        XCTAssertFalse(invite.isAllDay)
        XCTAssertFalse(invite.isCancelled)
        XCTAssertEqual(invite.organizer?.name, "Pat Organizer")
        XCTAssertEqual(invite.organizer?.address, "pat@x.com")
        XCTAssertEqual(invite.attendees.map(\.address), ["me@x.com", "sam@x.com"], "a folded attendee line is rejoined")
        XCTAssertEqual(invite.attendees.map(\.status), [.needsAction, .accepted])
        XCTAssertEqual(invite.attendees.first?.name, "Me")
        XCTAssertEqual(invite.joinURL?.absoluteString, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22t%22%7d", "the explicit Teams property wins over the description link")
        XCTAssertEqual(invite.description?.hasPrefix("Quarterly review, part one.\nAgenda attached."), true)
        XCTAssertNil(invite.recurrence)
    }

    func testAnUpdateCarriesItsSequenceAndNewTime() throws {
        let update = outlookTeams
            .replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:2")
            .replacingOccurrences(of: "DTSTART;TZID=Eastern Standard Time:20260915T140000", with: "DTSTART;TZID=Eastern Standard Time:20260916T090000")
            .replacingOccurrences(of: "DTEND;TZID=Eastern Standard Time:20260915T150000", with: "DTEND;TZID=Eastern Standard Time:20260916T093000")
        let invite = try XCTUnwrap(parse(update))

        XCTAssertEqual(invite.sequence, 2)
        XCTAssertEqual(invite.start, instant(2026, 9, 16, 9, 0, in: newYork))
        XCTAssertEqual(invite.end, instant(2026, 9, 16, 9, 30, in: newYork))
        XCTAssertEqual(invite.uid, "040000008200E00074C5B7101A82E00800000000A1B2C3D4", "the same meeting")
    }

    func testACancellationIsMarked() throws {
        let cancel = outlookTeams
            .replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL")
            .replacingOccurrences(of: "STATUS:CONFIRMED", with: "STATUS:CANCELLED")
        let invite = try XCTUnwrap(parse(cancel))
        XCTAssertEqual(invite.method, .cancel)
        XCTAssertTrue(invite.isCancelled)

        let statusOnly = outlookTeams.replacingOccurrences(of: "STATUS:CONFIRMED", with: "STATUS:CANCELLED")
        XCTAssertTrue(try XCTUnwrap(parse(statusOnly)).isCancelled, "STATUS:CANCELLED alone counts")
    }

    func testAnAttendeeReplyNamesWhoAnsweredAndHow() throws {
        let reply = """
        BEGIN:VCALENDAR
        METHOD:REPLY
        VERSION:2.0
        BEGIN:VEVENT
        ATTENDEE;PARTSTAT=TENTATIVE;CN=Sam Smith:mailto:sam@x.com
        ORGANIZER;CN=Pat Organizer:mailto:pat@x.com
        UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4
        SUMMARY:Tentative: Q3 Review
        DTSTART;TZID=Eastern Standard Time:20260915T140000
        DTEND;TZID=Eastern Standard Time:20260915T150000
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try XCTUnwrap(parse(reply))
        XCTAssertTrue(invite.isReply)
        XCTAssertEqual(invite.replyingAttendee?.address, "sam@x.com")
        XCTAssertEqual(invite.replyingAttendee?.status, .tentative)
        XCTAssertEqual(invite.replyingAttendee?.label, "Sam Smith")
    }

    // MARK: Google

    private let google = """
    BEGIN:VCALENDAR
    PRODID:-//Google Inc//Google Calendar 70.9054//EN
    VERSION:2.0
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    DTSTART;TZID=Europe/Berlin:20261002T100000
    DTEND;TZID=Europe/Berlin:20261002T104500
    DTSTAMP:20260920T080000Z
    ORGANIZER;CN=pat@x.com:mailto:pat@x.com
    UID:abc123def456@google.com
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE
     ;CN=me@x.com;X-NUM-GUESTS=0:mailto:me@x.com
    X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
    CREATED:20260920T075900Z
    DESCRIPTION:Sync on the plan.\\n\\n-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~
     :~:~:~:~::~:~::-\\nJoin with Google Meet: https://meet.google.com/abc-defg-hij\\n
    LAST-MODIFIED:20260920T080000Z
    LOCATION:
    SEQUENCE:0
    STATUS:CONFIRMED
    SUMMARY:Plan sync
    TRANSP:OPAQUE
    END:VEVENT
    END:VCALENDAR
    """

    func testGoogleInviteResolvesOlsonZoneAndMeetLink() throws {
        let invite = try XCTUnwrap(parse(google, zone: newYork))

        XCTAssertEqual(invite.start, instant(2026, 10, 2, 10, 0, in: berlin), "an Olson TZID is used as is, whatever the default zone")
        XCTAssertEqual(invite.end, instant(2026, 10, 2, 10, 45, in: berlin))
        XCTAssertEqual(invite.timeZoneID, "Europe/Berlin")
        XCTAssertEqual(invite.summary, "Plan sync")
        XCTAssertNil(invite.location, "an empty LOCATION is nil, not an empty string")
        XCTAssertNil(invite.organizer?.name, "a CN equal to the address is no name")
        XCTAssertEqual(invite.organizer?.address, "pat@x.com")
        XCTAssertEqual(invite.attendees.map(\.address), ["me@x.com"])
        XCTAssertEqual(invite.joinURL?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(invite.description?.hasPrefix("Sync on the plan."), true)
    }

    // MARK: Date forms

    func testAllDayEventEndsTheNextDayWhenDTENDIsAbsent() throws {
        let invite = try XCTUnwrap(parse("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:allday@x
        SUMMARY:Offsite
        DTSTART;VALUE=DATE:20261105
        END:VEVENT
        END:VCALENDAR
        """))
        XCTAssertTrue(invite.isAllDay)
        XCTAssertEqual(invite.start, instant(2026, 11, 5, in: berlin), "midnight in the default zone")
        XCTAssertEqual(invite.end, instant(2026, 11, 6, in: berlin))
        XCTAssertEqual(invite.method, .publish, "no METHOD reads as a plain event")
        XCTAssertNil(invite.timeZoneID)
    }

    func testUTCFloatingAndDurationForms() throws {
        let utc = try XCTUnwrap(parse("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:utc@x
        DTSTART:20260915T180000Z
        DURATION:PT1H30M
        END:VEVENT
        END:VCALENDAR
        """))
        XCTAssertEqual(utc.start, instant(2026, 9, 15, 14, 0, in: newYork), "18:00Z is 14:00 in New York")
        XCTAssertEqual(utc.end, instant(2026, 9, 15, 15, 30, in: newYork), "DURATION supplies the end")
        XCTAssertNil(utc.timeZoneID)

        let floating = try XCTUnwrap(parse("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:floating@x
        DTSTART:20260915T090000
        END:VEVENT
        END:VCALENDAR
        """, zone: newYork))
        XCTAssertEqual(floating.start, instant(2026, 9, 15, 9, 0, in: newYork), "a floating time is wall-clock in the default zone")
        XCTAssertEqual(floating.end, floating.start, "no DTEND and no DURATION: a point in time")
    }

    func testAnUnknownTZIDFallsBackToTheDefaultZone() throws {
        let invite = try XCTUnwrap(parse("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:odd@x
        DTSTART;TZID=Nowhere Standard Time:20260915T090000
        END:VEVENT
        END:VCALENDAR
        """, zone: newYork))
        XCTAssertEqual(invite.start, instant(2026, 9, 15, 9, 0, in: newYork))
        XCTAssertNil(invite.timeZoneID)
    }

    func testTimeZoneLookupCoversOlsonWindowsAndVendorPrefixedNames() {
        XCTAssertEqual(InviteParser.timeZone(named: "Europe/Berlin")?.identifier, "Europe/Berlin")
        XCTAssertEqual(InviteParser.timeZone(named: "Pacific Standard Time")?.identifier, "America/Los_Angeles")
        XCTAssertEqual(InviteParser.timeZone(named: "W. Europe Standard Time")?.identifier, "Europe/Berlin")
        XCTAssertEqual(InviteParser.timeZone(named: "/mozilla.org/20050126_1/Europe/Berlin")?.identifier, "Europe/Berlin")
        XCTAssertNil(InviteParser.timeZone(named: "Nowhere Standard Time"))
    }

    func testDurations() {
        XCTAssertEqual(InviteParser.duration("PT45M"), 45 * 60)
        XCTAssertEqual(InviteParser.duration("P1DT2H"), 26 * 3600)
        XCTAssertEqual(InviteParser.duration("P2W"), 14 * 86_400)
        XCTAssertEqual(InviteParser.duration("-PT10M"), -600)
        XCTAssertNil(InviteParser.duration("45M"))
        XCTAssertNil(InviteParser.duration("P1X"))
    }

    // MARK: Recurrence

    func testRecurrenceRendersReadably() {
        let zone = berlin
        XCTAssertEqual(InviteParser.recurrence("FREQ=WEEKLY;BYDAY=TU", zone: zone), "Weekly on Tuesday")
        XCTAssertEqual(InviteParser.recurrence("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR", zone: zone), "Every 2 weeks on Monday, Wednesday, and Friday")
        XCTAssertEqual(InviteParser.recurrence("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", zone: zone), "Every weekday")
        XCTAssertEqual(InviteParser.recurrence("FREQ=DAILY;COUNT=10", zone: zone), "Daily, 10 times")
        XCTAssertEqual(InviteParser.recurrence("FREQ=MONTHLY;BYDAY=2TU", zone: zone), "Monthly on the second Tuesday")
        XCTAssertEqual(InviteParser.recurrence("FREQ=MONTHLY;BYDAY=-1FR", zone: zone), "Monthly on the last Friday")
        XCTAssertEqual(InviteParser.recurrence("FREQ=MONTHLY;BYMONTHDAY=15", zone: zone), "Monthly on day 15")
        XCTAssertEqual(InviteParser.recurrence("FREQ=YEARLY", zone: zone), "Yearly")
        XCTAssertNil(InviteParser.recurrence("FREQ=SECONDLY", zone: zone))

        let until = InviteParser.recurrence("FREQ=WEEKLY;BYDAY=TU;UNTIL=20261215T225959Z", zone: zone)
        XCTAssertEqual(until?.hasPrefix("Weekly on Tuesday until "), true)
        XCTAssertEqual(until?.contains("2026"), true)
    }

    // MARK: Join links

    func testJoinLinkIsFoundInLocationBeforeDescriptionAndTrimmed() {
        let url = InviteParser.joinURL(
            explicit: [],
            searching: ["Zoom: https://us02web.zoom.us/j/123456789?pwd=abc.", "https://teams.microsoft.com/l/x"]
        )
        XCTAssertEqual(url?.absoluteString, "https://us02web.zoom.us/j/123456789?pwd=abc", "the trailing period is not part of the link")

        let none = InviteParser.joinURL(explicit: [], searching: ["See https://example.com/agenda for details"])
        XCTAssertNil(none, "an ordinary link is not a join link")

        let explicit = InviteParser.joinURL(explicit: ["https://teams.microsoft.com/l/meetup-join/abc"], searching: ["https://zoom.us/j/1"])
        XCTAssertEqual(explicit?.host, "teams.microsoft.com")
    }

    // MARK: Text handling

    func testUnfoldingAndUnescaping() {
        XCTAssertEqual(InviteParser.unfold("A:1\r\n b\r\nC:2\r\n\tc\r\n\r\nD:3"), ["A:1b", "C:2c", "D:3"])
        XCTAssertEqual(InviteParser.unescape(#"one\, two\; three\\ four\nfive\N"#), "one, two; three\\ four\nfive\n".trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(InviteParser.unescape(#"a\qb"#), #"a\qb"#, "an unknown escape is kept verbatim")
    }

    func testAColonInsideAQuotedParameterDoesNotEndTheName() throws {
        let line = try XCTUnwrap(InviteParser.ContentLine(#"ATTENDEE;CN="Smith, Sam: PM";PARTSTAT=ACCEPTED:mailto:sam@x.com"#))
        XCTAssertEqual(line.name, "ATTENDEE")
        XCTAssertEqual(line.params["CN"], "Smith, Sam: PM")
        XCTAssertEqual(line.params["PARTSTAT"], "ACCEPTED")
        XCTAssertEqual(line.value, "mailto:sam@x.com")
    }

    // MARK: Malformed input

    func testGarbageAndAMissingUIDYieldNothing() {
        XCTAssertNil(parse("hello"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:No identity
        DTSTART:20260915T090000Z
        END:VEVENT
        END:VCALENDAR
        """), "a VEVENT without a UID can't be threaded, so it is nothing")
    }

    func testATruncatedFileStillYieldsWhatItHas() throws {
        let truncated = String(outlookTeams.prefix(through: outlookTeams.range(of: "DTEND;TZID=Eastern Standard Time:20260915T150000")!.upperBound))
        let invite = try XCTUnwrap(parse(truncated))
        XCTAssertEqual(invite.summary, "Q3 Review; budget")
        XCTAssertEqual(invite.end, instant(2026, 9, 15, 15, 0, in: newYork))
        XCTAssertNil(invite.location, "cut off before LOCATION")
    }

    func testOnlyTheFirstVEVENTIsRead() throws {
        let two = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:series@x
        SUMMARY:Standup
        DTSTART:20260915T090000Z
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:series@x
        RECURRENCE-ID:20260916T090000Z
        SUMMARY:Standup (moved)
        DTSTART:20260916T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try XCTUnwrap(parse(two))
        XCTAssertEqual(invite.summary, "Standup")
        XCTAssertEqual(invite.recurrence, "Daily")
    }

    func testInviteRoundTripsThroughJSON() throws {
        let invite = try XCTUnwrap(parse(outlookTeams))
        let data = try JSONEncoder().encode(invite)
        let decoded = try JSONDecoder().decode(Invite.self, from: data)
        XCTAssertEqual(decoded, invite, "the store column carries it as JSON")
    }
}
