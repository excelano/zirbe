// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Find within one open conversation: match a query against the messages already
// loaded in a thread and return one result per matching message, each with a
// one-line snippet around the hit for the search list. Pure and local — the
// thread is already in memory, so this is an in-memory filter with no network,
// the same posture as the inbox search. Matching is case- and diacritic-
// insensitive, and it searches the visible body text (the words the bubble
// shows), so what you find is what you'd read.

import Foundation

public enum ConversationSearch {
    /// One matching message in the conversation: which message (by stable `id`),
    /// its sender and date for the result row, and a one-line snippet with the
    /// matched span marked by character offsets into the snippet.
    public struct Hit: Identifiable, Sendable, Hashable {
        /// The matched message's stable `Message.id`, so the caller can scroll to
        /// the bubble.
        public let messageID: String
        /// The sender, carried whole so the result row draws the same avatar
        /// (photo and color) the thread does.
        public let sender: Participant
        public let date: Date?
        /// A single line of context around the first match, trimmed and elided.
        public let snippet: String
        /// The matched span within `snippet`, as a character offset and length
        /// (the matched text can differ in length from the query, since matching
        /// ignores diacritics).
        public let highlightStart: Int
        public let highlightLength: Int

        public var id: String { messageID }

        public init(messageID: String, sender: Participant, date: Date?, snippet: String, highlightStart: Int, highlightLength: Int) {
            self.messageID = messageID
            self.sender = sender
            self.date = date
            self.snippet = snippet
            self.highlightStart = highlightStart
            self.highlightLength = highlightLength
        }
    }

    /// The matching messages for `query`, in the order they were given (which the
    /// caller passes chronologically). One hit per message, on its first match. A
    /// blank query, or a thread with nothing to show, yields no hits.
    public static func hits(for query: String, in messages: [Message], contextRadius: Int = 40) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return messages.compactMap { hit(for: q, in: $0, contextRadius: contextRadius) }
    }

    /// The hit for a single message, or nil when its visible text doesn't match.
    private static func hit(for query: String, in message: Message, contextRadius: Int) -> Hit? {
        let text = normalize(QuotedText.fold(message.bodyText ?? "").visible)
        guard !text.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let (snippet, start, length) = snippet(of: text, around: range, radius: contextRadius)
        return Hit(
            messageID: message.id,
            sender: message.from ?? Participant(address: "", displayName: "Unknown"),
            date: message.date,
            snippet: snippet,
            highlightStart: start,
            highlightLength: length
        )
    }

    /// Collapse all runs of whitespace and newlines to single spaces so the
    /// snippet reads as one line.
    private static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A one-line window of `text` around `match`: up to `radius` characters on
    /// each side, with a leading or trailing ellipsis when the window is cut from
    /// a longer line. Returns the snippet and the match's offset and length within
    /// it (the ellipsis shifts the offset when present).
    private static func snippet(
        of text: String,
        around match: Range<String.Index>,
        radius: Int
    ) -> (snippet: String, start: Int, length: Int) {
        let length = text.distance(from: match.lowerBound, to: match.upperBound)
        let lowerOffset = text.distance(from: text.startIndex, to: match.lowerBound)
        let upperOffset = text.distance(from: text.startIndex, to: match.upperBound)

        let startOffset = max(0, lowerOffset - radius)
        let endOffset = min(text.count, upperOffset + radius)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)

        var snippet = String(text[start..<end])
        var highlightStart = lowerOffset - startOffset
        if startOffset > 0 {
            snippet = "…" + snippet
            highlightStart += 1
        }
        if endOffset < text.count {
            snippet += "…"
        }
        return (snippet, highlightStart, length)
    }
}
