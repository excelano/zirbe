// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The conversation list: one row per thread, most recent activity first, in the
// Messages inbox idiom. Each row is titled by its subject, with the
// participants beneath and an unread dot when any message is unseen.

import SwiftUI
import ZirbeCore

struct InboxView: View {
    let model: InboxModel
    /// Routes a full sign-out up to the session (forget credential + wipe cache).
    let onSignOut: () -> Void
    /// Drives live refresh: the inbox watches the server (IMAP IDLE) only while
    /// the app is in the foreground, and pauses when it backgrounds.
    @Environment(\.scenePhase) private var scenePhase
    @State private var isComposing = false
    @State private var showingSettings = false
    /// Presents the mailbox switcher (browse mode) from the title.
    @State private var showingMailboxes = false
    /// When set, presents the mailbox switcher in move mode for these
    /// conversations. Held as an Identifiable request so `.sheet(item:)` drives it
    /// and the ids are captured before any selection clears.
    @State private var moveRequest: MoveRequest?
    /// When set, the list shows only conversations with unread mail.
    @State private var showUnreadOnly = false
    /// The conversations picked in selection mode, by thread id.
    @State private var selection = Set<String>()
    /// Drives selection mode: `.active` shows the per-row circles and the bulk
    /// action bar, and turns row taps into selection rather than navigation.
    @State private var editMode: EditMode = .inactive
    /// The live search query; empty means the normal inbox is shown.
    @State private var searchText = ""
    /// Results for the current query, most recent first. Held separately from the
    /// inbox summaries so search never disturbs the cached list.
    @State private var searchResults: [ThreadSummary] = []

    private var isSelecting: Bool { editMode == .active }

    /// Whether every selected conversation is already flagged, so the bulk Flag
    /// button reads as Unflag and clears them rather than re-flagging.
    private var allSelectedFlagged: Bool {
        !selection.isEmpty && selection.allSatisfy { id in
            model.summaries.first { $0.id == id }?.isFlagged ?? false
        }
    }

