// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Strips reply/forward prefixes from a subject so a thread shows one clean
// title instead of a creeping pile of "Re: Re: Fwd:". The conversation keeps
// its name; the prefixes are noise.

import Foundation

public enum SubjectNormalizer {
    /// Remove leading `Re:` / `Fwd:` / `Fw:` prefixes (repeated, case-insensitive,
    /// with optional `[n]` counters as some mailers add) and return the trimmed
    /// core subject. An empty or whitespace-only subject normalizes to "".
    public static func normalize(_ subject: String?) -> String {
        guard var s = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return ""
        }
        // One prefix at the front: re | fwd | fw, an optional [n] counter, a
        // colon, optional space.
        let pattern = #"^(?:re|fwd|fw)(?:\[\d+\])?:\s*"#
        while let range = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
