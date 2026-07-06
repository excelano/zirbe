// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The find-in-conversation panel that overlays an open thread. A search field at
// the top filters the conversation down to the messages that contain the query,
// each shown as a result row with the sender and a one-line snippet around the
// match; tapping a row closes the panel and jumps the thread to that bubble. The
// match itself is computed in ZirbeCore (ConversationSearch); this is only its
// presentation. Nothing leaves the device: the thread is already in memory.

import SwiftUI
import ZirbeCore

/// The search overlay shown over a conversation while finding within it: the
/// field, the filtered results, and the empty and no-match states. Sits on an
/// opaque canvas so the conversation it covers doesn't show through.
struct ConversationSearchPanel: View {
    @Binding var text: String
    let hits: [ConversationSearch.Hit]
    let onCancel: () -> Void
    let onJump: (_ messageID: String) -> Void

    @FocusState private var fieldFocused: Bool

    private var isQuerying: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.zirbeCanvas)
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in Conversation", text: $text)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if isQuerying {
                    Button {
                        text = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Cancel", action: onCancel)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var results: some View {
        if !isQuerying {
            // Waiting for a query: a quiet hint rather than an empty expanse.
            hintState
        } else if hits.isEmpty {
            ContentUnavailableView.search(text: text)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(hits) { hit in
                        Button { onJump(hit.messageID) } label: {
                            ConversationSearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
    }

    private var hintState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Find a word or phrase in this conversation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// One find result: the sender's avatar, their name and the message date, and a
/// one-line snippet with the matched span emphasized.
private struct ConversationSearchResultRow: View {
    let hit: ConversationSearch.Hit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SenderAvatar(participant: hit.sender, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.sender.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if let date = hit.date {
                        Text(date, format: .dateTime.month().day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(highlighted)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// The snippet with the matched span drawn in the accent color and bold, so
    /// the hit stands out in the line of context. Offsets come from ZirbeCore and
    /// are clamped defensively before use.
    private var highlighted: AttributedString {
        var attributed = AttributedString(hit.snippet)
        let count = hit.snippet.count
        let start = max(0, min(hit.highlightStart, count))
        let end = max(start, min(hit.highlightStart + hit.highlightLength, count))
        guard start < end else { return attributed }
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(attributed.startIndex, offsetByCharacters: end)
        attributed[lower..<upper].foregroundColor = .accentColor
        attributed[lower..<upper].font = .callout.weight(.semibold)
        return attributed
    }
}
