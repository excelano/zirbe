// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A meeting invitation as a card inside its bubble, in the three-row shape
// Blick's meeting card uses: a calendar icon with the time range, the title,
// then who it's with, plus a location line, a Join button when there is a
// link, and an Add to Calendar action. A badge says when the card is an update
// or a cancellation. The message's own text, if any, still shows under it.

import SwiftUI
import ZirbeCore

struct InviteCard: View {
    let invite: Invite
    let isOwn: Bool
    let onAddToCalendar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: invite.isCancelled ? "calendar.badge.minus" : "calendar")
                    .foregroundStyle(invite.isCancelled ? AnyShapeStyle(.red) : accent)
                Text(InviteCard.timeRange(for: invite))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(muted)
                    .strikethrough(invite.isCancelled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(invite.isCancelled ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.18)))
                        .foregroundStyle(invite.isCancelled ? AnyShapeStyle(.red) : accent)
                }
            }
            Text(invite.summary?.isEmpty == false ? invite.summary! : "Meeting")
                .font(.headline)
                .foregroundStyle(primary)
                .strikethrough(invite.isCancelled)
            if let organizer = invite.organizer {
                Text("with \(organizer.label)")
                    .font(.subheadline)
                    .foregroundStyle(muted)
            }
            if let recurrence = invite.recurrence {
                Label(recurrence, systemImage: "repeat")
                    .font(.caption)
                    .foregroundStyle(muted)
            }
            if let location = invite.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(muted)
                    .lineLimit(2)
            }
            if !invite.isCancelled {
                VStack(spacing: 8) {
                    if let url = invite.joinURL {
                        Link(destination: url) {
                            Label("Join", systemImage: "video.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                    }
                    Button(action: onAddToCalendar) {
                        Label("Add to Calendar", systemImage: "calendar.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(isOwn ? Color.white.opacity(0.22) : Color(.tertiarySystemFill)))
                            .foregroundStyle(primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOwn ? Color.white.opacity(0.14) : Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
    }

    private var badge: String? {
        if invite.isCancelled { return "Cancelled" }
        if invite.sequence > 0 { return "Updated" }
        return nil
    }

    private var accent: AnyShapeStyle { isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor) }
    private var muted: AnyShapeStyle { isOwn ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary) }
    private var primary: AnyShapeStyle { isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary) }

    /// The meeting's time range in the reader's own zone: "Tue, Sep 15 · 11:30 AM
    /// to 12:45 PM", "Tue, Sep 15 (all day)", or a two-day span. A meeting with
    /// no time reads as such rather than as a blank.
    static func timeRange(for invite: Invite, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let start = invite.start else { return "No time set" }
        let end = invite.end ?? start
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let day: Date.FormatStyle = sameYear
            ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
        if invite.isAllDay {
            // An all-day end is exclusive: the day after the last day.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
            if calendar.isDate(start, inSameDayAs: lastDay) || lastDay < start {
                return "\(start.formatted(day)) (all day)"
            }
            return "\(start.formatted(day)) to \(lastDay.formatted(day))"
        }
        let time: Date.FormatStyle = .dateTime.hour().minute()
        if calendar.isDate(start, inSameDayAs: end) {
            if start == end { return "\(start.formatted(day)) · \(start.formatted(time))" }
            return "\(start.formatted(day)) · \(start.formatted(time)) to \(end.formatted(time))"
        }
        return "\(start.formatted(day)) \(start.formatted(time)) to \(end.formatted(day)) \(end.formatted(time))"
    }
}

/// A line in the conversation for an attendee's answer ("Pat accepted"), the
/// way join-and-leave lines read, under the bubble it followed.
struct InviteResponseLine: View {
    let response: InviteResponse

    var body: some View {
        Text(response.text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}
