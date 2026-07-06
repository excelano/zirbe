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
    /// A saved draft loaded for editing, presented as the prefilled composer.
    /// Held as an Identifiable request so `.sheet(item:)` drives it.
    @State private var draftEditRequest: DraftEditRequest?
    /// True while a tapped draft's contents are being fetched, before its
    /// composer appears.
    @State private var openingDraft = false
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
                row(for: summary)
                    .modifier(RowActions(
                        model: model,
                        summary: summary,
                        enabled: !isSearching,
                        onMove: { moveRequest = MoveRequest(threadIDs: [$0]) }
                    ))
                    .listRowBackground(Color.zirbeCanvas)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.zirbeCanvas)
        .environment(\.editMode, $editMode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .searchable(text: $searchText, prompt: "Search chats")
        .sheet(isPresented: $isComposing) {
            ComposeView(model: model)
        }
        .sheet(item: $draftEditRequest) { request in
            ComposeView(model: model, editing: request.edit)
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
        .overlay {
            if openingDraft {
                ProgressView("Opening Draft…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
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
            // Reconcile the app icon badge with what's actually unread on launch,
            // clearing a stale count a background poll may have left.
            await NewMailNotifier.shared.updateBadge(unreadCount: model.unreadCounts["INBOX"] ?? 0)
        }
        .task(id: searchText) { await runSearch() }
        // Keep the badge tracking the inbox unread count as mail is read, synced,
        // or arrives, so it never freezes at a poll's number.
        .onChange(of: model.unreadCounts["INBOX"] ?? 0) { _, unread in
            Task { await NewMailNotifier.shared.updateBadge(unreadCount: unread) }
        }
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

    /// Whether the Drafts folder is on screen, where a tapped row resumes editing
    /// in the composer rather than opening the read-only conversation view.
    private var isViewingDrafts: Bool {
        model.currentMailbox.role == .drafts
    }

    /// One conversation row. In the Drafts folder (and not mid-selection) a tap
    /// reopens the composer prefilled; everywhere else it pushes the read-only
    /// conversation. Selection mode keeps the standard navigable row so the List's
    /// selection circles and bulk actions work in Drafts too.
    @ViewBuilder
    private func row(for summary: ThreadSummary) -> some View {
        if isViewingDrafts && !isSelecting {
            Button {
                openDraft(summary)
            } label: {
                ThreadRow(summary: summary, selfAddress: model.account.emailAddress)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                ConversationView(model: model, summary: summary)
            } label: {
                ThreadRow(summary: summary, selfAddress: model.account.emailAddress)
            }
        }
    }

    /// Fetch a tapped draft's contents (recipients, subject, body, attachment
    /// bytes) over the server session, then present it in the composer. A draft
    /// that no longer resolves (already sent or expunged) is left alone.
    private func openDraft(_ summary: ThreadSummary) {
        openingDraft = true
        Task {
            let edit = await model.loadDraft(threadID: summary.id)
            openingDraft = false
            if let edit { draftEditRequest = DraftEditRequest(edit: edit) }
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
        if isSelecting {
            ToolbarItem(placement: .principal) {
                Text(navigationTitle)
                    .font(.headline)
            }
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
            // Top left is the folder selector, the way Mail's leading corner opens
            // the mailbox list.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingMailboxes = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentMailbox.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Switch folder, currently \(model.currentMailbox.displayName)")
            }
            // Top right pairs Select with Settings, the gear sitting at the far
            // edge: Mail's one deliberately overloaded corner, kept to two.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editMode = .active
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(model.summaries.isEmpty)
                .accessibilityLabel("Select Conversations")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            // Bottom bar in the Mail idiom: filter at the leading edge, the system
            // search field centered, compose at the trailing edge.
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showUnreadOnly.toggle()
                } label: {
                    Image(systemName: showUnreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(showUnreadOnly ? "Show all conversations" : "Show unread only")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    isComposing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Conversation")
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

/// A saved draft loaded for editing, wrapped so `.sheet(item:)` can present the
/// prefilled composer.
private struct DraftEditRequest: Identifiable {
    let id = UUID()
    let edit: DraftEdit
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
                        Task { await model.setPinned(threadID: summary.id, pinned: !summary.isPinned) }
                    } label: {
                        Label(
                            summary.isPinned ? "Unpin" : "Pin",
                            systemImage: summary.isPinned ? "pin.slash" : "pin"
                        )
                    }
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
                        Task { await model.setPinned(threadID: summary.id, pinned: !summary.isPinned) }
                    } label: {
                        Label(
                            summary.isPinned ? "Unpin" : "Pin",
                            systemImage: summary.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .tint(.yellow)
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
    /// The account's own address, so an unnamed chat is titled by the other
    /// people rather than by the viewer.
    let selfAddress: String
    /// How many preview lines to show under the subject (0 hides the preview).
    @AppStorage(SettingsKeys.previewLineCount) private var previewLineCount = 2

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // A far-left gutter for the unread dot; clear when read so avatars
            // still line up down the list.
            Circle()
                .fill(summary.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
            ThreadAvatar(
                others: otherParticipants,
                fallback: summary.participants.first ?? Participant(address: selfAddress)
            )
            VStack(alignment: .leading, spacing: 3) {
                // The subject owns the first line; a pin and flag trail it so
                // subjects still share a left edge whatever their markers.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(summary.isUnread ? .bold : .regular)
                        .lineLimit(1)
                    if summary.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    if summary.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Flagged")
                    }
                    Spacer(minLength: 8)
                }
                // Beneath the subject: a named chat's participants on the left, the
                // timestamp on the right; an unnamed chat's title already names the
                // people, so the timestamp stands alone.
                if isNamed || summary.lastActivity != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if isNamed {
                            Text(participantText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let date = summary.lastActivity {
                            Text(date, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if previewLineCount > 0, let preview = summary.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(previewLineCount)
                }
            }
        }
        .padding(.vertical, 5)
    }

    /// Everyone in the thread except the account holder, in order — the faces the
    /// row shows (one, or two stacked for a group).
    private var otherParticipants: [Participant] {
        summary.participants.filter { $0.address.lowercased() != selfAddress.lowercased() }
    }

    /// Whether the user titled this chat (vs the default sent for an untitled one),
    /// which decides whether the participants need their own line.
    private var isNamed: Bool {
        let trimmed = summary.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != ConversationDefaults.unnamedSubject
    }

    private var title: String {
        ConversationDefaults.displayTitle(
            subject: summary.subject,
            participants: summary.participants,
            selfAddress: selfAddress
        )
    }

    private var participantText: String {
        let names = summary.participants.prefix(3).map(\.label)
        let base = names.isEmpty ? "—" : names.joined(separator: ", ")
        return summary.messageCount > 1 ? "\(base) · \(summary.messageCount)" : base
    }
}

/// The avatar (or pair) leading an inbox row: one face for a one-to-one chat, two
/// overlapping faces for a group, the way Messages and Mail show a group thread. A
/// thin canvas-colored ring sets the front face off from the one behind it.
private struct ThreadAvatar: View {
    /// The thread's participants minus the account holder, in order.
    let others: [Participant]
    /// Shown when there's no one else (a note to self): the account's own face.
    let fallback: Participant
    var size: CGFloat = 44

    var body: some View {
        if others.count >= 2 {
            let face = size * 0.72
            let shift = size * 0.14
            ZStack {
                SenderAvatar(participant: others[1], size: face)
                    .offset(x: shift, y: -shift)
                SenderAvatar(participant: others[0], size: face)
                    .overlay(Circle().stroke(Color.zirbeCanvas, lineWidth: 2))
                    .offset(x: -shift, y: shift)
            }
            .frame(width: size, height: size)
        } else {
            SenderAvatar(participant: others.first ?? fallback, size: size)
        }
    }
}
