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
    @State private var isComposing = false
    /// When set, the list shows only conversations with unread mail.
    @State private var showUnreadOnly = false
    /// The conversations picked in selection mode, by thread id.
    @State private var selection = Set<String>()
    /// Drives selection mode: `.active` shows the per-row circles and the bulk
    /// action bar, and turns row taps into selection rather than navigation.
    @State private var editMode: EditMode = .inactive

    private var isSelecting: Bool { editMode == .active }

    /// The rows actually shown, narrowed to unread when the filter is on.
    private var visibleSummaries: [ThreadSummary] {
        showUnreadOnly ? model.summaries.filter(\.isUnread) : model.summaries
    }

    var body: some View {
        List(visibleSummaries, selection: $selection) { summary in
            NavigationLink {
                ConversationView(model: model, summary: summary)
            } label: {
                ThreadRow(summary: summary)
            }
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
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(isSelecting ? .inline : .large)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isComposing) {
            ComposeView(model: model)
        }
        .overlay { emptyState }
        .refreshable { await model.refresh() }
        .task {
            await model.loadCached()
            if model.summaries.isEmpty {
                await model.refresh()
            }
        }
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
                Button("Sign Out") { model.signOut() }
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
        if model.summaries.isEmpty {
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

/// One inbox row: unread dot, subject, relative time, and the participants.
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
