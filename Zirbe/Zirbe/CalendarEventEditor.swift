// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// "Add to Calendar": the system event editor, prefilled from an invitation, so
// the user saves the meeting into a calendar of their choosing in Apple's own
// UI. Nothing leaves the device and no calendar is read: the editor needs only
// permission to add the one event, which iOS asks for itself when the sheet
// saves (the write-only calendar access of iOS 17).

import EventKit
import EventKitUI
import SwiftUI
import ZirbeCore

/// The invitation to add, as a sheet item keyed by its meeting.
struct InviteToAdd: Identifiable {
    let invite: Invite
    var id: String { invite.uid }
}

struct CalendarEventEditor: UIViewControllerRepresentable {
    let invite: Invite
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = invite.summary?.isEmpty == false ? invite.summary : "Meeting"
        event.isAllDay = invite.isAllDay
        event.startDate = invite.start ?? .now
        event.endDate = invite.end ?? event.startDate.addingTimeInterval(3600)
        if invite.isAllDay, let end = invite.end, let inclusive = Calendar.current.date(byAdding: .day, value: -1, to: end), inclusive >= event.startDate {
            // The editor wants an all-day end on the last day, not the day after.
            event.endDate = inclusive
        }
        if let zoneID = invite.timeZoneID { event.timeZone = TimeZone(identifier: zoneID) }
        event.location = invite.location
        event.url = invite.joinURL
        var notes: [String] = []
        if let organizer = invite.organizer { notes.append("Organizer: \(organizer.label)") }
        if let recurrence = invite.recurrence { notes.append("Repeats: \(recurrence) (add each occurrence as needed)") }
        if let join = invite.joinURL { notes.append("Join: \(join.absoluteString)") }
        if let description = invite.description, !description.isEmpty { notes.append(description) }
        event.notes = notes.joined(separator: "\n\n")

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
        context.coordinator.onDone = { dismiss() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        var onDone: () -> Void = {}

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onDone()
        }
    }
}
