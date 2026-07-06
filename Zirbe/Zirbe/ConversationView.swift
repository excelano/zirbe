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
import QuickLook
import UniformTypeIdentifiers
import ZirbeCore
import KlartextUI

struct ConversationView: View {
    let model: InboxModel
    let summary: ThreadSummary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var thread: ZirbeCore.Thread?
    /// The user's just-added reactions still inside their undo window, keyed by
    /// the reacted-to message's Message-ID. Each holds the emoji and the timer
    /// that will send it; the badge shows it at once, and a remove or change
    /// before the timer fires means no email was ever sent. Emptied as each one
    /// commits (or is undone), and flushed early when the view leaves.
    @State private var pendingReactions: [String: PendingReaction] = [:]
    /// The flagged state shown in the top bar. Seeded from the inbox summary for
    /// an instant read, refined once the thread loads, and toggled optimistically.
    @State private var isFlagged = false
    @State private var isLoading = true
    /// Whether the find-in-conversation panel is up, and its live query and
    /// results. The panel overlays the (still-mounted) chat, so closing it and
    /// scrolling to a hit is instant.
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchHits: [ConversationSearch.Hit] = []
    /// A message to scroll to (a tapped search result); consumed and cleared by
    /// the chat's scroll reader.
    @State private var scrollTarget: String?
    /// A message to briefly emphasize after a jump, so the eye finds where it
    /// landed; cleared on its own after a moment.
    @State private var flashedMessage: String?
    @State private var replyText = ""
    @State private var replyAttachments: [StagedAttachment] = []
    /// The earlier message a swipe-to-reply is answering, shown as a chip above the
    /// reply bar; nil for a normal reply into the thread (which answers the latest).
    @State private var replyTarget: Message?
    /// A one-shot flag that asks the reply bar to take focus after a swipe.
    @State private var focusReply = false
    @State private var isSending = false
    @State private var removedAddresses: Set<String> = []
    @State private var showRecipients = false
    /// Presents the move-destination picker for this conversation.
    @State private var isMoving = false
    /// The message the user chose to forward, presenting the forward composer;
    /// nil when no forward is in progress.
    @State private var forwardingMessage: Message?
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

