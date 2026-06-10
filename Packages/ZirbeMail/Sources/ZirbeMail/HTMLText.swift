// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A deliberately on-device reduction of an HTML mail body to readable plain
// text. It never loads a remote resource: there is no <img> fetch, no network,
// nothing leaves the device, so a tracking pixel in the markup is inert here.
// This is the text-first fallback and the source of preview snippets; faithful
// rich rendering (formatting, inline images, with a remote-content setting) is a
// separate WKWebView path.
//
// The reduction drops script/style/head blocks whole (tag and contents, so CSS
// and JS never leak into the text), turns block-level boundaries into line
// breaks the way a reader expects paragraphs, removes the remaining tags, and
// decodes the HTML entities that show up in real mail.

import Foundation

enum HTMLText {
    /// Reduce an HTML body to readable plain text. Returns an empty string only
    /// when the markup truly carries no text, which the caller treats as "no
    /// body" rather than caching.
    static func plainText(from html: String) -> String {
        var s = html

        // Whole blocks whose contents are never shown: tag and inner text alike.
        s = replace(s, #"(?is)<(script|style|head|title)[^>]*>.*?</\1>"#, " ")

        // Block-level boundaries read as line breaks.
        s = replace(s, #"(?i)<br\s*/?>"#, "\n")
        s = replace(s, #"(?i)</(p|div|li|tr|h[1-6]|ul|ol|table|blockquote|section|article|header|footer)\s*>"#, "\n")

        // Everything else that is a tag simply disappears.
        s = replace(s, #"<[^>]+>"#, "")

        s = decodeEntities(s)

        // Tidy whitespace: collapse spaces, strip trailing spaces on a line, and
        // cap blank-line runs so paragraphs stay separated without big gaps.
        s = replace(s, #"[ \t]+"#, " ")
        s = replace(s, #"[ \t]*\n[ \t]*"#, "\n")
        s = replace(s, #"\n{3,}"#, "\n\n")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Entities

    /// Decode the HTML entities common in mail: a small named set plus numeric
    /// `&#NN;` and hex `&#xHH;` character references.
    static func decodeEntities(_ text: String) -> String {
        var s = decodeNumericEntities(text)
        for (entity, replacement) in named {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // `&amp;` last, so an `&amp;lt;` resolves to `&lt;` rather than `<`.
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let named: [String: String] = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
        "&hellip;": "\u{2026}", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&trade;": "\u{2122}",
        "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&bull;": "\u{2022}",
    ]

    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
