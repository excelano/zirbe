// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The letters and color slot for a sender's avatar when there's no contact
// photo. Pure and platform-agnostic: the app target maps the index onto an
// actual color and draws the circle, this layer just decides what to draw.

import Foundation

/// Derives a sender's monogram: one or two initials and a stable palette slot,
/// both keyed off the address so the same correspondent always reads the same.
public enum Monogram {
    /// Up to two uppercase initials for the avatar. Prefers the display name's
    /// first and last word (so "Pat Lee" reads "PL"), falls back to the email's
    /// local part ("pat.lee@x.com" reads "PL"), and returns "" when no letter or
    /// digit can be found, which the view renders as a person glyph instead.
    public static func initials(displayName: String?, address: String) -> String {
        if let name = displayName, let letters = initials(from: name, separators: .whitespaces) {
            return letters
        }
        let localPart = String(address.prefix { $0 != "@" })
        return initials(from: localPart, separators: CharacterSet(charactersIn: "._-+")) ?? ""
    }

    /// A deterministic palette slot in `0..<count`, stable across launches.
    /// Rolls its own hash rather than `Hashable`, whose seed is randomized per
    /// process, so a sender keeps the same color from one run to the next.
    public static func paletteIndex(for address: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 5381 // djb2
        for byte in address.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Int(hash % UInt64(count))
    }

    /// First letter (or digit) of the first and last token, uppercased. One
    /// initial when there's a single token, nil when no token carries a letter
    /// or digit.
    private static func initials(from text: String, separators: CharacterSet) -> String? {
        let firstLetters = text
            .components(separatedBy: separators)
            .compactMap { word in word.first { $0.isLetter || $0.isNumber } }
        guard let first = firstLetters.first else { return nil }
        if firstLetters.count >= 2, let last = firstLetters.last {
            return String([first, last]).uppercased()
        }
        return String(first).uppercased()
    }
}
