// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A conversation as a stack of time-ordered bubbles, the user's own messages on
// the trailing side and everyone else's on the leading side, the way a group
// chat reads. The subject is the title. Bodies load on first open and are then
// served from the store, so a second open needs no network. A tappable header
// shows who a reply reaches, subtle lines mark who joined or left, and a bottom
// bar sends a reply-all back into the thread.

import SwiftUI
import ZirbeCore

struct ConversationView: View {
    let model: InboxModel
    let summary: ThreadSummary

    @State private var thread: ZirbeCore.Thread?
    @State private var isLoading = true
    @State private var replyText = ""
    @State private var isSending = false
    @State private var removedAddresses: Set<String> = []
    @State private var showRecipients = false

    var body: some View {
        VStack(spacing: 0) {
            if let thread {
                RecipientHeader(
                    to: activeTo(in: thread),
                    cc: activeCc(in: thread),
                    isNoteToSelf: isNoteToSelf(in: thread)
                ) { showRecipients = true }
                Divider()
                conversation(thread)
                Divider()
                ReplyBar(text: $replyText, isSending: isSending, onSend: { send(into: thread) })
            } else if isLoading {
                ProgressView("Loading…").frame(maxHeight: .infinity)
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
        .sheet(isPresented: $showRecipients) {
            if let thread {
                let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: model.account)
                RecipientsView(to: to, cc: cc, removedAddresses: $removedAddresses)
            }
        }
        .task {
            let loaded = await model.conversation(id: summary.id)
            thread = loaded
            isLoading = false
            if let loaded { await model.markReadOnOpen(loaded) }
        }
    }

    private func conversation(_ thread: ZirbeCore.Thread) -> some View {
        let deltas = Dictionary(
            ParticipantChange.deltas(across: thread.messages, excluding: model.account.emailAddress)
                .map { ($0.messageID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let messages = thread.messages
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if let delta = deltas[message.id] {
                        ParticipantChangeLine(delta: delta)
                            .padding(.vertical, 8)
                    }
                    MessageBubble(
                        message: message,
                        isOwn: isOwn(message),
                        hasTail: isLastInRun(at: index, in: messages),
                        showSender: !isOwn(message) && isFirstOfRun(at: index, in: messages)
                    )
                    .padding(.top, index > 0 && isFirstOfRun(at: index, in: messages) ? 8 : 0)
                }
            }
            .padding()
        }
    }

    private func isOwn(_ message: Message) -> Bool {
        message.from?.address == model.account.emailAddress
    }

    /// Whether this message ends a run of consecutive messages from one sender,
    /// so it carries the tail and the timestamp. True for the last message
    /// overall and whenever the next message is from someone else.
    private func isLastInRun(at index: Int, in messages: [Message]) -> Bool {
        guard index < messages.count - 1 else { return true }
        return messages[index].from?.address != messages[index + 1].from?.address
    }

    /// Whether this message begins a run from a new sender, so the sender name
    /// shows once atop the run and a little space separates it from the one
    /// before. True for the very first message.
    private func isFirstOfRun(at index: Int, in messages: [Message]) -> Bool {
        guard index > 0 else { return true }
        return messages[index].from?.address != messages[index - 1].from?.address
    }

    /// The reply-all recipients with the user's removals applied, for the header.
    private func activeTo(in thread: ZirbeCore.Thread) -> [Participant] {
        let (to, _) = ReplyBuilder.replyAllRecipients(to: thread, as: model.account)
        return to.filter { !removedAddresses.contains($0.address) }
    }

    private func activeCc(in thread: ZirbeCore.Thread) -> [Participant] {
        let (_, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: model.account)
        return cc.filter { !removedAddresses.contains($0.address) }
    }

    /// Whether this conversation is just the user talking to themselves, so the
    /// header reads "Note to self" and isn't editable. True when reply-all lands
    /// on the account alone.
    private func isNoteToSelf(in thread: ZirbeCore.Thread) -> Bool {
        let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: model.account)
        return cc.isEmpty && to.count == 1 && to.first?.address == model.account.emailAddress.lowercased()
    }

    private func send(into thread: ZirbeCore.Thread) {
        let text = replyText
        isSending = true
        Task {
            let updated = await model.sendReply(to: thread, removing: removedAddresses, body: text)
            isSending = false
            if let updated {
                self.thread = updated
                replyText = ""
            }
        }
    }
}

