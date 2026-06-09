// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A conversation as a stack of time-ordered bubbles, the user's own messages on
// the trailing side and everyone else's on the leading side, the way a group
// chat reads. The subject is the title. Bodies load on first open and are then
// served from the store, so a second open needs no network.

import SwiftUI
import ZirbeCore

struct ConversationView: View {
    let model: InboxModel
    let summary: ThreadSummary

    @State private var thread: ZirbeCore.Thread?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let thread {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(thread.messages) { message in
                            MessageBubble(message: message, isOwn: isOwn(message))
                        }
                    }
                    .padding()
                }
            } else if isLoading {
                ProgressView("Loading…")
            } else {
                ContentUnavailableView(
                    "Couldn’t load this conversation",
                    systemImage: "exclamationmark.triangle",
                    description: Text(model.errorMessage ?? "Try again.")
                )
            }
        }
        .navigationTitle(summary.subject.isEmpty ? "(no subject)" : summary.subject)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            thread = await model.conversation(id: summary.id)
            isLoading = false
        }
    }

    private func isOwn(_ message: Message) -> Bool {
        message.from?.address == model.account.emailAddress
    }
}

/// One message bubble: the sender's name for incoming messages, the text body,
/// and the time. Outgoing messages are tinted and right-aligned.
private struct MessageBubble: View {
    let message: Message
    let isOwn: Bool

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 40) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if !isOwn, let name = message.from?.label {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(displayText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isOwn ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundStyle(isOwn ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if let date = message.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !isOwn { Spacer(minLength: 40) }
        }
    }

    private var displayText: String {
        let text = message.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty { return text }
        return "(no text content)"
    }
}
