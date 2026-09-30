// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Run iCalendar files through InviteParser and print what it read, one block
// per file. The companion to ZirbeMail's ics-dump: dump real invites, then see
// exactly how the parser understands them before they become fixtures. macOS
// only; not part of any app.
//
//   swift run ics-check ../../ics-dump/*.ics

import Foundation
import ZirbeCore

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: ics-check <file.ics> ...\n".utf8))
    exit(2)
}

let formatter = DateFormatter()
formatter.dateStyle = .medium
formatter.timeStyle = .short

var failures = 0
for path in paths {
    print("== \(URL(fileURLWithPath: path).lastPathComponent)")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("   unreadable")
        failures += 1
        continue
    }
    guard let invite = InviteParser.parse(iCalendar: text) else {
        print("   no invite (no VEVENT with a UID)")
        failures += 1
        continue
    }
    let zone = invite.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
    formatter.timeZone = zone
    let when: String
    if let start = invite.start, let end = invite.end {
        when = invite.isAllDay
            ? "\(formatter.string(from: start).components(separatedBy: " at ").first ?? "") (all day)"
            : "\(formatter.string(from: start)) to \(formatter.string(from: end)) \(zone.abbreviation() ?? zone.identifier)"
    } else {
        when = "(no time)"
    }
    print("   method:     \(invite.method)\(invite.isCancelled ? "  CANCELLED" : "")   sequence \(invite.sequence)")
    print("   uid:        \(invite.uid)")
    print("   summary:    \(invite.summary ?? "(none)")")
    print("   when:       \(when)")
    if let recurrence = invite.recurrence { print("   repeats:    \(recurrence)") }
    if let location = invite.location { print("   location:   \(location)") }
    if let organizer = invite.organizer { print("   organizer:  \(organizer.label) <\(organizer.address)>") }
    for attendee in invite.attendees {
        print("   attendee:   \(attendee.label) <\(attendee.address)>  \(attendee.status)")
    }
    if let url = invite.joinURL { print("   join:       \(url.absoluteString)") }
    if let description = invite.description {
        let firstLines = description.split(separator: "\n", omittingEmptySubsequences: true).prefix(3).joined(separator: " | ")
        print("   description: \(firstLines.prefix(160))\(description.count > 160 ? "…" : "")")
    }
}
exit(failures == 0 ? 0 : 1)
