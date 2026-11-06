// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The conversation list: one row per thread, most recent activity first, in the
// Messages inbox idiom. Each row is titled by its subject, with the
// participants beneath and an unread dot when any message is unseen.

import SwiftUI
import ZirbeCore

struct InboxView: View {
    let scope: InboxScope
    let session: AppSession
    let onRemoveAccount: (String) -> Void
    /// The conversation open beside the list in the split view. Nil on compact
    /// width, where a row pushes its conversation instead.
    var openedThread: Binding<ThreadSummary?>? = nil
    /// Drives live refresh: the inbox watches the server (IMAP IDLE) only while
    /// the app is in the foreground, and pauses when it backgrounds.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    /// The conversations picked in selection mode, by account and thread.
    @State private var selection = Set<ThreadKey>()
    /// Drives selection mode: `.active` shows the per-row circles and the bulk
    /// action bar, and turns row taps into selection rather than navigation.
    @State private var editMode: EditMode = .inactive
    /// The live search query; empty means the normal inbox is shown.
    @State private var searchText = ""
    /// Results for the current query, most recent first. Held separately from the
    /// inbox summaries so search never disturbs the cached list.
    @State private var searchResults: [ThreadSummary] = []
    @State private var serverSearchQuery: String?
    @State private var isSearchingServer = false
    @State private var serverSearchFailed = false

    private var isSelecting: Bool { editMode == .active }

    /// Whether every selected conversation is already flagged, so the bulk Flag
    /// button reads as Unflag and clears them rather than re-flagging.
    ///
    /// Gathering the flagged ids once and testing the selection against them costs
    /// one pass over the list. Asking the list for each selected row in turn cost a
    /// scan per row, and the toolbar this feeds re-evaluates on every tap of a
    /// selection circle — so selecting the fiftieth of three hundred conversations
    /// was walking the list for the fiftieth time.
    private var allSelectedFlagged: Bool {
        guard !selection.isEmpty else { return false }
        let flagged = Set(scope.summaries.lazy.filter(\.isFlagged).map(\.key))
        return selection.isSubset(of: flagged)
    }

    private var accountModel: InboxModel? {
        if case .account(let model) = scope { model } else { nil }
    }

    private var selectedSummaries: [ThreadSummary] {
        visibleSummaries.filter { selection.contains($0.key) }
    }