/// The slim, tappable strip above the conversation showing who a reply reaches.
/// Tapping opens the recipient editor where people can be dropped.
private struct RecipientHeader: View {
    let to: [Participant]
    let cc: [Participant]
    let isNoteToSelf: Bool
    let onTap: () -> Void

    var body: some View {
        if isNoteToSelf {
            // A note to self has no one to add or drop, so the header is a plain
            // label, not a button into the recipient editor.
            strip(showChevron: false)
        } else {
            Button(action: onTap) { strip(showChevron: true) }
                .buttonStyle(.plain)
        }
    }

    private func strip(showChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isNoteToSelf ? "person" : "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var summaryText: String {
        if isNoteToSelf { return "Note to self" }
        let everyone = to + cc
        guard !everyone.isEmpty else { return "No recipients" }
        let names = everyone.prefix(2).map(\.label).joined(separator: ", ")
        let extra = everyone.count - min(2, everyone.count)
        return extra > 0 ? "To: \(names) +\(extra)" : "To: \(names)"
    }
}

/// A subtle, centered line marking who joined or left the conversation at this
/// point, the way a group chat notes membership changes.
private struct ParticipantChangeLine: View {
    let delta: ParticipantChange.Delta

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private var text: String {
        var parts: [String] = []
        if !delta.added.isEmpty {
            parts.append("\(names(delta.added)) joined")
        }
        if !delta.removed.isEmpty {
            parts.append("\(names(delta.removed)) left")
        }
        return parts.joined(separator: " · ")
    }

    private func names(_ people: [Participant]) -> String {
        people.map(\.label).joined(separator: ", ")
    }
}

/// The bottom reply bar: a growing text field and a send button, in the Messages
/// idiom. Send is disabled while empty or in flight.
private struct ReplyBar: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
            }
            .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// One message bubble: the sender's name for incoming messages, the text body,
/// and the time. Outgoing messages are tinted and right-aligned. The quoted
/// history is folded behind a "Show quoted text" control so the reply reads
/// first, with the original one tap away.
private struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    /// Whether this bubble ends a run, so it gets the tail and the timestamp.
    let hasTail: Bool
    /// Whether to show the sender's name above, set once atop a run of incoming
    /// messages.
    let showSender: Bool

    @State private var quoteExpanded = false

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 40) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if showSender, let name = message.from?.label {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                bubble
                if hasTail, let date = message.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            if !isOwn { Spacer(minLength: 40) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(folded.visible.isEmpty ? "(quoted message)" : folded.visible)
                .foregroundStyle(folded.visible.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(isOwn ? .white : .primary))
            if let quoted = folded.quoted {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { quoteExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: quoteExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text(quoteExpanded ? "Hide quoted text" : "Show quoted text")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(isOwn ? AnyShapeStyle(Color.white.opacity(0.6)) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                if quoteExpanded {
                    Text(quoted)
                        .font(.callout)
                        .foregroundStyle(isOwn ? Color.white.opacity(0.85) : .secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isOwn ? Color.accentColor : Color(.secondarySystemBackground),
            in: BubbleShape(isOwn: isOwn, hasTail: hasTail)
        )
    }

    /// The body split into the part to show and the quoted history to fold. An
    /// empty body falls back to a placeholder so a bubble is never blank.
    private var folded: QuotedText.Folded {
        let text = message.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            return QuotedText.Folded(visible: "(no text content)", quoted: nil)
        }
        return QuotedText.fold(text)
    }
}

/// A Messages-style bubble: a rounded rectangle that grows a small curved tail at
/// its bottom outer corner (trailing for your own messages, leading for others)
/// on the last bubble of a run. The tail is drawn just past the bubble's edge,
/// into the gutter, so consecutive bubbles in a run stay edge-aligned.
private struct BubbleShape: Shape {
    let isOwn: Bool
    let hasTail: Bool
    var radius: CGFloat = 17
    var tail: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        guard hasTail else { return path }

        if isOwn {
            path.move(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX + tail, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius * 0.7, y: rect.maxY - radius * 0.6),
                control: CGPoint(x: rect.maxX, y: rect.maxY - radius * 0.45)
            )
        } else {
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX - tail, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius * 0.7, y: rect.maxY - radius * 0.6),
                control: CGPoint(x: rect.minX, y: rect.maxY - radius * 0.45)
            )
        }
        path.closeSubpath()
        return path
    }
}
