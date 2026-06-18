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
    @State private var isComposing = false
    @State private var showingSettings = false
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
                .modifier(RowActions(model: model, summary: summary, enabled: !isSearching))
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(isSelecting ? .inline : .large)
        .toolbar { toolbarContent }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search mail")
        .sheet(isPresented: $isComposing) {
            ComposeView(model: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(account: model.account, onSignOut: onSignOut)
        }
        .overlay { emptyState }
        .refreshable { await model.refresh() }
        .task {
            await model.loadCached()
            if model.summaries.isEmpty {
                await model.refresh()
            }
        }
        .task(id: searchText) { await runSearch() }
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

    private var navigationTitle: String {
        guard isSelecting else { return "Conversations" }
        return selection.isEmpty ? "Select" : "\(selection.count) Selected"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                Button(role: .destructive) {
                    Task { await bulkTrash() }
                } label: {
                    Label("Trash", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
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

    /// Trash the selected conversations, then leave selection mode.
    private func bulkTrash() async {
        let ids = Array(selection)
        endSelecting()
        await model.trash(threadIDs: ids)
    }
}

/// The swipe actions on an inbox row: trash trailing, read/unread toggle
/// leading. Disabled while searching, where results are navigate-only so a
/// mutation can't leave the result list stale.
private struct RowActions: ViewModifier {
    let model: InboxModel
    let summary: ThreadSummary
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await model.trash(summary) }
                    } label: {
                        Label("Trash", systemImage: "trash")
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
