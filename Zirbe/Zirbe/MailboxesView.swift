// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The mailbox switcher, in two modes. Browse mode lists the account's folders
// with their unread counts and a check on the one showing, and tapping one swaps
// the conversation list to it. Move mode lists the same folders as destinations,
// and tapping one moves the chosen conversations there. Both read the folder list
// from the cache for an instant open, then refresh it from the server in the
// background.

import SwiftUI
import ZirbeCore

struct MailboxesView: View {
    let model: InboxModel

    /// Browse swaps the visible list; move sends the given conversations to the
    /// picked folder. The associated ids are captured by the caller before the
    /// sheet opens, so dismissing or re-selecting can't race the move.
    enum Mode {
        case browse
        case move(threadIDs: [String])
    }
    let mode: Mode
    /// Called after a move is started, so a caller (e.g. the open conversation)
    /// can pop itself once its thread has left the folder. Unused in browse mode
    /// and by the inbox, where the list just refreshes in place.
    var onMoved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedMailboxes) { mailbox in
                    Button { pick(mailbox) } label: { row(mailbox) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay { if sortedMailboxes.isEmpty { emptyState } }
        }
        .task {
            await model.loadMailboxes()
            await model.discoverFolders()
        }
    }

    private var title: String {
        switch mode {
        case .browse: return "Mailboxes"
        case .move: return "Move to"
        }
    }

    /// The destinations a move offers, or every folder in browse mode. Moving a
    /// conversation into the folder it already sits in is a no-op, so the current
    /// folder is dropped from the move list.
    private var sortedMailboxes: [Mailbox] {
        let folders: [Mailbox]
        switch mode {
        case .browse:
            folders = model.mailboxes
        case .move:
            folders = model.mailboxes.filter { $0.name != model.currentMailbox.name }
        }
        return folders.sorted { sortKey($0) < sortKey($1) }
    }

    /// Sort the well-known folders into the familiar mail order (Inbox, Drafts,
    /// Sent, Archive, Junk, Trash), then any custom folders alphabetically below.
    private func sortKey(_ mailbox: Mailbox) -> (Int, String) {
        let rank: [MailboxRole: Int] = [
            .inbox: 0, .drafts: 1, .sent: 2, .archive: 3, .junk: 4, .trash: 5,
        ]
        return (mailbox.role.flatMap { rank[$0] } ?? 6, mailbox.displayName.lowercased())
    }

    @ViewBuilder
    private func row(_ mailbox: Mailbox) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: mailbox))
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(mailbox.displayName)
                .foregroundStyle(.primary)
            Spacer()
            if let count = model.unreadCounts[mailbox.name], count > 0 {
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case .browse = mode, mailbox.name == model.currentMailbox.name {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No mailboxes",
            systemImage: "tray.2",
            description: Text("Pull the inbox to refresh, then try again.")
        )
    }

    /// A role-appropriate icon, falling back to a plain folder for custom folders.
    private func symbol(for mailbox: Mailbox) -> String {
        switch mailbox.role {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .none: return "folder"
        }
    }

    private func pick(_ mailbox: Mailbox) {
        switch mode {
        case .browse:
            Task { await model.selectMailbox(mailbox) }
        case .move(let threadIDs):
            Task { await model.move(threadIDs: threadIDs, to: mailbox.name) }
            onMoved?()
        }
        dismiss()
    }
}
