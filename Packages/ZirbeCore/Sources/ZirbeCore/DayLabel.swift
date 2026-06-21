// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The text on the centered divider the conversation drops between bubbles when
// the calendar day changes, the way Messages marks the passage of days. Pure
// and calendar-injectable so the label rules are unit-testable.

import Foundation

/// Formats the day-separator caption for a message's date relative to now:
/// "Today" and "Yesterday" for the recent two, the weekday name within the past
/// week, then a short date ("Jun 18", with the year once it differs).
public enum DayLabel {
    public static func text(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        // Measured against the supplied `now`, not the device clock, so the rule
        // is deterministic and testable. `Calendar.isDateInToday` would ignore
        // `now` entirely, so the day delta is computed by hand.
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let daysApart = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

        switch daysApart {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: break
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone

        if (2...6).contains(daysApart) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE") // weekday name
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        }
        return formatter.string(from: date)
    }
}
