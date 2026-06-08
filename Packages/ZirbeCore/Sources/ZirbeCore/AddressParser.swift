// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A small, forgiving parser for RFC 5322 address fields. Not a full grammar:
// it handles the shapes real mail uses (`Name <addr>`, quoted names with
// commas, bare addresses, comma-separated lists) and is deliberately lenient
// about the rest, because the cost of a mis-parse here is only a label.

import Foundation

public enum AddressParser {
    /// Parse an address-list header value (`To`, `Cc`) into participants,
    /// splitting on top-level commas so quoted names containing commas stay
    /// intact.
    public static func parseList(_ raw: String?) -> [Participant] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return splitTopLevel(raw).compactMap(parseOne)
    }

    /// Parse a single address. Returns nil if there is nothing address-like in
    /// the string.
    public static func parseOne(_ raw: String) -> Participant? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // `display-name <addr-spec>` form. Use the last angle pair so a stray
        // `<` inside the name doesn't throw us off.
        if let close = s.lastIndex(of: ">"),
           let open = s[..<close].lastIndex(of: "<") {
            let addr = s[s.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = unquote(String(s[..<open]).trimmingCharacters(in: .whitespaces))
            if isPlausibleAddress(addr) {
                return Participant(address: addr, displayName: name.isEmpty ? nil : name)
            }
        }

        guard isPlausibleAddress(s) else { return nil }
        return Participant(address: s)
    }

    /// Split on commas that are not inside quotes or angle brackets.
    static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        for ch in s {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: angleDepth += 1; current.append(ch)
            case ">" where !inQuotes: angleDepth = max(0, angleDepth - 1); current.append(ch)
            case "," where !inQuotes && angleDepth == 0:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Strip surrounding double quotes and unescape `\"` / `\\` inside them.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let inner = s.dropFirst().dropLast()
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A pragmatic test: one `@`, with non-empty, space-free parts on each side.
    static func isPlausibleAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        return !local.isEmpty && !domain.isEmpty
            && !s.contains(" ") && domain.contains(".")
    }
}
