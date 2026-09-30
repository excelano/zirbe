// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// An attendee's answer to a meeting, shown in the conversation as a line
// ("Pat accepted") rather than a bubble, the way join-and-leave lines already
// read. The answer message itself stays out of the chat; this is what the view
// renders in its place, under the visible message it followed.

import Foundation

public struct InviteResponse: Sendable, Hashable, Identifiable {
    /// The id of the answer message.
    public var messageID: String
    public var attendee: Invite.Attendee
    public var date: Date?

    public init(messageID: String, attendee: Invite.Attendee, date: Date?) {
        self.messageID = messageID
        self.attendee = attendee
        self.date = date
    }

    public var id: String { messageID }

    /// The line's text.
    public var text: String {
        switch attendee.status {
        case .accepted: "\(attendee.label) accepted"
        case .tentative: "\(attendee.label) might attend"
        case .declined: "\(attendee.label) declined"
        case .needsAction, .other: "\(attendee.label) replied"
        }
    }

    /// The answers in `messages`, oldest first.
    public static func responses(in messages: [Message]) -> [InviteResponse] {
        messages.compactMap { message in
            guard let attendee = message.invite?.replyingAttendee else { return nil }
            return InviteResponse(messageID: message.id, attendee: attendee, date: message.date)
        }
        .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// The answers grouped under the visible message each one follows: the
    /// latest chat message dated at or before the answer, else the first. The
    /// view renders each group below that bubble.
    public static func byPrecedingMessage(_ responses: [InviteResponse], visible: [Message]) -> [String: [InviteResponse]] {
        guard let first = visible.first else { return [:] }
        var grouped: [String: [InviteResponse]] = [:]
        for response in responses {
            let anchor = visible.last { ($0.date ?? .distantPast) <= (response.date ?? .distantFuture) } ?? first
            grouped[anchor.id, default: []].append(response)
        }
        return grouped
    }
}
