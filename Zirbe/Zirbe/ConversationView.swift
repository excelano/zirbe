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
import UIKit
import ZirbeCore
import KlartextUI

struct ConversationView: View {
    let model: InboxModel
    let summary: ThreadSummary

    @Environment(\.dismiss) private var dismiss
    @State private var thread: ZirbeCore.Thread?
    @State private var isLoading = true
    @State private var replyText = ""
    @State private var isSending = false
    @State private var removedAddresses: Set<String> = []
    @State private var showRecipients = false
    /// The message currently shown as its HTML web view, taking over the whole
    /// conversation tray; nil when the tray shows the normal chat of bubbles.
    @State private var activeWeb: ActiveWeb?
    /// When set, an HTML email opens straight in its Web View instead of the text
    /// bubble (the user opted out of the text-first default in Settings).
    @AppStorage(SettingsKeys.openHTMLInWebView) private var openHTMLInWebView = false
    /// When set, the Web View loads remote images by default rather than blocking
    /// them.
    @AppStorage(SettingsKeys.loadRemoteImages) private var loadRemoteImages = false

    /// A message switched to its web view: which message, the fetched body (HTML
    /// plus inline images), and whether remote images are shown. Replaces the chat
    /// tray while set. The message id keys the web view's identity so SwiftUI
    /// rebuilds it (a fresh `cid:` handler) when a different message opens, per
    /// EmailHTMLView's contract.
    private struct ActiveWeb {
        var messageID: String
        var body: WebViewBody
        var showImages: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // A custom top bar in place of the system navigation bar, so the
            // subject can read on two left-justified lines (the inline bar is
            // fixed-height, centered, and single-line). Trash pops back
            // optimistically and moves on the server in the background; a failed
            // move (server-first) just leaves the conversation in the inbox.
            ConversationTopBar(
                title: subjectTitle,
                onBack: { dismiss() },
                onTrash: {
                    dismiss()
                    Task { await model.trash(summary) }
                }
            )
            Divider()
            if let thread {
                RecipientHeader(
                    to: activeTo(in: thread),
                    cc: activeCc(in: thread),
                    isNoteToSelf: isNoteToSelf(in: thread)
                ) { showRecipients = true }
                Divider()
                if let active = activeWeb {
                    webTray(active)
                } else {
                    conversation(thread)
                }
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
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showRecipients) {
            if let thread {
                let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: model.account)
                RecipientsView(to: to, cc: cc, removedAddresses: $removedAddresses)
            }
        }
        .task {
            let loaded = await model.conversation(id: summary.id)
            // Decide the starting view before revealing anything: with the HTML-in-
            // Web-View preference on, fetch the newest message's HTML while the
            // loading spinner is still up, so the conversation opens straight into
            // the web view instead of flashing the text bubbles first.
            if let loaded { await prepareInitialWebView(loaded) }
            thread = loaded
            isLoading = false
            if let loaded { await model.markReadOnOpen(loaded) }
        }
    }

    private var subjectTitle: String {
        summary.subject.isEmpty ? "(no subject)" : summary.subject
    }

    /// With the "open HTML in Web View" preference on, fetch the newest message's
    /// HTML and set it as the active web view BEFORE the conversation is revealed,
    /// so it opens straight into the web view with no flash of the text bubbles.
    /// Falls through to the chat of bubbles when the preference is off, the newest
    /// message isn't HTML, or the fetch fails. The tray's "Text View" button still
    /// returns to the bubbles, so this is only the starting view, not a one-way
    /// door. Images load per the image preference.
    private func prepareInitialWebView(_ thread: ZirbeCore.Thread) async {
        guard openHTMLInWebView,
              let latest = thread.messages.last, latest.hasHTML else { return }
        if let body = await model.htmlBody(for: latest.id) {
            activeWeb = ActiveWeb(messageID: latest.id, body: body, showImages: loadRemoteImages)
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
                        model: model,
                        message: message,
                        isOwn: isOwn(message),
                        hasTail: isLastInRun(at: index, in: messages),
                        showSender: !isOwn(message) && isFirstOfRun(at: index, in: messages),
                        onShowWeb: { body, showImages in
                            activeWeb = ActiveWeb(messageID: message.id, body: body, showImages: showImages)
                        }
                    )
                    .padding(.top, index > 0 && isFirstOfRun(at: index, in: messages) ? 8 : 0)
                }
            }
            .padding()
        }
    }

    /// The web view taking over the whole tray: a toggle bar across the top
    /// (switch back to the chat, show or hide images) and the message's HTML
    /// filling everything below. No bubble chrome, sender, or timestamp here, the
    /// way the web view stands alone.
    private func webTray(_ active: ActiveWeb) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WebControlButton(title: "Text View", systemImage: "text.alignleft", edge: .leading) {
                    activeWeb = nil
                }
                Divider().frame(height: 18)
                WebControlButton(
                    title: active.showImages ? "Hide Images" : "Show Images",
                    systemImage: active.showImages ? "eye.slash" : "eye",
                    edge: .trailing
                ) {
                    activeWeb?.showImages.toggle()
                }
            }
            .foregroundStyle(.tint)
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            EmailHTMLView(
                content: EmailContent(
                    html: active.body.html,
                    parts: active.body.inlineImages.map {
                        EmailPart(
                            mimeType: $0.mimeType,
                            contentID: $0.contentID,
                            disposition: .inline,
                            data: $0.data
                        )
                    }
                ),
                allowRemoteContent: active.showImages
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(active.messageID)
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

/// The conversation's own top bar, in place of the system navigation bar so the
/// subject can read on two left-justified lines (the inline bar is fixed-height,
/// centered, and single-line). The back chevron and trash sit on the first line
/// with the subject between them; a subject too long for one line wraps to a
/// second line below, still left-justified. When even two lines truncate, the
/// title turns tappable and the whole subject opens in a popover.
private struct ConversationTopBar: View {
    let title: String
    let onBack: () -> Void
    let onTrash: () -> Void

    @State private var isTruncated = false
    @State private var showingFull = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            circleButton(systemName: "chevron.left", tint: .accentColor, action: onBack)
                .accessibilityLabel("Back")

            Button {
                // Only the truncated title has more to show; an untruncated one is
                // a no-op tap rather than a disabled (dimmed) control.
                if isTruncated { showingFull = true }
            } label: {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(truncationProbe)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onPreferenceChange(SubjectTruncationKey.self) { isTruncated = $0 }
            .popover(isPresented: $showingFull) {
                ScrollView {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        // A fixed width plus vertical fixedSize makes the popover
                        // text wrap to as many lines as it needs, not one long row.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding()
                }
                .presentationCompactAdaptation(.popover)
            }

            circleButton(systemName: "trash", tint: .red, action: onTrash)
                .accessibilityLabel("Trash Conversation")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// A round, tappable button matching the compose sheet's header circles, sized
    /// for a comfortable tap target. Its centre is pinned to the subject's first
    /// line (via the `.top` alignment guide) so a wrapped two-line subject doesn't
    /// drag it down to the block's middle.
    private func circleButton(
        systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Color(.secondarySystemFill), in: Circle())
        }
        .alignmentGuide(.top) { dims in (dims.height - titleLineHeight) / 2 }
    }

    /// One line of the title's height, used to centre the round buttons on the
    /// subject's first line.
    private var titleLineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .headline).lineHeight
    }

    /// Invisible measurement behind the two-line title: it lays the full subject
    /// out at the title's exact width and compares its height to the displayed
    /// (two-line-capped) height, raising the truncation flag only when the full
    /// text is genuinely taller. Deterministic, so a one-line subject never reads
    /// as truncated.
    private var truncationProbe: some View {
        GeometryReader { shown in
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .background(
                    GeometryReader { full in
                        Color.clear.preference(
                            key: SubjectTruncationKey.self,
                            value: full.size.height > shown.size.height + 1
                        )
                    }
                )
                .hidden()
        }
    }
}

