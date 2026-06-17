// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The Zirbe-domain adapter over Klartext's quote handling. Klartext owns the
// heuristics in both directions: seam detection on an incoming body, and quote-
// trailer synthesis on our own outgoing reply. This type only maps Zirbe's
// Message/Participant domain onto Klartext's primitive API and hands back the
// Folded value the conversation bubble consumes. No boundary detection lives
// here anymore.

import Foundation
import Klartext

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

    /// Split `body` at the first quoted-history boundary via Klartext, and drop a
    /// trailing signature from the visible text so the bubble shows just the new
    /// words. Klartext separates the signature on conservative markers only (the
    /// RFC 3676 `-- ` delimiter, mobile/auto footers), so a mid-message "Thanks,"
    /// is never mistaken for one. The signature is only hidden from this glance,
    /// not lost: the raw body and the HTML Web View still carry it in full.
    public static func fold(_ body: String) -> Folded {
        let parsed = Klartext.parse(plainText: body)
        return Folded(visible: parsed.visible, quoted: parsed.quoted)
    }

    /// A one-line glance of a body for the inbox row. Klartext's preview strips
    /// the salutation, signature, and quoted history down to just the new
    /// content, which is exactly what a list row wants; this collapses that to a
    /// single line and bounds it so a long paragraph doesn't bloat the stored
    /// snippet. Empty when the body reduces to nothing shown (an image-only mail),
    /// which the caller treats as "no preview" rather than a blank line.
    public static func snippet(_ body: String, maxLength: Int = 160) -> String {
        Klartext.parse(plainText: body)
            .preview(maxLength: maxLength)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Compose the body of a reply: the user's words, then a blank line, then the
    /// conventional quote trailer for the message being answered (normally the
    /// conversation's most recent). Locale and time zone control the attribution
    /// date and default to the device's.
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

    /// The quote trailer for one message. Klartext builds the attribution line and
    /// the `> `-prefixed body; Zirbe supplies the sender's display label and the
    /// "someone" fallback for a message that carries no From.
    public static func quoteTrailer(
        for message: Message,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        Klartext.replyQuoteTrailer(
            body: message.bodyText ?? "",
            from: message.from?.addressLabel ?? "someone",
            date: message.date,
            locale: locale,
            timeZone: timeZone
        )
    }
}