    /// Whether a search is active (the query has non-whitespace content).
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rows actually shown: search results while searching, otherwise the
    /// inbox narrowed to unread when the filter is on.
    private var visibleSummaries: [ThreadSummary] {
        if isSearching { return searchResults }
        return showUnreadOnly ? scope.summaries.filter(\.isUnread) : scope.summaries
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleSummaries, id: \.key) { summary in
                row(for: summary)
                    .modifier(RowActions(
                        model: scope.model(for: summary),
                        summary: summary,
                        enabled: !isSearching,
                        onMove: { moveRequest = MoveRequest(model: $0, summaries: [$1]) },
                        onRemove: { close([$0]) }
                    ))
                    .listRowBackground(isOpened(summary) ? Color.accentColor.opacity(0.15) : Color.zirbeCanvas)
            }
            if offersServerSearch {
                serverSearchRow
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.zirbeCanvas)
        .environment(\.editMode, $editMode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .searchable(text: $searchText, prompt: "Search chats")
        #if DEBUG
        // Demo/screenshot capture: pre-fill the search field so the results
        // screen can be grabbed without typing.
        .task {
            if let query = DemoMode.searchQuery, searchText.isEmpty { searchText = query }
        }
        #endif
        .sheet(isPresented: $isComposing) {
            ComposeView(model: accountModel ?? session.model ?? scope.models[0], accounts: session.models) { account in
                session.noteSent(from: account.id)
            }
        }
        .sheet(item: $draftEditRequest) { request in
            ComposeView(model: request.model, editing: request.edit)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(session: session, onRemoveAccount: onRemoveAccount)
        }
        .sheet(isPresented: $showingMailboxes) {
            MailboxesView(model: accountModel ?? session.model ?? scope.models[0], mode: .browse, session: session)
        }
        .sheet(item: $moveRequest) { request in
            MailboxesView(
                model: request.model,
                mode: .move(threadIDs: request.summaries.map(\.id)),
                onMoved: { close(request.summaries) }
            )
        }
        .overlay { emptyState }
        .overlay {
            if openingDraft {
                ProgressView("Opening Draft…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .refreshable { await scope.refresh() }
        .task {
            await scope.loadCached()
            if !scope.hasSynced {
                await scope.refresh()
            }
            // The first foreground doesn't fire `onChange(of: scenePhase)`, so
            // start the live watch here; later background/foreground transitions
            // are handled below.
            scope.startLiveRefresh()
        }
        .task(id: searchText) { await runSearch() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Returning to the foreground: catch up on anything missed while
                // the watch was paused, then resume it.
                Task {
                    await scope.refresh()
                    scope.startLiveRefresh()
                }
            case .background:
                // No foreground connection in the background, so end the live
                // watch and hand off to the background poll: queue a refresh
                // request iOS can run while we're suspended. `.inactive` is a
                // brief transitional state and is left alone to avoid needless
                // connection churn.
                Task { await scope.stopLiveRefresh() }
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
        accountModel?.currentMailbox.role == .drafts
    }

    /// One conversation row. In the Drafts folder (and not mid-selection) a tap
    /// reopens the composer prefilled; everywhere else it opens the read-only
    /// conversation, pushed on compact width and beside the list in the split view.
    /// Selection mode keeps a row without a button so the List's selection circles
    /// and bulk actions work in Drafts too.
    @ViewBuilder
    private func row(for summary: ThreadSummary) -> some View {
        let account = scope.model(for: summary)?.account
        let label = ThreadRow(
            summary: summary,
            selfAddress: account?.emailAddress ?? "",
            account: scope.isAllInboxes ? account : nil
        )
        if isViewingDrafts && !isSelecting {
            Button { openDraft(summary) } label: { label }
                .buttonStyle(.plain)
        } else if let openedThread {
            if isSelecting {
                label
            } else {
                Button { openedThread.wrappedValue = summary } label: { label }
                    .buttonStyle(.plain)
            }
        } else {
            NavigationLink(value: summary) { label }
        }
    }

    /// Whether this row's conversation is the one open beside the list.
    private func isOpened(_ summary: ThreadSummary) -> Bool {
        openedThread?.wrappedValue?.key == summary.key
    }

    /// Empty the split view's detail column when its conversation is among those
    /// leaving the list.
    private func close(_ summaries: [ThreadSummary]) {
        guard let openedThread, let key = openedThread.wrappedValue?.key,
              summaries.contains(where: { $0.key == key }) else { return }
        openedThread.wrappedValue = nil
    }

    /// Fetch a tapped draft's contents (recipients, subject, body, attachment
    /// bytes) over the server session, then present it in the composer. A draft
    /// that no longer resolves (already sent or expunged) is left alone.
    private func openDraft(_ summary: ThreadSummary) {
        guard let model = scope.model(for: summary) else { return }
        openingDraft = true
        Task {
            let edit = await model.loadDraft(threadID: summary.id)
            openingDraft = false
            if let edit { draftEditRequest = DraftEditRequest(model: model, edit: edit) }
        }
    }

    /// Run the current query against the local store, with a short debounce so a
    /// burst of keystrokes only issues the final search. `.task(id:)` cancels and
    /// restarts this when the text changes, so a cancelled run never overwrites
    /// newer results, and the previous results stay on screen until the new ones
    /// land (no flash to empty mid-typing).
    private func runSearch() async {
        serverSearchFailed = false
        guard isSearching else { searchResults = []; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        searchResults = await scope.search(searchText)
    }

    private var offersServerSearch: Bool {
        isSearching && !scope.models.contains(where: \.isDemo) && serverSearchQuery != searchText
    }

    private var serverSearchRow: some View {
        Button(action: searchServer) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(serverSearchTitle, systemImage: "magnifyingglass")
                    if serverSearchFailed {
                        Text(scope.errorMessage ?? "The server didn’t answer.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if isSearchingServer { ProgressView() }
            }
        }
        .disabled(isSearchingServer)
        .listRowBackground(Color.zirbeCanvas)
    }

    private var serverSearchTitle: String {
        guard let accountModel else { return "Search Inboxes on Server" }
        return "Search \(accountModel.currentMailbox.displayName) on Server"
    }

    private func searchServer() {
        let query = searchText
        isSearchingServer = true
        serverSearchFailed = false
        Task {
            let hits = await scope.searchServer(query)
            isSearchingServer = false
            guard searchText == query else { return }
            guard let hits else { serverSearchFailed = true; return }
            serverSearchQuery = query
            let shown = Set(searchResults.map(\.key))
            searchResults = (searchResults + hits.filter { !shown.contains($0.key) })
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        }
    }

    /// The centered title while picking conversations; the title bar otherwise
    /// shows the mailbox switcher, so this is read only in selection mode.
    private var hasSeveralAccounts: Bool { session.models.count > 1 }

    private var folderTitle: String {
        guard let accountModel else { return "All Inboxes" }
        return hasSeveralAccounts && accountModel.isViewingInbox ? accountModel.account.title : accountModel.currentMailbox.displayName
    }

    private var folderAccessibilityLabel: String {
        guard let accountModel else { return "Switch folder, currently All Inboxes" }
        return hasSeveralAccounts
            ? "Switch folder, currently \(accountModel.currentMailbox.displayName) in \(accountModel.account.title)"
            : "Switch folder, currently \(accountModel.currentMailbox.displayName)"
    }

    private var selectionSpansAccounts: Bool {
        Set(selectedSummaries.map(\.accountID)).count > 1
    }

    /// The toolbar lays items out at their ideal width and moves whatever doesn't
    /// fit into an overflow menu, so a long account title would push Select and
    /// Settings out of sight. The split view's sidebar column also carries the
    /// sidebar toggle, leaving the title less room than the iPhone's full width.
    private var folderSelectorMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 130 : 200
    }

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
                    .disabled(selectionSpansAccounts)
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
                        if hasSeveralAccounts, let accountModel {
                            AccountDot(color: accountModel.account.color)
                        }
                        Text(folderTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.75)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .frame(maxWidth: folderSelectorMaxWidth, alignment: .leading)
                }
                .accessibilityLabel(folderAccessibilityLabel)
            }
            // Top right pairs Select with Settings, the gear sitting at the far
            // edge: Mail's one deliberately overloaded corner, kept to two.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editMode = .active
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(scope.summaries.isEmpty)
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
            if searchResults.isEmpty && !offersServerSearch {
                ContentUnavailableView.search(text: searchText)
            }
        } else if scope.summaries.isEmpty {
            if scope.isSyncing {
                ProgressView("Syncing…")
            } else {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "tray",
                    description: Text(scope.errorMessage ?? "Pull down to refresh.")
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

    private func bulkRead(_ read: Bool) async {
        let picked = selectedSummaries
        endSelecting()
        await scope.perform(on: picked) { model, ids in await model.markRead(threadIDs: ids, read: read) }
    }

    private func bulkFlag(_ flagged: Bool) async {
        let picked = selectedSummaries
        endSelecting()
        await scope.perform(on: picked) { model, ids in await model.markFlagged(threadIDs: ids, flagged: flagged) }
    }

    private func bulkTrash() async {
        let picked = selectedSummaries
        endSelecting()
        close(picked)
        await scope.perform(on: picked) { model, ids in await model.trash(threadIDs: ids) }
    }

    private func bulkArchive() async {
        let picked = selectedSummaries
        endSelecting()
        close(picked)
        await scope.perform(on: picked) { model, ids in await model.archive(threadIDs: ids) }
    }

    private func bulkJunk() async {
        let picked = selectedSummaries
        endSelecting()
        close(picked)
        await scope.perform(on: picked) { model, ids in await model.junk(threadIDs: ids) }
    }

    private func bulkMove() {
        let picked = selectedSummaries
        if let model = picked.first.flatMap(scope.model(for:)) {
            moveRequest = MoveRequest(model: model, summaries: picked)
        }
        endSelecting()
    }
}

/// A pending move: the conversations to relocate, wrapped so `.sheet(item:)` can
/// drive the destination picker and the ids survive the selection clearing.
private struct MoveRequest: Identifiable {
    let id = UUID()
    let model: InboxModel
    let summaries: [ThreadSummary]
}

/// A saved draft loaded for editing, wrapped so `.sheet(item:)` can present the
/// prefilled composer.
private struct DraftEditRequest: Identifiable {
    let id = UUID()
    let model: InboxModel
    let edit: DraftEdit
}

/// The swipe actions on an inbox row: trash trailing; read/unread toggle (full
/// swipe) and flag/unflag together on the leading edge. Disabled while
/// searching, where results are navigate-only so a mutation can't leave the
/// result list stale.
private struct RowActions: ViewModifier {
    let model: InboxModel?
    let summary: ThreadSummary
    let enabled: Bool
    /// Opens the move-destination picker for this conversation.
    let onMove: (InboxModel, ThreadSummary) -> Void
    /// Called with the conversation as a swipe or menu action takes it out of
    /// the list.
    let onRemove: (ThreadSummary) -> Void

    func body(content: Content) -> some View {
        if enabled, let model {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onRemove(summary)
                        Task { await model.trash(summary) }
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    Button {
                        onRemove(summary)
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
                        onRemove(summary)
                        Task { await model.archive(summary) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button {
                        onMove(model, summary)
                    } label: {
                        Label("Move to…", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        onRemove(summary)
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
    var account: Account?
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
                if isNamed || summary.lastActivity != nil || account != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if isNamed {
                            Text(participantText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let account {
                            AccountDot(color: account.color, size: 7)
                        }
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
        .contentShape(.rect)
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
