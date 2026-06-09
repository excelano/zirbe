// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Quoted history, in both directions. `fold` minimizes the quoted trailer on a
// received message so a bubble shows the new words and tucks the rest behind a
// tap-to-expand. `replyBody` builds the conventional quote trailer onto our own
// outgoing reply, so the people we answer keep their thread context.
//
// The fold is a heuristic and deliberately errs toward folding: a mis-fold is
// harmless because the reader can expand it, whereas leaving a long quote inline
// defeats the point. We never parse the quoted text for meaning (participants,
// dates); it is reproduced verbatim and only its boundary is found.

import Foundation

public enum QuotedText {
    /// A received body split into the new content shown directly and the quoted
    /// history tucked behind a control. `quoted` is nil when no quote boundary
    /// was found, in which case the whole body is `visible`.
    public struct Folded: Sendable, Hashable {
        /// The new words, shown in the bubble.
        public var visible: String
        /// The quoted history, or nil when there is none to fold.
        public var quoted: String?

        public init(visible: String, quoted: String?) {
            self.visible = visible
            self.quoted = quoted
        }
    }

    /// Split `body` at the first quoted-history boundary. Everything above it is
    /// the new content; everything from it down is the quoted trailer. When no
    /// boundary is found the whole body is returned as `visible` with no quote.
    /// A body that is entirely quoted (a bare forward) returns an empty
    /// `visible` and the whole text as `quoted`, which the UI shows expanded.
    public static func fold(_ body: String) -> Folded {
        let lines = body.components(separatedBy: "\n")
        guard let cut = boundaryIndex(in: lines) else {
            return Folded(visible: body.trimmingCharacters(in: .whitespacesAndNewlines), quoted: nil)
        }
        let visible = lines[..<cut].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = lines[cut...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Folded(visible: visible, quoted: quoted.isEmpty ? nil : quoted)
    }

    /// Compose the body of a reply: the user's words, then a blank line, then the
    /// conventional quote trailer ("On <date>, <name> wrote:" with the quoted
    /// message indented under it). The quoted message is the one being answered,
    /// normally the conversation's most recent. Locale and time zone control the
    /// attribution date and default to the device's, so the reader sees a date in
    /// the sender's own format.
    public static func replyBody(
        _ userText: String,
        quoting message: Message,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let body = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailer = quoteTrailer(for: message, locale: locale, timeZone: timeZone)
        return "\(body)\n\n\(trailer)"
    }

    /// The quote trailer for one message: its attribution line, a blank line,
    /// then the body with every line prefixed `> `. The blank line sets the
    /// quoted original apart as its own block, the way Apple Mail does. The body
    /// is whatever text we hold for the message; an empty body yields just the
    /// attribution.
    public static func quoteTrailer(
        for message: Message,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let attribution = attributionLine(for: message, locale: locale, timeZone: timeZone)
        let body = message.bodyText ?? ""
        guard !body.isEmpty else { return attribution }
        let quoted = body
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\(attribution)\n\n\(quoted)"
    }

    // MARK: - Attribution

    /// The "On <date>, at <time>, <sender> wrote:" line, in the Apple Mail shape.
    /// The date is dropped when the message has none, leaving "<sender> wrote:".
    private static func attributionLine(
        for message: Message,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let sender = message.from?.addressLabel ?? "someone"
        guard let date = message.date else { return "\(sender) wrote:" }

        let dateText = formatted(date, "MMM d, yyyy", locale: locale, timeZone: timeZone)
        let timeText = formatted(date, "h:mm a", locale: locale, timeZone: timeZone)
        return "On \(dateText), at \(timeText), \(sender) wrote:"
    }

    private static func formatted(_ date: Date, _ format: String, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: - Boundary detection

    /// The index of the first line that begins the quoted history, or nil if the
    /// body carries none. Recognizes a `>`-quoted line, an attribution line
    /// ending in "wrote:", an Outlook "Original Message" separator, and an Apple
    /// "Begin forwarded message:" marker, whichever comes first.
    private static func boundaryIndex(in lines: [String]) -> Int? {
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { return index }
            if isForwardOrOriginalMarker(line) { return index }
            if line.range(of: #"\bwrote:$"#, options: .regularExpression) != nil {
                return attributionStart(of: index, in: lines)
            }
        }
        return nil
    }

    /// An attribution can wrap across lines ("On Mon, Jun 9, 2026\nDavid <x>
    /// wrote:"). Given the line that ends in "wrote:", walk back over the
    /// contiguous non-blank block above it; if that block begins with "On ", the
    /// boundary is its first line so the whole attribution folds together.
    /// Otherwise the "wrote:" line stands alone as the boundary.
    private static func attributionStart(of index: Int, in lines: [String]) -> Int {
        var start = index
        var cursor = index - 1
        while cursor >= 0 {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { break }
            start = cursor
            if line.hasPrefix("On ") { break }
            cursor -= 1
        }
        return lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("On ") ? start : index
    }

    private static func isForwardOrOriginalMarker(_ line: String) -> Bool {
        line.range(of: #"^-{2,}\s*Original Message\s*-{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || line.caseInsensitiveCompare("Begin forwarded message:") == .orderedSame
    }
}
