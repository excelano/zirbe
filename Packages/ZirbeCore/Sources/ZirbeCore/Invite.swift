// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A calendar invitation as a mail client shows and threads it: the fields read
// off an iCalendar (RFC 5545) body carried as a `text/calendar` part. The same
// value describes the first invite, an update to it (a higher sequence), its
// cancellation, and an attendee's answer; `method` says which. The UID is the
// meeting's identity across all of them, so the conversation threads by it.

import Foundation

public struct Invite: Sendable, Hashable, Codable {
    /// What the message does to the meeting. `.publish` when the VCALENDAR
    /// carries no METHOD (a plain event, not an invitation).
    public enum Method: Sendable, Hashable, Codable {
        case request, cancel, reply, publish
        case other(String)
    }

    /// An attendee's answer, from `PARTSTAT`. `.needsAction` when absent.
    public enum ParticipationStatus: Sendable, Hashable, Codable {
        case needsAction, accepted, tentative, declined
        case other(String)
    }

    public struct Attendee: Sendable, Hashable, Codable {
        public var name: String?
        /// Lowercased, with the `mailto:` scheme stripped.
        public var address: String
        public var status: ParticipationStatus

        public init(name: String? = nil, address: String, status: ParticipationStatus = .needsAction) {
            self.name = name
            self.address = address.lowercased()
            self.status = status
        }

        /// The name when there is one, else the address.
        public var label: String { name ?? address }
    }

    /// `UID`: the meeting's identity across the invite, its updates, its
    /// cancellation, and every reply.
    public var uid: String
    /// `SEQUENCE`, 0 when absent. A higher value supersedes a lower one.
    public var sequence: Int
    public var method: Method
    public var summary: String?
    /// Absolute instants. A floating time is resolved in `timeZoneID` when the
    /// property carried a `TZID`, else in the zone the parser was given.
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    /// The Olson identifier the start was resolved in, when known.
    public var timeZoneID: String?
    public var location: String?
    public var organizer: Attendee?
    public var attendees: [Attendee]
    /// `RRULE` rendered readable ("Weekly on Tuesday"); nil for one occurrence.
    public var recurrence: String?
    /// A meeting join link: Microsoft's Teams property, else the first Teams,
    /// Zoom, Meet, or Webex URL in the location or description.
    public var joinURL: URL?
    /// `DESCRIPTION` unfolded and unescaped, or the HTML alternative reduced to
    /// text when only that is present.
    public var description: String?
    /// `METHOD:CANCEL` or `STATUS:CANCELLED`.
    public var isCancelled: Bool

    public init(
        uid: String,
        sequence: Int = 0,
        method: Method = .request,
        summary: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool = false,
        timeZoneID: String? = nil,
        location: String? = nil,
        organizer: Attendee? = nil,
        attendees: [Attendee] = [],
        recurrence: String? = nil,
        joinURL: URL? = nil,
        description: String? = nil,
        isCancelled: Bool = false
    ) {
        self.uid = uid
        self.sequence = sequence
        self.method = method
        self.summary = summary
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.recurrence = recurrence
        self.joinURL = joinURL
        self.description = description
        self.isCancelled = isCancelled
    }

    /// Whether this message answers an invitation rather than issuing one, so
    /// the conversation shows it as a line ("Pat accepted"), not a card.
    public var isReply: Bool { method == .reply }

    /// The answering attendee of a reply: the one attendee a REPLY carries.
    public var replyingAttendee: Attendee? { isReply ? attendees.first : nil }

    /// A one-line reading for the inbox row and a notification: what this
    /// message does to the meeting, then its title.
    public var glance: String {
        let title = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lead: String
        if isReply, let attendee = replyingAttendee {
            switch attendee.status {
            case .accepted: lead = "\(attendee.label) accepted"
            case .tentative: lead = "\(attendee.label) might attend"
            case .declined: lead = "\(attendee.label) declined"
            case .needsAction, .other: lead = "\(attendee.label) replied"
            }
        } else if isCancelled {
            lead = "Cancelled"
        } else if sequence > 0 {
            lead = "Updated"
        } else {
            lead = "Invitation"
        }
        return title.isEmpty ? lead : "\(lead): \(title)"
    }

    /// The words search should find this invitation by.
    public var searchText: String {
        [summary, location, organizer?.label, description].compactMap { $0 }.joined(separator: "\n")
    }

    /// The threading key every message about this meeting shares: the invite,
    /// its updates, its cancellation, and each attendee's answer.
    public var threadKey: String { "ical:\(uid)" }
}
