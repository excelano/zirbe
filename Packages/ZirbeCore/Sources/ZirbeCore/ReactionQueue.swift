// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The undo window for reactions (tapbacks). A reaction the user adds shows on
// its bubble at once but is only emailed after a short pause, so a mis-tap can
// be taken back before anyone sees it. This type owns that timing, keyed by the
// reacted-to message's Message-ID: tapping the emoji already pending removes it,
// a different emoji replaces it and restarts the window, and an explicit undo
// cancels it. Leaving the conversation or backgrounding the app flushes every
// pending reaction immediately, so the window is a courtesy, never a way to
// silently drop one. The conversation view owns the sending: it sets
// `onCommit` and the queue calls it once per reaction that survives its window.

import Foundation
import Observation

@MainActor
@Observable
public final class ReactionQueue {
    /// The reactions still inside their window, emoji by Message-ID.
    public private(set) var pending: [String: String] = [:]
    /// How long a reaction waits before it is sent.
    public let undoWindow: Duration
    /// Called once per committed reaction, with its emoji and the reacted-to
    /// Message-ID. Set by the owner; a queue with no handler drops the commit.
    public var onCommit: (@MainActor (_ emoji: String, _ messageID: String) async -> Void)?

    private var timers: [String: Task<Void, Never>] = [:]

    public init(undoWindow: Duration = .seconds(5)) {
        self.undoWindow = undoWindow
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// The emoji waiting on a message, if any. Nil for a nil id, so a bubble
    /// without a Message-ID reads as having nothing pending.
    public func pendingEmoji(for messageID: String?) -> String? {
        messageID.flatMap { pending[$0] }
    }

    /// Add, change, or take back the user's reaction to a message. The same emoji
    /// as the one pending removes it; any other replaces it and restarts the
    /// window. Nothing is sent until the window passes.
    public func react(_ emoji: String, to messageID: String) {
        cancelTimer(for: messageID)
        if pending[messageID] == emoji {
            pending[messageID] = nil
            return
        }
        pending[messageID] = emoji
        timers[messageID] = Task { [weak self] in
            try? await Task.sleep(for: self?.undoWindow ?? .zero)
            guard !Task.isCancelled, let self else { return }
            await self.commit(messageID)
        }
    }

    /// Take back a reaction still inside its window. Nothing was sent.
    public func undo(_ messageID: String) {
        cancelTimer(for: messageID)
        pending[messageID] = nil
    }

    /// Send every pending reaction now, cancelling their windows. The badges
    /// clear at once; the sends run on their own.
    public func flush() {
        let flushed = pending
        pending = [:]
        for (messageID, emoji) in flushed {
            cancelTimer(for: messageID)
            Task { await onCommit?(emoji, messageID) }
        }
    }

    private func commit(_ messageID: String) async {
        guard let emoji = pending.removeValue(forKey: messageID) else { return }
        timers[messageID] = nil
        await onCommit?(emoji, messageID)
    }

    private func cancelTimer(for messageID: String) {
        timers[messageID]?.cancel()
        timers[messageID] = nil
    }
}