/// Raised when the full subject can't fit the title's two lines, so the title
/// turns into a tappable control that reveals the whole subject.
private struct SubjectTruncationKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
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
    let model: InboxModel
    let message: Message
    let isOwn: Bool
    /// Whether this bubble ends a run, so it gets the tail and the timestamp.
    let hasTail: Bool
    /// Whether to show the sender's name above, set once atop a run of incoming
    /// messages.
    let showSender: Bool
    /// Hand the fetched body up so the conversation can take over its tray with
    /// the web view: the HTML plus inline images, and whether to show remote
    /// images on open.
    let onShowWeb: (_ body: WebViewBody, _ showImages: Bool) -> Void

    @State private var quoteExpanded = false
    /// Which action is fetching, so only the tapped button shows a spinner: nil
    /// when idle, true for an images-on open, false for an images-blocked one.
    @State private var loadingWithImages: Bool?
    /// Whether the Web View loads remote images by default. When on, the single
    /// "Web View" button opens with images and the separate "Show Images" shortcut
    /// is dropped as redundant.
    @AppStorage(SettingsKeys.loadRemoteImages) private var loadRemoteImages = false

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
                        // Inset from the screen edge (past the bubble), on the
                        // same side the bubble hugs.
                        .padding(isOwn ? .trailing : .leading, 22)
                }
            }
            if !isOwn { Spacer(minLength: 40) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.hasHTML { webViewControls }
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
        // The tail droops below the bottom edge. When a timestamp follows it
        // reserves the row's bottom space (and clears the tail horizontally), so
        // explicit clearance is only needed for a tailed bubble with no date.
        .padding(.bottom, (hasTail && message.date == nil) ? BubbleShape.tailDrop : 0)
    }

    /// The "Web View" affordances, shown when the message carries an HTML
    /// alternative: two buttons spanning the bubble's top, one opening the HTML
    /// with remote images blocked (the safe default) and one opening it with
    /// images already shown, so the reader who wants them needn't ask twice.
    private var webViewControls: some View {
        HStack(spacing: 0) {
            WebControlButton(
                title: "Web View", systemImage: "safari", edge: .leading,
                isLoading: loadingWithImages == loadRemoteImages
            ) { openWebView(showImages: loadRemoteImages) }
            // When images already load by default the second button would just
            // repeat the first, so it only appears in the privacy-default mode as
            // the one-tap way to bring images in.
            if !loadRemoteImages {
                Divider().frame(height: 18)
                WebControlButton(
                    title: "Show Images", systemImage: "eye", edge: .trailing,
                    isLoading: loadingWithImages == true
                ) { openWebView(showImages: true) }
            }
        }
        .disabled(loadingWithImages != nil)
        // Same size as the email body, in a tone sitting between the faint
        // accessory color and the full-strength body text.
        .foregroundStyle(isOwn ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }

    /// Fetch the message's HTML and inline images, then hand them up so the
    /// conversation takes over its tray with the web view, with remote images on
    /// or off per the button tapped. A failure is left to the model (it sets
    /// `errorMessage`); nothing happens here.
    private func openWebView(showImages: Bool) {
        loadingWithImages = showImages
        Task {
            let body = await model.htmlBody(for: message.id)
            loadingWithImages = nil
            if let body { onShowWeb(body, showImages) }
        }
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

/// A Messages-style bubble drawn as one continuous outline so the fill is always
/// clean. The last bubble of a run grows a small tail off its bottom outer corner
/// (trailing for your own messages, leading for others): a curved crescent that
/// hooks down off the bottom edge with a rounded tip and an inward curl, matching
/// the current-iOS tail rather than the older side-tail. The tip dips `tailDrop`
/// below the bottom edge and the bubble reserves that much clearance so it stays
/// clear of the timestamp. The curve was dialed in visually; the constants are
/// the locked values (see git history for the tuning round).
private struct BubbleShape: Shape {
    let isOwn: Bool
    let hasTail: Bool

    /// Bubble corner radius (every corner except the tail-side bottom one).
    static let radius: CGFloat = 16
    /// Clearance reserved below the bubble so the tail clears the timestamp.
    static let tailDrop: CGFloat = 10

    /// How far the tail is pasted toward the outer corner. The tail keeps its
    /// shape exactly; this only translates it, and the tail-side bottom corner
    /// tightens by the same amount to make room (`radius - slide`).
    private static let slide: CGFloat = 8.5

    func path(in rect: CGRect) -> Path {
        let r = Self.radius
        guard hasTail else { return Path(roundedRect: rect, cornerRadius: r) }

        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let slide = Self.slide
        let brc = r - slide   // tightened tail-side bottom corner
        var p = Path()

        if isOwn {
            // Tail at the bottom-right, attached at rx; the bottom-right corner is
            // tightened to brc so the (rigid) tail sits further toward the edge.
            let rx = maxX - r + slide
            p.move(to: CGPoint(x: minX + r, y: maxY))
            p.addQuadCurve(to: CGPoint(x: minX, y: maxY - r), control: CGPoint(x: minX, y: maxY))
            p.addLine(to: CGPoint(x: minX, y: minY + r))
            p.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: maxX - r, y: minY))
            p.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: maxY - brc))
            p.addQuadCurve(to: CGPoint(x: rx, y: maxY), control: CGPoint(x: maxX, y: maxY))
            // The tail: outer edge to the rounded tip, the tip cap, then the curl.
            p.addQuadCurve(to: CGPoint(x: rx - 0.5, y: maxY + 8), control: CGPoint(x: rx - 4, y: maxY + 5))
            p.addQuadCurve(to: CGPoint(x: rx - 5.5, y: maxY + 8), control: CGPoint(x: rx - 1.75, y: maxY + 10.5))
            p.addQuadCurve(to: CGPoint(x: rx - 14, y: maxY), control: CGPoint(x: rx - 8, y: maxY + 7))
            p.addLine(to: CGPoint(x: minX + r, y: maxY))
        } else {
            // Mirror: tail at the bottom-left, attached at lx.
            let lx = minX + r - slide
            p.move(to: CGPoint(x: maxX - r, y: maxY))
            p.addQuadCurve(to: CGPoint(x: maxX, y: maxY - r), control: CGPoint(x: maxX, y: maxY))
            p.addLine(to: CGPoint(x: maxX, y: minY + r))
            p.addQuadCurve(to: CGPoint(x: maxX - r, y: minY), control: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: minX + r, y: minY))
            p.addQuadCurve(to: CGPoint(x: minX, y: minY + r), control: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: minX, y: maxY - brc))
            p.addQuadCurve(to: CGPoint(x: lx, y: maxY), control: CGPoint(x: minX, y: maxY))
            p.addQuadCurve(to: CGPoint(x: lx + 0.5, y: maxY + 8), control: CGPoint(x: lx + 4, y: maxY + 5))
            p.addQuadCurve(to: CGPoint(x: lx + 5.5, y: maxY + 8), control: CGPoint(x: lx + 1.75, y: maxY + 10.5))
            p.addQuadCurve(to: CGPoint(x: lx + 14, y: maxY), control: CGPoint(x: lx + 8, y: maxY + 7))
            p.addLine(to: CGPoint(x: maxX - r, y: maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// One of a pair of web controls: an icon and label that hugs the given outer
/// edge, so two of them span a row with symmetric outside padding. Shared by the
/// text bubble (open the web view, show images) and the web view's own top bar
/// (back to text, show or hide images), so both rows look and sit the same.
private struct WebControlButton: View {
    let title: String
    let systemImage: String
    let edge: HorizontalEdge
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    // Keep the label on one line; the bubble widens to fit it
                    // rather than wrapping "Show Images" in a narrow bubble.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Half the width each for a big tap target, label hugging the outer
            // edge so the row's outside padding is symmetric and the leading icon
            // lines up under the body text's left margin.
            .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
