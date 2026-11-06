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
    var session: AppSession?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let accounts = browsedAccounts {
                    allInboxesRow
                    ForEach(accounts, id: \.account.id) { account in
                        Section {
                            folderRows(in: account)
                        } header: {
                            accountHeader(account)
                        }
                    }
                } else {
                    folderRows(in: model)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.zirbeCanvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay { if isEmpty { emptyState } }
        }
        .task {
            let accounts = browsedAccounts ?? [model]
            for account in accounts { await account.loadMailboxes() }
            for account in accounts { await account.discoverFolders() }
        }
    }

    private var browsedAccounts: [InboxModel]? {
        guard case .browse = mode, let session, session.models.count > 1 else { return nil }
        return session.models
    }

    private var isViewingAllInboxes: Bool { session?.scope?.isAllInboxes == true }

    private var allInboxesRow: some View {
        Button(action: pickAllInboxes) {
            HStack(spacing: 12) {
                Image(systemName: "tray.2")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text("All Inboxes")
                    .foregroundStyle(.primary)
                Spacer()
                if let count = session?.inboxUnreadCount, count > 0 {
                    Text("\(count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if isViewingAllInboxes {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.zirbeCanvas)
    }

    private func pickAllInboxes() {
        Task {
            await session?.selectAllInboxes()
            await session?.scope?.refresh()
        }
        dismiss()
    }

    private var isEmpty: Bool {
        (browsedAccounts ?? [model]).allSatisfy { sortedMailboxes(in: $0).isEmpty }
    }

    private func folderRows(in account: InboxModel) -> some View {
        ForEach(sortedMailboxes(in: account)) { mailbox in
            Button { pick(mailbox, in: account) } label: { row(mailbox, in: account) }
                .buttonStyle(.plain)
                .listRowBackground(Color.zirbeCanvas)
        }
    }

    private func accountHeader(_ account: InboxModel) -> some View {
        HStack {
            AccountLabel(account: account.account)
            Spacer()
            if !account.isConnected {
                Text("Password needed")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }

    private var title: String {
        switch mode {
        case .browse: return "Folders"
        case .move: return "Move to"
        }
    }

    /// The destinations a move offers, or every folder in browse mode. Moving a
    /// conversation into the folder it already sits in is a no-op, so the current
    /// folder is dropped from the move list.
    private func sortedMailboxes(in account: InboxModel) -> [Mailbox] {
        let folders: [Mailbox]
        switch mode {
        case .browse:
            folders = account.mailboxes
        case .move:
            folders = account.mailboxes.filter { $0.name != account.currentMailbox.name }
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
    private func row(_ mailbox: Mailbox, in account: InboxModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: mailbox))
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(mailbox.displayName)
                .foregroundStyle(.primary)
            Spacer()
            if let count = account.unreadCounts[mailbox.name], count > 0 {
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case .browse = mode, !isViewingAllInboxes, account === model, mailbox.name == account.currentMailbox.name {
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
            "No folders",
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

    private func pick(_ mailbox: Mailbox, in account: InboxModel) {
        switch mode {
        case .browse:
            let switching = isViewingAllInboxes || account !== model
            Task {
                if switching { await session?.select(account.account.id) }
                await account.selectMailbox(mailbox)
                if switching, account.isViewingInbox { await account.refresh() }
            }
        case .move(let threadIDs):
            Task { await model.move(threadIDs: threadIDs, to: mailbox.name) }
            onMoved?()
        }
        dismiss()
    }
}
