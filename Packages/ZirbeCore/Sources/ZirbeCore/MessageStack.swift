// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// How a conversation's messages sit in the stack: which of them start and end a
// run from one sender, and where the day separators fall. Pure functions of the
// message list, so the view computes them once per thread rather than per frame.

import Foundation

/// One message with everything about its place in the stack already worked out.
///
/// Whether a bubble carries the tail, shows its sender, or has a day separator
/// above it depends only on its neighbours, so it never changes while a thread is
/// on screen. Deriving it per row per body evaluation meant recomputing the whole
/// stack on every frame of a timestamp-peek drag, which is exactly when the app
/// can least afford it.
public struct StackedMessage: Identifiable, Sendable {
    public let message: Message
    /// Sent by the account holder, so it sits on the trailing side.
    public let isOwn: Bool
    /// Ends a run from one sender, so it carries the tail and the timestamp.
    public let hasTail: Bool
    /// Begins a run from someone else, so their name shows above it.
    public let showSender: Bool
    /// Begins a run that isn't the first, so it takes a little space above it.
    public let needsRunSpacing: Bool
    /// The date to caption a separator above this message, when it opens a new
    /// calendar day.
    public let daySeparator: Date?

    public var id: String { message.id }
}

public enum MessageStack {
    /// Lay out a conversation's messages, oldest first, as the view will show them.
    ///
    /// A run is a stretch of consecutive messages from one address. The first
    /// dated message always opens a day; a message with no date never carries a
    /// separator, and doesn't close the day the message before it opened.
    public static func rows(
        _ messages: [Message],
        ownedBy selfAddress: String,
        calendar: Calendar = .current
    ) -> [StackedMessage] {
        messages.enumerated().map { index, message in
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index < messages.count - 1 ? messages[index + 1] : nil
            let startsRun = previous.map { $0.from?.address != message.from?.address } ?? true
            let isOwn = message.from?.address == selfAddress

            return StackedMessage(
                message: message,
                isOwn: isOwn,
                hasTail: next.map { $0.from?.address != message.from?.address } ?? true,
                showSender: !isOwn && startsRun,
                needsRunSpacing: startsRun && index > 0,
                daySeparator: separator(for: message, after: previous, calendar: calendar)
            )
        }
    }

    private static func separator(for message: Message, after previous: Message?, calendar: Calendar) -> Date? {
        guard let date = message.date else { return nil }
        guard let earlier = previous?.date else { return date }
        return calendar.isDate(date, inSameDayAs: earlier) ? nil : date
    }
}
