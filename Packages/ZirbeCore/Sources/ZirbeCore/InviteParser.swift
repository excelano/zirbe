// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Read an iCalendar (RFC 5545) body into an `Invite`. Pure and offline: line
// unfolding, property parameters, text unescaping, the date forms (all-day,
// floating, zoned by TZID, UTC), DTEND defaults from DURATION, attendees with
// their answers, a readable rendering of RRULE, and a meeting join link from
// the Microsoft, Google, and Zoom conventions. Outlook names time zones in
// Windows form ("Eastern Standard Time"), so a Windows-to-Olson table rides
// along. Never throws: an unreadable property is dropped, not fatal, and only a
// VEVENT without a UID yields nothing, since nothing could be threaded by it.
//
// This lives in ZirbeCore rather than Klartext on purpose: Klartext admits a
// thing only with two real consumers, and Blick reads meetings as typed Graph
// fields, so today this has one. It moves if a second consumer appears.

import Foundation
import Klartext

public enum InviteParser {
    /// Parse one iCalendar body. `defaultTimeZone` resolves floating times and
    /// all-day dates, and any TZID the table can't name.
    public static func parse(iCalendar text: String, defaultTimeZone: TimeZone = .current) -> Invite? {
        let lines = unfold(text)
        var method: Invite.Method = .publish
        var event: [ContentLine] = []
        var inEvent = false
        var depth: [String] = []

        for line in lines {
            guard let parsed = ContentLine(line) else { continue }
            switch parsed.name {
            case "BEGIN":
                depth.append(parsed.value.uppercased())
                if parsed.value.uppercased() == "VEVENT", event.isEmpty { inEvent = true }
            case "END":
                if parsed.value.uppercased() == "VEVENT", inEvent {
                    inEvent = false
                    // Only the first VEVENT is read; a later one is a recurrence
                    // exception, out of scope for now.
                    depth.removeLast()
                    continue
                }
                if !depth.isEmpty { depth.removeLast() }
            case "METHOD" where depth == ["VCALENDAR"]:
                method = Invite.Method(raw: parsed.value)
            default:
                if inEvent, depth.last == "VEVENT" { event.append(parsed) }
            }
        }

        guard let uid = event.first(where: { $0.name == "UID" })?.value.trimmingCharacters(in: .whitespaces),
              !uid.isEmpty else { return nil }

        func first(_ name: String) -> ContentLine? { event.first { $0.name == name } }
        func property(_ name: String) -> String? {
            first(name).map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        let startLine = first("DTSTART")
        let isAllDay = startLine?.params["VALUE"]?.uppercased() == "DATE"
            || (startLine.map { $0.value.count == 8 } ?? false)
        let (start, zoneID) = startLine.map { date(from: $0, allDay: isAllDay, defaultZone: defaultTimeZone) } ?? (nil, nil)
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? defaultTimeZone

        var end: Date?
        if let endLine = first("DTEND") {
            end = date(from: endLine, allDay: isAllDay, defaultZone: defaultTimeZone).0
        } else if let start {
            if let duration = first("DURATION").flatMap({ self.duration($0.value) }) {
                end = start.addingTimeInterval(duration)
            } else if isAllDay {
                end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: start)
            } else {
                end = start
            }
        }

        let organizer = first("ORGANIZER").flatMap(attendee)
        let attendees = event.filter { $0.name == "ATTENDEE" }.compactMap(attendee)
        let location = property("LOCATION")
        let description = property("DESCRIPTION")
            ?? first("X-ALT-DESC").map { Klartext.plainText(fromHTML: unescape($0.value)) }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let status = first("STATUS")?.value.uppercased()

        return Invite(
            uid: uid,
            sequence: first("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0,
            method: method,
            summary: property("SUMMARY"),
            start: start,
            end: end,
            isAllDay: isAllDay,
            timeZoneID: zoneID,
            location: location,
            organizer: organizer,
            attendees: attendees,
            recurrence: first("RRULE").flatMap { recurrence($0.value, zone: zone) },
            joinURL: joinURL(explicit: [first("X-MICROSOFT-SKYPETEAMSMEETINGURL"), first("X-GOOGLE-CONFERENCE")].compactMap { $0?.value },
                             searching: [location, description].compactMap { $0 }),
            description: description,
            isCancelled: method == .cancel || status == "CANCELLED"
        )
    }

    // MARK: Lines

    /// One content line: `NAME;PARAM=VALUE;PARAM="quoted":value`.
    struct ContentLine {
        let name: String
        let params: [String: String]
        let value: String

        init?(_ line: String) {
            // The first ':' outside double quotes ends the name-and-parameters.
            var inQuotes = false
            var colon: String.Index?
            for index in line.indices {
                let ch = line[index]
                if ch == "\"" { inQuotes.toggle() }
                if ch == ":", !inQuotes { colon = index; break }
            }
            guard let colon else { return nil }
            let head = line[..<colon]
            value = String(line[line.index(after: colon)...])
            let pieces = split(head, on: ";")
            guard let rawName = pieces.first, !rawName.isEmpty else { return nil }
            name = rawName.uppercased()
            var params: [String: String] = [:]
            for piece in pieces.dropFirst() {
                let kv = piece.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                params[kv[0].uppercased()] = kv[1].replacingOccurrences(of: "\"", with: "")
            }
            self.params = params
        }
    }

    /// Split on a separator, ignoring separators inside double quotes.
    private static func split(_ text: Substring, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle() }
            if ch == separator, !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    /// Join folded continuation lines (a line starting with a space or tab
    /// continues the previous one) and drop blank lines.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if let firstChar = raw.first, firstChar == " " || firstChar == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// RFC 5545 text unescaping: `\n` and `\N` to a newline, `\,` `\;` `\\` to
    /// the literal character.
    static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else { result.append(ch); continue }
            switch next {
            case "n", "N": result.append("\n")
            case ",", ";", "\\": result.append(next)
            default: result.append("\\"); result.append(next)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Dates

    /// A date property's instant and the Olson zone it was resolved in (nil for
    /// UTC and for floating or all-day values resolved in the default zone).
    private static func date(from line: ContentLine, allDay: Bool, defaultZone: TimeZone) -> (Date?, String?) {
        let raw = line.value.trimmingCharacters(in: .whitespaces)
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 8,
              let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)) else { return (nil, nil) }
        var components = DateComponents(year: year, month: month, day: day)
        if !allDay, digits.count >= 14 {
            components.hour = Int(digits.dropFirst(8).prefix(2))
            components.minute = Int(digits.dropFirst(10).prefix(2))
            components.second = Int(digits.dropFirst(12).prefix(2))
        }
        var zone = defaultZone
        var zoneID: String?
        if raw.hasSuffix("Z"), !allDay {
            zone = TimeZone(identifier: "UTC")!
        } else if let tzid = line.params["TZID"], let resolved = timeZone(named: tzid) {
            zone = resolved
            zoneID = resolved.identifier
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (calendar.date(from: components), zoneID)
    }

    /// Resolve a TZID: an Olson identifier as is, else Outlook's Windows name
    /// through the table, else nil (the caller falls back to the default zone).
    static func timeZone(named tzid: String) -> TimeZone? {
        let trimmed = tzid.trimmingCharacters(in: .whitespaces)
        if let zone = TimeZone(identifier: trimmed) { return zone }
        if let olson = windowsZones[trimmed], let zone = TimeZone(identifier: olson) { return zone }
        // Some servers prefix a vendor path ("/mozilla.org/.../Europe/Berlin").
        if let slash = trimmed.range(of: "/", options: .backwards),
           let region = trimmed[..<slash.lowerBound].split(separator: "/").last {
            let candidate = "\(region)/\(trimmed[slash.upperBound...])"
            if let zone = TimeZone(identifier: candidate) { return zone }
        }
        return nil
    }

    /// An RFC 5545 DURATION (`P1DT2H30M`, `PT45M`, `P2W`) in seconds.
    static func duration(_ value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: Double = 1
        if text.hasPrefix("-") { sign = -1; text = text.dropFirst() } else if text.hasPrefix("+") { text = text.dropFirst() }
        guard text.hasPrefix("P") else { return nil }
        text = text.dropFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        for ch in text {
            if ch.isNumber { number.append(ch); continue }
            if ch == "T" { inTime = true; continue }
            guard let n = Double(number) else { return nil }
            number = ""
            switch ch {
            case "W": total += n * 7 * 86_400
            case "D": total += n * 86_400
            case "H" where inTime: total += n * 3_600
            case "M" where inTime: total += n * 60
            case "S" where inTime: total += n
            default: return nil
            }
        }
        return number.isEmpty ? sign * total : nil
    }

    // MARK: People

    private static func attendee(_ line: ContentLine) -> Invite.Attendee? {
        var address = line.value.trimmingCharacters(in: .whitespaces)
        if let range = address.range(of: "mailto:", options: .caseInsensitive) { address = String(address[range.upperBound...]) }
        guard !address.isEmpty else { return nil }
        let name = line.params["CN"].flatMap { $0.isEmpty || $0.caseInsensitiveCompare(address) == .orderedSame ? nil : $0 }
        return Invite.Attendee(
            name: name,
            address: address,
            status: line.params["PARTSTAT"].map(Invite.ParticipationStatus.init(raw:)) ?? .needsAction
        )
    }

    // MARK: Recurrence

    /// A readable rendering of an RRULE: frequency, interval, weekdays, an
    /// ordinal for a monthly weekday, and the end by count or date.
    static func recurrence(_ rule: String, zone: TimeZone) -> String? {
        var fields: [String: String] = [:]
        for pair in rule.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            fields[kv[0].uppercased()] = String(kv[1]).uppercased()
        }
        guard let freq = fields["FREQ"] else { return nil }
        let interval = fields["INTERVAL"].flatMap(Int.init) ?? 1
        let days = fields["BYDAY"]?.split(separator: ",").map(String.init) ?? []

        var text: String
        switch freq {
        case "DAILY":
            text = interval == 1 ? "Daily" : "Every \(interval) days"
        case "WEEKLY":
            let names = days.compactMap { weekdayName($0.filter(\.isLetter)) }
            if Set(days) == ["MO", "TU", "WE", "TH", "FR"] {
                text = interval == 1 ? "Every weekday" : "Every \(interval) weeks on weekdays"
            } else {
                text = interval == 1 ? "Weekly" : "Every \(interval) weeks"
                if !names.isEmpty { text += " on " + list(names) }
            }
        case "MONTHLY":
            text = interval == 1 ? "Monthly" : "Every \(interval) months"
            if let day = days.first, let name = weekdayName(day.filter(\.isLetter)),
               let ordinal = Int(day.filter { $0.isNumber || $0 == "-" }) {
                text += " on the \(ordinalName(ordinal)) \(name)"
            } else if let monthDay = fields["BYMONTHDAY"].flatMap(Int.init) {
                text += " on day \(monthDay)"
            }
        case "YEARLY":
            text = interval == 1 ? "Yearly" : "Every \(interval) years"
        default:
            return nil
        }

        if let count = fields["COUNT"].flatMap(Int.init) {
            text += count == 1 ? ", once" : ", \(count) times"
        } else if let until = fields["UNTIL"], let date = ContentLine("UNTIL:\(until)").flatMap({ self.date(from: $0, allDay: until.count == 8, defaultZone: zone).0 }) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.timeZone = zone
            text += " until \(formatter.string(from: date))"
        }
        return text
    }

    private static func weekdayName(_ code: String) -> String? {
        switch code {
        case "MO": "Monday"
        case "TU": "Tuesday"
        case "WE": "Wednesday"
        case "TH": "Thursday"
        case "FR": "Friday"
        case "SA": "Saturday"
        case "SU": "Sunday"
        default: nil
        }
    }

    private static func ordinalName(_ n: Int) -> String {
        switch n {
        case 1: "first"
        case 2: "second"
        case 3: "third"
        case 4: "fourth"
        case -1: "last"
        default: "\(n)th"
        }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    // MARK: Join link

    private static let meetingHosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com", "gotomeeting.com"]

    /// An explicit conference property wins; else the first meeting-host URL in
    /// the searched texts (location before description).
    static func joinURL(explicit: [String], searching texts: [String]) -> URL? {
        for value in explicit {
            if let url = URL(string: value.trimmingCharacters(in: .whitespaces)), url.scheme != nil { return url }
        }
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) else { return nil }
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                var candidate = String(text[range])
                while let last = candidate.last, ".,;:)]}>".contains(last) { candidate.removeLast() }
                guard let url = URL(string: candidate), let host = url.host?.lowercased(),
                      meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
                return url
            }
        }
        return nil
    }

    // MARK: Windows time zones

    /// Outlook's Windows zone names mapped to their territory-001 Olson zone,
    /// from CLDR's windowsZones table. The names Outlook actually emits in
    /// TZID; an unknown one falls back to the default zone.
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "UTC-11": "Etc/GMT+11",
        "Aleutian Standard Time": "America/Adak",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Marquesas Standard Time": "Pacific/Marquesas",
        "Alaskan Standard Time": "America/Anchorage",
        "UTC-09": "Etc/GMT+9",
        "Pacific Standard Time (Mexico)": "America/Tijuana",
        "UTC-08": "Etc/GMT+8",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Mountain Standard Time": "America/Denver",
        "Yukon Standard Time": "America/Whitehorse",
        "Central America Standard Time": "America/Guatemala",
        "Central Standard Time": "America/Chicago",
        "Easter Island Standard Time": "Pacific/Easter",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota",
        "Eastern Standard Time (Mexico)": "America/Cancun",
        "Eastern Standard Time": "America/New_York",
        "Haiti Standard Time": "America/Port-au-Prince",
        "Cuba Standard Time": "America/Havana",
        "US Eastern Standard Time": "America/Indianapolis",
        "Turks And Caicos Standard Time": "America/Grand_Turk",
        "Paraguay Standard Time": "America/Asuncion",
        "Atlantic Standard Time": "America/Halifax",
        "Venezuela Standard Time": "America/Caracas",
        "Central Brazilian Standard Time": "America/Cuiaba",
        "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns",
        "Tocantins Standard Time": "America/Araguaina",
        "E. South America Standard Time": "America/Sao_Paulo",
        "SA Eastern Standard Time": "America/Cayenne",
        "Argentina Standard Time": "America/Buenos_Aires",
        "Greenland Standard Time": "America/Godthab",
        "Montevideo Standard Time": "America/Montevideo",
        "Magallanes Standard Time": "America/Punta_Arenas",
        "Saint Pierre Standard Time": "America/Miquelon",
        "Bahia Standard Time": "America/Bahia",
        "UTC-02": "Etc/GMT+2",
        "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde",
        "UTC": "Etc/UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "Sao Tome Standard Time": "Africa/Sao_Tome",
        "Morocco Standard Time": "Africa/Casablanca",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos",
        "GTB Standard Time": "Europe/Bucharest",
        "Middle East Standard Time": "Asia/Beirut",
        "Egypt Standard Time": "Africa/Cairo",
        "E. Europe Standard Time": "Europe/Chisinau",
        "West Bank Standard Time": "Asia/Hebron",
        "South Africa Standard Time": "Africa/Johannesburg",
        "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem",
        "South Sudan Standard Time": "Africa/Juba",
        "Kaliningrad Standard Time": "Europe/Kaliningrad",
        "Sudan Standard Time": "Africa/Khartoum",
        "Libya Standard Time": "Africa/Tripoli",
        "Namibia Standard Time": "Africa/Windhoek",
        "Jordan Standard Time": "Asia/Amman",
        "Arabic Standard Time": "Asia/Baghdad",
        "Syria Standard Time": "Asia/Damascus",
        "Turkey Standard Time": "Europe/Istanbul",
        "Arab Standard Time": "Asia/Riyadh",
        "Belarus Standard Time": "Europe/Minsk",
        "Russian Standard Time": "Europe/Moscow",
        "E. Africa Standard Time": "Africa/Nairobi",
        "Volgograd Standard Time": "Europe/Volgograd",
        "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai",
        "Astrakhan Standard Time": "Europe/Astrakhan",
        "Azerbaijan Standard Time": "Asia/Baku",
        "Russia Time Zone 3": "Europe/Samara",
        "Mauritius Standard Time": "Indian/Mauritius",
        "Saratov Standard Time": "Europe/Saratov",
        "Georgian Standard Time": "Asia/Tbilisi",
        "Caucasus Standard Time": "Asia/Yerevan",
        "Afghanistan Standard Time": "Asia/Kabul",
        "West Asia Standard Time": "Asia/Tashkent",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "Pakistan Standard Time": "Asia/Karachi",
        "Qyzylorda Standard Time": "Asia/Qyzylorda",
        "India Standard Time": "Asia/Calcutta",
        "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Katmandu",
        "Central Asia Standard Time": "Asia/Bishkek",
        "Bangladesh Standard Time": "Asia/Dhaka",
        "Omsk Standard Time": "Asia/Omsk",
        "Myanmar Standard Time": "Asia/Rangoon",
        "SE Asia Standard Time": "Asia/Bangkok",
        "Altai Standard Time": "Asia/Barnaul",
        "W. Mongolia Standard Time": "Asia/Hovd",
        "North Asia Standard Time": "Asia/Krasnoyarsk",
        "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "Tomsk Standard Time": "Asia/Tomsk",
        "China Standard Time": "Asia/Shanghai",
        "North Asia East Standard Time": "Asia/Irkutsk",
        "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth",
        "Taipei Standard Time": "Asia/Taipei",
        "Ulaanbaatar Standard Time": "Asia/Ulaanbaatar",
        "Aus Central W. Standard Time": "Australia/Eucla",
        "Transbaikal Standard Time": "Asia/Chita",
        "Tokyo Standard Time": "Asia/Tokyo",
        "North Korea Standard Time": "Asia/Pyongyang",
        "Korea Standard Time": "Asia/Seoul",
        "Yakutsk Standard Time": "Asia/Yakutsk",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Tasmania Standard Time": "Australia/Hobart",
        "Vladivostok Standard Time": "Asia/Vladivostok",
        "Lord Howe Standard Time": "Australia/Lord_Howe",
        "Bougainville Standard Time": "Pacific/Bougainville",
        "Russia Time Zone 10": "Asia/Srednekolymsk",
        "Magadan Standard Time": "Asia/Magadan",
        "Norfolk Standard Time": "Pacific/Norfolk",
        "Sakhalin Standard Time": "Asia/Sakhalin",
        "Central Pacific Standard Time": "Pacific/Guadalcanal",
        "Russia Time Zone 11": "Asia/Kamchatka",
        "New Zealand Standard Time": "Pacific/Auckland",
        "UTC+12": "Etc/GMT-12",
        "Fiji Standard Time": "Pacific/Fiji",
        "Chatham Islands Standard Time": "Pacific/Chatham",
        "UTC+13": "Etc/GMT-13",
        "Tonga Standard Time": "Pacific/Tongatapu",
        "Samoa Standard Time": "Pacific/Apia",
        "Line Islands Standard Time": "Pacific/Kiritimati",
    ]
}

extension Invite.Method {
    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "REQUEST": self = .request
        case "CANCEL": self = .cancel
        case "REPLY": self = .reply
        case "PUBLISH", "": self = .publish
        case let other: self = .other(other)
        }
    }
}

extension Invite.ParticipationStatus {
    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "NEEDS-ACTION", "": self = .needsAction
        case "ACCEPTED": self = .accepted
        case "TENTATIVE": self = .tentative
        case "DECLINED": self = .declined
        case let other: self = .other(other)
        }
    }
}
