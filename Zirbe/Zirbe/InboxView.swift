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

    var body: some View {
        List(model.summaries) { summary in
            NavigationLink {
                ConversationView(model: model, summary: summary)
            } label: {
                ThreadRow(summary: summary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Sign Out") { model.signOut() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isComposing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Conversation")
            }
        }
        .sheet(isPresented: $isComposing) {
            ComposeView(model: model)
        }
        .overlay {
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
            }
        }
        .refreshable { await model.refresh() }
        .task {
            await model.loadCached()
            if model.summaries.isEmpty {
                await model.refresh()
            }
        }
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