    /// A reaction the user added that hasn't been sent yet: its emoji and the
    /// timer that will send it once the undo window passes. Cancelling the task
    /// (a remove, a change, or a re-tap of the same emoji) means the reaction
    /// never leaves the device.
    private struct PendingReaction {
        var emoji: String
        var task: Task<Void, Never>
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
                isFlagged: isFlagged,
                onToggleFlag: {
                    isFlagged.toggle()
                    Task { await model.markFlagged(threadID: summary.id, flagged: isFlagged) }
                },
                onBack: { dismiss() },
                onTrash: {
                    dismiss()
                    Task { await model.trash(summary) }
                },
                onArchive: {
                    dismiss()
                    Task { await model.archive(summary) }
                },
                onJunk: {
                    dismiss()
                    Task { await model.junk(summary) }
                },
                onMove: { isMoving = true },
                // Find works over the chat of bubbles, so leave any open Web View
                // first; the tapped result lands on a bubble.
                onFind: { activeWeb = nil; isSearching = true }
            )
            Divider()
            if let thread {
                if !isSearching {
                    RecipientHeader(
                        to: activeTo(in: thread),
                        cc: activeCc(in: thread),
                        isNoteToSelf: isNoteToSelf(in: thread)
                    ) { showRecipients = true }
                    Divider()
                }
                // The chat stays mounted under the search panel so closing Find
                // and scrolling to a tapped result is instant, with no rebuild.
                ZStack {
                    if let active = activeWeb {
                        webTray(active)
                    } else {
                        conversation(thread)
                    }
                    if isSearching {
                        ConversationSearchPanel(
                            text: $searchText,
                            hits: searchHits,
                            onCancel: { exitSearch() },
                            onJump: { jump(to: $0) }
                        )
                    }
                }
                if !isSearching {
                    Divider()
                    if let target = replyTarget {
                        ReplyTargetChip(message: target) {
                            replyTarget = nil
                            dismissKeyboard()
                        }
                    }
                    ReplyBar(
                        text: $replyText,
                        attachments: $replyAttachments,
                        isSending: isSending,
                        focusRequest: $focusReply,
                        onSend: { send(into: thread) }
                    )
                }
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
        .background(Color.zirbeCanvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showRecipients) {
            if let thread {
                let (to, cc) = ReplyBuilder.replyAllRecipients(to: thread, as: model.account)
                RecipientsView(to: to, cc: cc, removedAddresses: $removedAddresses)
            }
        }
        .sheet(item: $forwardingMessage) { message in
            if let thread {
                ForwardView(model: model, message: message, thread: thread)
            }
        }
        .sheet(isPresented: $isMoving) {
            MailboxesView(
                model: model,
                mode: .move(threadIDs: [summary.id]),
                onMoved: { dismiss() }
            )
        }
        .task {
            isFlagged = summary.isFlagged
            let loaded = await model.conversation(id: summary.id)
            // Decide the starting view before revealing anything: with the HTML-in-
            // Web-View preference on, fetch the newest message's HTML while the
            // loading spinner is still up, so the conversation opens straight into
            // the web view instead of flashing the text bubbles first.
            if let loaded { await prepareInitialWebView(loaded) }
            thread = loaded
            isLoading = false
            if let loaded {
                isFlagged = loaded.isFlagged
                await model.markReadOnOpen(loaded)
            }
        }
        // A pending reaction's undo window is a courtesy, not a way to silently
        // drop it: leaving the conversation or backgrounding the app sends any
        // that are still waiting, so the only way to cancel one is an explicit
        // undo while it's on screen.
        .onDisappear { flushPendingReactions() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPendingReactions() }
        }
        // Recompute the find results as the query changes, debounced so a burst of
        // keystrokes issues one pass. Mirrors the inbox search.
        .task(id: searchText) { await runConversationSearch() }
    }

    /// Filter the loaded thread to the messages matching the current query, after
    /// a short debounce. A blank query clears the results.
    private func runConversationSearch() async {
        guard let thread,
              !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchHits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }
        searchHits = ConversationSearch.hits(for: searchText, in: thread.conversationMessages)
    }

    /// Close the find panel and jump the chat to the tapped message, flashing it
    /// briefly so the eye finds where it landed.
    private func jump(to messageID: String) {
        exitSearch()
        flashedMessage = messageID
        scrollTarget = messageID
    }

    /// Leave find: hide the panel and drop the query and its results.
    private func exitSearch() {
        isSearching = false
        searchText = ""
        searchHits = []
    }

    private var subjectTitle: String {
        ConversationDefaults.displayTitle(
            subject: summary.subject,
            participants: summary.participants,
            selfAddress: model.account.emailAddress
        )
    }

    /// With the "open HTML in Web View" preference on, fetch the newest message's
    /// HTML and set it as the active web view BEFORE the conversation is revealed,
    /// so it opens straight into the web view with no flash of the text bubbles.
    /// Falls through to the chat of bubbles when the preference is off, the newest
    /// message isn't HTML, or the fetch fails. The tray's "Chat View" button still
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
        // Reactions are shown as badges on their target, not as bubbles, so the
        // stack, the run grouping, and the join/leave lines are all over the chat
        // messages alone.
        let messages = thread.conversationMessages
        let deltas = Dictionary(
            ParticipantChange.deltas(across: messages, excluding: model.account.emailAddress)
                .map { ($0.messageID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let dayDate = daySeparatorDate(at: index, in: messages) {
                            DaySeparatorView(date: dayDate)
                                .padding(.vertical, 4)
                        }
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
                            reactions: thread.reactions(forMessageID: message.messageID),
                            pendingEmoji: pendingReactions[message.messageID ?? ""]?.emoji,
                            lockedEmoji: myCommittedEmoji(on: message.messageID, in: thread),
                            selfAddress: model.account.emailAddress,
                            isFlashed: flashedMessage == message.id,
                            onReact: { emoji in react(emoji, to: message, in: thread) },
                            onUndoReaction: { undoReaction(on: message) },
                            onReply: { beginReply(to: message) },
                            onShowWeb: { body, showImages in
                                activeWeb = ActiveWeb(messageID: message.id, body: body, showImages: showImages)
                            },
                            onForward: { forwardingMessage = message },
                            onRetry: { await retry(message, into: thread) }
                        )
                        .padding(.top, index > 0 && isFirstOfRun(at: index, in: messages) ? 8 : 0)
                    }
                }
                .padding()
                // Room for a reaction badge overhanging the newest bubble's top edge.
                .padding(.top, 6)
            }
            // A tapped search result scrolls its bubble to center; the flash it set
            // fades on its own shortly after.
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    if flashedMessage == target {
                        withAnimation { flashedMessage = nil }
                    }
                }
            }
        }
    }

    /// The emoji the user has already sent on a message, if any. A sent reaction
    /// is final, so this is what locks the picker for that message.
    private func myCommittedEmoji(on messageID: String?, in thread: ZirbeCore.Thread) -> String? {
        guard let messageID else { return nil }
        let me = model.account.emailAddress.lowercased()
        return thread.reactions(forMessageID: messageID)
            .first { $0.reactor.address.lowercased() == me }?.emoji
    }

    /// Add, change, or undo the user's reaction to a message. The badge updates at
    /// once; the email is scheduled for after the undo window. Tapping the emoji
    /// already pending removes it; a different emoji replaces it and restarts the
    /// window. A reaction already sent is locked and ignored here.
    private func react(_ emoji: String, to message: Message, in thread: ZirbeCore.Thread) {
        guard let mid = message.messageID, !mid.isEmpty else { return }
        guard myCommittedEmoji(on: mid, in: thread) == nil else { return }

        pendingReactions[mid]?.task.cancel()
        if pendingReactions[mid]?.emoji == emoji {
            pendingReactions[mid] = nil
            return
        }
        let task = Task {
            try? await Task.sleep(for: ReactionPalette.undoWindow)
            if Task.isCancelled { return }
            await commitReaction(emoji, to: mid, in: thread)
        }
        pendingReactions[mid] = PendingReaction(emoji: emoji, task: task)
    }

    /// Remove a reaction still inside its undo window. Nothing was sent, so this
    /// just cancels the pending send and clears the badge.
    private func undoReaction(on message: Message) {
        guard let mid = message.messageID else { return }
        pendingReactions[mid]?.task.cancel()
        pendingReactions[mid] = nil
    }

    /// Send a pending reaction once its window has passed, then swap in the
    /// refreshed thread so the badge carries over from tentative to sent.
    private func commitReaction(_ emoji: String, to messageID: String, in thread: ZirbeCore.Thread) async {
        let refreshed = await model.sendReaction(emoji, to: messageID, in: thread)
        pendingReactions[messageID] = nil
        if let refreshed { self.thread = refreshed }
    }

    /// Send every reaction still waiting, now, cancelling their timers. Called
    /// when the conversation leaves the screen or the app backgrounds, so a
    /// pending reaction is never silently dropped.
    private func flushPendingReactions() {
        guard !pendingReactions.isEmpty, let thread else { return }
        for (mid, pending) in pendingReactions {
            pending.task.cancel()
            let emoji = pending.emoji
            Task { await model.sendReaction(emoji, to: mid, in: thread) }
        }
        pendingReactions = [:]
    }

    /// The web view taking over the whole tray: a toggle bar across the top
    /// (switch back to the chat, show or hide images) and the message's HTML
    /// filling everything below. No bubble chrome, sender, or timestamp here, the
    /// way the web view stands alone.
    private func webTray(_ active: ActiveWeb) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WebControlButton(title: "Chat View", systemImage: "text.alignleft", edge: .leading) {
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

    /// The date to caption a day separator above this message, or nil when it
    /// shares a calendar day with the message before it. The first dated message
    /// always gets one. Messages without a date never carry a separator.
    private func daySeparatorDate(at index: Int, in messages: [Message]) -> Date? {
        guard let date = messages[index].date else { return nil }
        guard index > 0, let previous = messages[index - 1].date else { return date }
        return Calendar.current.isDate(date, inSameDayAs: previous) ? nil : date
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
        let files = replyAttachments.map(\.attachment)
        let targetID = replyTarget?.messageID
        isSending = true
        Task {
            let updated = await model.sendReply(to: thread, removing: removedAddresses, body: text, attachments: files, replyingToMessageID: targetID)
            isSending = false
            if let updated {
                self.thread = updated
                replyText = ""
                replyAttachments = []
                replyTarget = nil
            }
        }
    }

    /// Begin a reply aimed at a specific message (a swipe on its bubble, or its
    /// long-press Reply): remember it as the target and focus the reply bar.
    private func beginReply(to message: Message) {
        replyTarget = message
        focusReply = true
    }

    /// Resign the reply field's keyboard. Used when canceling a swipe-to-reply, so
    /// clearing the target also puts the keyboard away rather than leaving a stray
    /// cursor in the reply box.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Retry a reply that failed to send, resending the held draft. The refreshed
    /// thread flips the bubble to sent on success, or leaves it undelivered to try
    /// again. A nil return (the draft was lost, or not connected) leaves the
    /// existing failed bubble as it was.
    private func retry(_ message: Message, into thread: ZirbeCore.Thread) async {
        guard let messageID = message.messageID else { return }
        if let updated = await model.retrySend(messageID: messageID, in: thread.id) {
            self.thread = updated
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
    let isFlagged: Bool
    let onToggleFlag: () -> Void
    let onBack: () -> Void
    let onTrash: () -> Void
    let onArchive: () -> Void
    let onJunk: () -> Void
    let onMove: () -> Void
    let onFind: () -> Void

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
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Flagged")
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(truncationProbe)
                }
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

            Menu {
                Button(action: onFind) {
                    Label("Find in Conversation", systemImage: "magnifyingglass")
                }
                Button(action: onToggleFlag) {
                    Label(isFlagged ? "Unflag" : "Flag", systemImage: isFlagged ? "flag.slash" : "flag")
                }
                Button(action: onArchive) {
                    Label("Archive", systemImage: "archivebox")
                }
                Button(action: onMove) {
                    Label("Move to…", systemImage: "folder")
                }
                Button(role: .destructive, action: onJunk) {
                    Label("Move to Junk", systemImage: "xmark.bin")
                }
                Button(role: .destructive, action: onTrash) {
                    Label("Trash", systemImage: "trash")
                }
            } label: {
                circleLabel(systemName: "ellipsis", tint: .accentColor)
            }
            .alignmentGuide(.top) { dims in (dims.height - titleLineHeight) / 2 }
            .accessibilityLabel("More Actions")
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
            circleLabel(systemName: systemName, tint: tint)
        }
        .alignmentGuide(.top) { dims in (dims.height - titleLineHeight) / 2 }
    }

    /// The round, tinted glyph shared by the bar's buttons and its actions menu,
    /// so a `Menu` (which can't use `circleButton`'s `Button`) sits the same as the
    /// tappable circles beside it.
    private func circleLabel(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(Color(.secondarySystemFill), in: Circle())
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
/// The centered caption marking a change of day between bubbles: "Today",
/// "Yesterday", a weekday within the past week, then a short date.
private struct DaySeparatorView: View {
    let date: Date

    var body: some View {
        Text(DayLabel.text(for: date, now: Date()))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

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

/// The bottom message bar: a growing text field, an attach button, and a send
/// button, in the Messages idiom. Shared by a reply (in a conversation) and a new
/// conversation (the composer), so the two compose the same way. Send is disabled
/// while in flight, while there's nothing to send, or while an external
/// precondition isn't met (a new conversation needs a recipient).
struct ReplyBar: View {
    @Binding var text: String
    @Binding var attachments: [StagedAttachment]
    let isSending: Bool
    /// The field's empty-state prompt: "Reply" in a thread, "Message" for a new
    /// conversation.
    var placeholder: String = "Reply"
    /// An external requirement beyond having something to send (a new conversation
    /// needs a recipient). A reply has its recipients already, so this defaults on.
    var canSend: Bool = true
    /// A one-shot request to focus the field, flipped true by the caller (a
    /// swipe-to-reply focuses the bar). The bar takes focus and resets it. Nil for
    /// callers that don't drive focus, like the new-conversation composer.
    var focusRequest: Binding<Bool>? = nil
    let onSend: () -> Void

    @FocusState private var fieldFocused: Bool

    /// Nothing to send: no typed text and no picked files.
    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttachmentTray(attachments: $attachments)
            HStack(alignment: .bottom, spacing: 8) {
                AttachButton(attachments: $attachments)
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($fieldFocused)
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
                .disabled(isSending || isEmpty || !canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // A swipe-to-reply asks the bar to take focus; consume the request so it
        // fires once per swipe.
        .onChange(of: focusRequest?.wrappedValue ?? false) { _, want in
            if want {
                fieldFocused = true
                focusRequest?.wrappedValue = false
            }
        }
    }
}

/// The strip above the reply bar naming the earlier message a swipe-to-reply is
/// answering: a reply arrow, who wrote it, a one-line glance of its text, and an
/// ✕ to cancel and return to a normal reply into the thread.
private struct ReplyTargetChip: View {
    let message: Message
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(message.from?.label ?? "the sender")")
                    .font(.caption.weight(.semibold))
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var snippet: String {
        QuotedText.snippet(message.bodyText ?? "", maxLength: 64)
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
    /// The reactions sent on this message, from everyone, drawn as a badge cluster
    /// on the bubble's corner.
    let reactions: [Reaction]
    /// The user's just-added emoji still inside its undo window, shown tentatively
    /// with an Undo affordance; nil when they have no pending reaction here.
    let pendingEmoji: String?
    /// The emoji the user has already sent on this message, which locks the picker
    /// (a sent reaction can't be changed); nil when they haven't reacted.
    let lockedEmoji: String?
    /// The account's own address, to tell the user's reactions from others' in the
    /// cluster.
    let selfAddress: String
    /// True while this bubble is the just-jumped-to search result, drawing a brief
    /// accent outline so the eye finds where the jump landed.
    let isFlashed: Bool
    /// Add, change, or remove the user's reaction to this message.
    let onReact: (String) -> Void
    /// Pull back the pending reaction before its window passes.
    let onUndoReaction: () -> Void
    /// Answer this message specifically (a swipe on the bubble, or Reply from the
    /// long-press menu): the conversation targets it and focuses the reply bar.
    let onReply: () -> Void
    /// Hand the fetched body up so the conversation can take over its tray with
    /// the web view: the HTML plus inline images, and whether to show remote
    /// images on open.
    let onShowWeb: (_ body: WebViewBody, _ showImages: Bool) -> Void
    /// Forward this message: the conversation presents the forward composer.
    let onForward: () -> Void
    /// Retry a failed send: the conversation resends the held draft and refreshes.
    /// Awaited so the footer can drop its in-flight state once the retry resolves,
    /// whether it succeeded or failed again.
    let onRetry: () async -> Void

    /// True from the moment a retry is tapped until the thread refreshes, so the
    /// failed footer reads "Retrying…" and can't be tapped twice.
    @State private var isRetrying = false
    /// Whether the reaction picker popover is showing for this bubble.
    @State private var showingReactionPicker = false
    /// The live horizontal offset while swiping the bubble to reply; springs back
    /// to zero on release.
    @State private var replyDragOffset: CGFloat = 0
    @State private var quoteExpanded = false
    /// Which action is fetching, so only the tapped button shows a spinner: nil
    /// when idle, true for an images-on open, false for an images-blocked one.
    @State private var loadingWithImages: Bool?
    /// Whether the Web View loads remote images by default. When on, the single
    /// "Web View" button opens with images and the separate "Show Images" shortcut
    /// is dropped as redundant.
    @AppStorage(SettingsKeys.loadRemoteImages) private var loadRemoteImages = false

    /// The sender avatar's diameter and the gap to the bubble. The leading inset
    /// for the name and timestamp is derived from these so they line up over the
    /// bubble whether or not an avatar is drawn.
    private let avatarSize: CGFloat = 30
    private let avatarGap: CGFloat = 6
    private var gutter: CGFloat { avatarSize + avatarGap }

    var body: some View {
        HStack(alignment: .bottom, spacing: avatarGap) {
            if !isOwn { avatarGutter }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if showSender, let name = message.from?.label {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                HStack(spacing: 0) {
                    if isOwn { Spacer(minLength: 40) }
                    bubble
                    if !isOwn { Spacer(minLength: 40) }
                }
                if message.didFailToSend {
                    failedFooter
                } else if hasTail, let date = message.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Inset from the screen edge, on the side the bubble hugs.
                        .padding(isOwn ? .trailing : .leading, 22)
                }
                if pendingEmoji != nil {
                    undoPill
                        .padding(isOwn ? .trailing : .leading, 22)
                }
            }
        }
    }

    /// The Undo affordance shown while the user's reaction is inside its window:
    /// tapping it pulls the reaction back before any email is sent. It disappears
    /// on its own once the window passes and the reaction is on its way.
    private var undoPill: some View {
        Button(action: onUndoReaction) {
            HStack(spacing: 3) {
                Text(pendingEmoji ?? "")
                Text("Undo").fontWeight(.semibold)
            }
            .font(.caption2)
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
    }

    /// The undelivered marker shown under a failed own-bubble, in place of the
    /// timestamp: a red "Not Delivered" that, while this session still holds the
    /// draft, doubles as a retry button. A bubble left undelivered by a relaunch
    /// has no held draft, so it reads "Not Delivered" alone and the user composes
    /// the reply again.
    @ViewBuilder
    private var failedFooter: some View {
        let retryable = model.canRetry(messageID: message.messageID ?? "")
        Button {
            guard retryable, !isRetrying else { return }
            isRetrying = true
            // Clear the in-flight flag when the retry resolves either way. On
            // success the footer stops rendering; on a repeat failure the bubble
            // stays undelivered and becomes tappable again rather than sticking
            // on "Retrying…".
            Task {
                await onRetry()
                isRetrying = false
            }
        } label: {
            HStack(spacing: 3) {
                if isRetrying {
                    ProgressView().controlSize(.mini)
                    Text("Retrying…")
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(retryable ? "Not Delivered · Tap to Retry" : "Not Delivered")
                }
            }
            .font(.caption2)
            .foregroundStyle(.red)
            .padding(isOwn ? .trailing : .leading, 22)
        }
        .buttonStyle(.plain)
        .disabled(!retryable || isRetrying)
    }

    /// The leading column for an incoming bubble: the sender's avatar beside the
    /// last bubble of a run, bottom-aligned with the whole stack so it sits level
    /// with the timestamp line; an empty reservation of the same width on the
    /// other bubbles of a run so they stay aligned.
    @ViewBuilder
    private var avatarGutter: some View {
        if hasTail, let from = message.from {
            SenderAvatar(participant: from, size: avatarSize)
        } else {
            Color.clear.frame(width: avatarSize, height: 0)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.hasHTML { webViewControls }
            // Let an attachment carry the bubble on its own when there's no visible
            // text to show above it: a photo or voice message sent with no words,
            // whether the body is truly empty or nothing but a folded reply quote.
            // The "(no text content)" / "(quoted message)" placeholder would just
            // clutter the bubble, and the quote stays reachable below either way.
            if hasVisibleBody || message.attachments.isEmpty {
                Text(folded.visible.isEmpty ? "(quoted message)" : folded.visible)
                    .foregroundStyle(folded.visible.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(isOwn ? .white : .primary))
            }
            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(imageAttachments.enumerated()), id: \.offset) { _, attachment in
                        InlineAttachmentImage(model: model, messageID: message.id, attachment: attachment, isOwn: isOwn)
                    }
                    ForEach(Array(audioAttachments.enumerated()), id: \.offset) { _, attachment in
                        InlineAttachmentAudio(model: model, messageID: message.id, attachment: attachment, isOwn: isOwn)
                    }
                    ForEach(Array(fileAttachments.enumerated()), id: \.offset) { _, attachment in
                        AttachmentChip(model: model, messageID: message.id, attachment: attachment, isOwn: isOwn)
                    }
                }
                .padding(.top, 2)
            }
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
            isOwn ? Color.accentColor : Color.zirbeReceived,
            in: BubbleShape(isOwn: isOwn, hasTail: hasTail)
        )
        // The search-jump flash: a brief accent outline on the landed-on bubble.
        .overlay {
            BubbleShape(isOwn: isOwn, hasTail: hasTail)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isFlashed ? 1 : 0)
        }
        // The tail droops below the bottom edge. When a timestamp follows it
        // reserves the row's bottom space (and clears the tail horizontally), so
        // explicit clearance is only needed for a tailed bubble with no date.
        .padding(.bottom, (hasTail && message.date == nil) ? BubbleShape.tailDrop : 0)
        // The reaction cluster overhangs the bubble's top inner corner, the way a
        // tapback sits in Messages: on the leading side of the user's own bubble,
        // the trailing side of everyone else's. Display-only; Undo lives below.
        .overlay(alignment: isOwn ? .topLeading : .topTrailing) {
            if !reactions.isEmpty || pendingEmoji != nil {
                ReactionCluster(reactions: reactions, pendingEmoji: pendingEmoji, selfAddress: selfAddress)
                    .offset(x: isOwn ? -8 : 8, y: -12)
                    .allowsHitTesting(false)
            }
        }
        // Long-press opens the reaction bar (and the bubble's actions), replacing
        // the plain context menu.
        .onLongPressGesture(minimumDuration: 0.35) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showingReactionPicker = true
        }
        .popover(isPresented: $showingReactionPicker) {
            ReactionMenu(
                selected: pendingEmoji ?? lockedEmoji,
                locked: lockedEmoji != nil,
                onReact: { emoji in
                    showingReactionPicker = false
                    onReact(emoji)
                },
                onReply: {
                    showingReactionPicker = false
                    onReply()
                },
                onForward: {
                    showingReactionPicker = false
                    onForward()
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        // Swipe the bubble left to reply to it: it slides under the finger,
        // revealing a reply arrow, and passing the threshold on release starts a
        // reply aimed at this message. Simultaneous so vertical scrolling still
        // wins; the gesture only engages on a leftward, horizontal-dominant drag.
        .offset(x: replyDragOffset)
        .overlay(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)
                .opacity(replyRevealProgress)
                .offset(x: 30)
        }
        .simultaneousGesture(replyDragGesture)
    }

    /// How far the reply arrow has faded in, 0…1, tracking the leftward drag up to
    /// the trigger threshold.
    private var replyRevealProgress: Double {
        Double(min(-replyDragOffset, 55) / 55)
    }

    /// The swipe-to-reply drag: track a leftward, horizontal-dominant drag as a
    /// bubble offset, fire the reply on release past the threshold, and spring
    /// back either way.
    private var replyDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      value.translation.width < 0 else { return }
                replyDragOffset = max(value.translation.width, -70)
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                if horizontal, value.translation.width < -55 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReply()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    replyDragOffset = 0
                }
            }
    }

    /// The "Web View" affordances, shown when the message carries an HTML
    /// alternative: two buttons spanning the bubble's top, one opening the HTML
    /// with remote images blocked (the safe default) and one opening it with
    /// images already shown, so the reader who wants them needn't ask twice.
    private var webViewControls: some View {
        HStack(spacing: 0) {
            WebControlButton(
                title: "Email View", systemImage: "safari", edge: .leading,
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

    /// Whether the message has no readable text body, so an attachment must carry
    /// the bubble on its own.
    private var bodyIsEmpty: Bool {
        message.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    /// Whether there's real text to show above the attachments: not a blank body,
    /// and not one that folds to nothing but a reply quote. False for a photo or
    /// voice message sent with no words, so the attachment stands alone.
    private var hasVisibleBody: Bool {
        !bodyIsEmpty && !folded.visible.isEmpty
    }

    /// Image attachments, rendered inline as thumbnails.
    private var imageAttachments: [MessageAttachment] {
        message.attachments.filter { $0.mimeType.lowercased().hasPrefix("image/") }
    }

    /// Audio attachments, rendered inline as a small player (a voice message, or
    /// any audio file).
    private var audioAttachments: [MessageAttachment] {
        message.attachments.filter { $0.mimeType.lowercased().hasPrefix("audio/") }
    }

    /// Everything else, rendered as a tappable chip.
    private var fileAttachments: [MessageAttachment] {
        message.attachments.filter {
            let type = $0.mimeType.lowercased()
            return !type.hasPrefix("image/") && !type.hasPrefix("audio/")
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

/// One attachment shown under a message bubble: a small capsule with a
/// type-appropriate icon and the file's name. Tapping fetches its bytes over the
/// warm session and opens them in QuickLook; the icon becomes a spinner while the
/// fetch is in flight. Tinted to sit on its bubble: light on an own (accent)
/// bubble, secondary on an incoming one. Long names truncate in the middle so the
/// extension stays visible.
struct AttachmentChip: View {
    let model: InboxModel
    let messageID: String
    let attachment: MessageAttachment
    let isOwn: Bool

    @State private var isLoading = false
    /// The temp file the fetched bytes were written to; setting it presents the
    /// QuickLook preview, and it clears when the preview is dismissed.
    @State private var previewURL: URL?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: AttachmentSymbol.symbol(for: attachment.mimeType))
                }
                Text(attachment.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.footnote)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isOwn ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: Capsule()
            )
            .foregroundStyle(isOwn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // A chip cached before part ids were tracked can't be opened (its body
        // re-fetches on next open); until then it's a plain, non-tappable label.
        .disabled(isLoading || attachment.partID.isEmpty)
        .quickLook($previewURL)
    }

    /// Fetch the attachment's bytes over the warm session, write them to a temp
    /// file named for the attachment, and open it in QuickLook. A failure leaves
    /// the model's `errorMessage` set; nothing opens.
    private func open() {
        guard !isLoading, !attachment.partID.isEmpty else { return }
        isLoading = true
        Task {
            let data = await model.attachmentData(messageID: messageID, partID: attachment.partID)
            isLoading = false
            guard let data else { return }
            previewURL = try? AttachmentFile.write(data, filename: attachment.filename, mimeType: attachment.mimeType)
        }
    }
}

/// Writes an attachment's decoded bytes to a temp file so QuickLook can open it.
/// The file is named for the attachment, with an extension supplied from the MIME
/// type when the name carries none, so QuickLook picks the right type. Files land
/// in a dedicated temp subdirectory the OS reclaims; a repeat open overwrites in
/// place.
enum AttachmentFile {
    static func write(_ data: Data, filename: String, mimeType: String) throws -> URL {
        var name = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if name.isEmpty { name = "Attachment" }
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
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