    /// Whether a search is active (the query has non-whitespace content).
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rows actually shown: search results while searching, otherwise the
    /// inbox narrowed to unread when the filter is on.
    private var visibleSummaries: [ThreadSummary] {
        if isSearching { return searchResults }
        return showUnreadOnly ? model.summaries.filter(\.isUnread) : model.summaries
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleSummaries) { summary in
                NavigationLink {
                    ConversationView(model: model, summary: summary)
                } label: {
                    ThreadRow(summary: summary)
                }
                .modifier(RowActions(
                    model: model,
                    summary: summary,
                    enabled: !isSearching,
                    onMove: { moveRequest = MoveRequest(threadIDs: [$0]) }
                ))
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search mail")
        .sheet(isPresented: $isComposing) {
            ComposeView(model: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(account: model.account, onSignOut: onSignOut)
        }
        .sheet(isPresented: $showingMailboxes) {
            MailboxesView(model: model, mode: .browse)
        }
        .sheet(item: $moveRequest) { request in
            MailboxesView(model: model, mode: .move(threadIDs: request.threadIDs))
        }
        .overlay { emptyState }
        .refreshable { await model.refresh() }
        .task {
            await model.loadCached()
            if model.summaries.isEmpty {
                await model.refresh()
            }
            // The first foreground doesn't fire `onChange(of: scenePhase)`, so
            // start the live watch here; later background/foreground transitions
            // are handled below.
            model.startLiveRefresh()
        }
        .task(id: searchText) { await runSearch() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Returning to the foreground: catch up on anything missed while
                // the watch was paused, then resume it.
                Task {
                    await model.refresh()
                    model.startLiveRefresh()
                }
            case .background:
                // No foreground connection in the background, so end the live
                // watch and hand off to the background poll: queue a refresh
                // request iOS can run while we're suspended. `.inactive` is a
                // brief transitional state and is left alone to avoid needless
                // connection churn.
                Task { await model.stopLiveRefresh() }
                BackgroundRefreshScheduler.schedule()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// Run the current query against the local store, with a short debounce so a
    /// burst of keystrokes only issues the final search. `.task(id:)` cancels and
    /// restarts this when the text changes, so a cancelled run never overwrites
    /// newer results, and the previous results stay on screen until the new ones
    /// land (no flash to empty mid-typing).
    private func runSearch() async {
        guard isSearching else { searchResults = []; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        searchResults = await model.search(searchText)
    }

    /// The centered title while picking conversations; the title bar otherwise
    /// shows the mailbox switcher, so this is read only in selection mode.
    private var navigationTitle: String {
        selection.isEmpty ? "Select" : "\(selection.count) Selected"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if isSelecting {
                Text(navigationTitle)
                    .font(.headline)
            } else {
                Button {
                    showingMailboxes = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentMailbox.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Switch mailbox, currently \(model.currentMailbox.displayName)")
            }
        }
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelecting() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await bulkRead(true) }
                } label: {
                    Label("Read", systemImage: "envelope.open")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button {
                    Task { await bulkRead(false) }
                } label: {
                    Label("Unread", systemImage: "envelope.badge")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button {
                    Task { await bulkFlag(!allSelectedFlagged) }
                } label: {
                    Label(
                        allSelectedFlagged ? "Unflag" : "Flag",
                        systemImage: allSelectedFlagged ? "flag.slash" : "flag"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    Task { await bulkTrash() }
                } label: {
                    Label("Trash", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selection.isEmpty)
                Spacer()
                Menu {
                    Button {
                        Task { await bulkArchive() }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button {
                        bulkMove()
                    } label: {
                        Label("Move to…", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        Task { await bulkJunk() }
                    } label: {
                        Label("Move to Junk", systemImage: "xmark.bin")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showUnreadOnly.toggle()
                } label: {
                    Image(systemName: showUnreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(showUnreadOnly ? "Show all conversations" : "Show unread only")
                Button {
                    isComposing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Conversation")
                Button("Select") { editMode = .active }
                    .disabled(model.summaries.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        } else if model.summaries.isEmpty {
            if model.isSyncing {
                ProgressView("Syncing…")
            } else {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "tray",
                    description: Text(model.errorMessage ?? "Pull down to refresh.")
                )
            }
        } else if showUnreadOnly && visibleSummaries.isEmpty {
            ContentUnavailableView(
                "No unread conversations",
                systemImage: "envelope.open",
                description: Text("You’re all caught up.")
            )
        }
    }

    /// Leave selection mode and clear the picked rows.
    private func endSelecting() {
        editMode = .inactive
        selection.removeAll()
    }

    /// Mark the selected conversations read or unread, then leave selection mode.
    /// The ids are captured before exiting so clearing the selection can't race
    /// the server work.
    private func bulkRead(_ read: Bool) async {
        let ids = Array(selection)
        endSelecting()
        await model.markRead(threadIDs: ids, read: read)
    }

    /// Flag or unflag the selected conversations, then leave selection mode. The
    /// ids are captured before exiting so clearing the selection can't race the
    /// server work.
    private func bulkFlag(_ flagged: Bool) async {
        let ids = Array(selection)
        endSelecting()
        await model.markFlagged(threadIDs: ids, flagged: flagged)
    }

    /// Trash the selected conversations, then leave selection mode.
    private func bulkTrash() async {
        let ids = Array(selection)
        endSelecting()
        await model.trash(threadIDs: ids)
    }

    /// Archive the selected conversations, preserving their read state, then
    /// leave selection mode.
    private func bulkArchive() async {
        let ids = Array(selection)
        endSelecting()
        await model.archive(threadIDs: ids)
    }

    /// Mark the selected conversations as junk, then leave selection mode.
    private func bulkJunk() async {
        let ids = Array(selection)
        endSelecting()
        await model.junk(threadIDs: ids)
    }

    /// Present the move-destination picker for the selected conversations. The ids
    /// are captured into the request before selection mode ends, so the move runs
    /// against the right conversations once a folder is picked.
    private func bulkMove() {
        moveRequest = MoveRequest(threadIDs: Array(selection))
        endSelecting()
    }
}

/// A pending move: the conversations to relocate, wrapped so `.sheet(item:)` can
/// drive the destination picker and the ids survive the selection clearing.
private struct MoveRequest: Identifiable {
    let id = UUID()
    let threadIDs: [String]
}

/// The swipe actions on an inbox row: trash trailing; read/unread toggle (full
/// swipe) and flag/unflag together on the leading edge. Disabled while
/// searching, where results are navigate-only so a mutation can't leave the
/// result list stale.
private struct RowActions: ViewModifier {
    let model: InboxModel
    let summary: ThreadSummary
    let enabled: Bool
    /// Opens the move-destination picker for this conversation.
    let onMove: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await model.trash(summary) }
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    Button {
                        Task { await model.archive(summary) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button {
                        Task { await model.archive(summary) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button {
                        onMove(summary.id)
                    } label: {
                        Label("Move to…", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        Task { await model.junk(summary) }
                    } label: {
                        Label("Move to Junk", systemImage: "xmark.bin")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await model.markRead(threadID: summary.id, read: summary.isUnread) }
                    } label: {
                        Label(
                            summary.isUnread ? "Read" : "Unread",
                            systemImage: summary.isUnread ? "envelope.open" : "envelope.badge"
                        )
                    }
                    .tint(.blue)
                    Button {
                        Task { await model.markFlagged(threadID: summary.id, flagged: !summary.isFlagged) }
                    } label: {
                        Label(
                            summary.isFlagged ? "Unflag" : "Flag",
                            systemImage: summary.isFlagged ? "flag.slash" : "flag"
                        )
                    }
                    .tint(.orange)
                }
        } else {
            content
        }
    }
}

/// One inbox row: unread dot, subject, relative time, the participants, and a
/// one-line preview of the newest message when its body has been fetched.
private struct ThreadRow: View {
    let summary: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(summary.isUnread ? Color.accentColor : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(summary.isUnread ? .bold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if summary.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Flagged")
                    }
                    if let date = summary.lastActivity {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(participantText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview = summary.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        summary.subject.isEmpty ? "(no subject)" : summary.subject
    }

    private var participantText: String {
        let names = summary.participants.prefix(3).map(\.label)
        let base = names.isEmpty ? "—" : names.joined(separator: ", ")
        return summary.messageCount > 1 ? "\(base) · \(summary.messageCount)" : base
    }
}
