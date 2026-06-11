// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Offline server autodiscovery. Given an email address, we infer the IMAP and
// SMTP servers from a baked-in table of well-known providers, keyed on the
// domain. This is deliberately NOT a network lookup: RFC 6186 SRV records or
// Mozilla's autoconfig database would leak the address (or at least its domain)
// to a third party, which the privacy posture forbids. Everything here is a
// static table plus a same-domain guess, so onboarding never touches the
// network before the user's own mail server.

import Foundation

/// Connection settings for a provider, used to prefill the onboarding form. A
/// `displayName` marks a recognized provider ("Looks like Fastmail"); its
/// absence marks the generic same-domain guess, which the UI presents as
/// editable server fields rather than a confident match.
public struct ProviderPreset: Sendable, Equatable {
    public let displayName: String?
    public let imapHost: String
    public let imapPort: Int
    public let smtpHost: String
    public let smtpPort: Int
    /// A short, honest note on how to authenticate with this provider, e.g. that
    /// it needs an app-specific password rather than the normal login password.
    public let passwordHint: String?

    public init(
        displayName: String?,
        imapHost: String,
        imapPort: Int = 993,
        smtpHost: String,
        smtpPort: Int = 587,
        passwordHint: String? = nil
    ) {
        self.displayName = displayName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.passwordHint = passwordHint
    }
}

/// The autodiscovery table and the same-domain fallback. Pure and offline.
public enum ProviderPresets {
    /// A recognized provider for this email, or nil when the domain is unknown.
    /// Matching is case-insensitive on the part after the `@`.
    public static func preset(forEmail email: String) -> ProviderPreset? {
        guard let domain = domain(of: email) else { return nil }
        return byDomain[domain]
    }

    /// A best-effort guess for an unknown domain: `imap.<domain>` /
    /// `smtp.<domain>`, which is the convention a large share of self-hosted and
    /// smaller providers follow. No `displayName`, so the UI shows these as
    /// editable suggestions, not a confident match. Returns nil only when the
    /// address has no usable domain.
    public static func suggestion(forEmail email: String) -> ProviderPreset? {
        guard let domain = domain(of: email) else { return nil }
        return ProviderPreset(
            displayName: nil,
            imapHost: "imap.\(domain)",
            smtpHost: "smtp.\(domain)"
        )
    }

    /// The recognized preset for an email if there is one, otherwise the
    /// same-domain guess. nil only when the address has no domain.
    public static func resolve(forEmail email: String) -> ProviderPreset? {
        preset(forEmail: email) ?? suggestion(forEmail: email)
    }

    /// The lowercased domain of an email, or nil if there isn't exactly one `@`
    /// with non-empty parts on both sides.
    private static func domain(of email: String) -> String? {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    // MARK: Known providers

    private static let icloud = ProviderPreset(
        displayName: "iCloud",
        imapHost: "imap.mail.me.com",
        smtpHost: "smtp.mail.me.com",
        passwordHint: "iCloud needs an app-specific password. Create one at appleid.apple.com under Sign-In and Security."
    )

    private static let fastmail = ProviderPreset(
        displayName: "Fastmail",
        imapHost: "imap.fastmail.com",
        smtpHost: "smtp.fastmail.com",
        passwordHint: "Fastmail needs an app password. Create one in Settings → Privacy & Security → App passwords."
    )

    private static let gmail = ProviderPreset(
        displayName: "Gmail",
        imapHost: "imap.gmail.com",
        smtpHost: "smtp.gmail.com",
        passwordHint: "Gmail needs an app password (requires 2-Step Verification). Native Google sign-in comes in a later release."
    )

    private static let yahoo = ProviderPreset(
        displayName: "Yahoo",
        imapHost: "imap.mail.yahoo.com",
        smtpHost: "smtp.mail.yahoo.com",
        passwordHint: "Yahoo needs an app password. Create one in Account Security → Generate app password."
    )

    private static let aol = ProviderPreset(
        displayName: "AOL",
        imapHost: "imap.aol.com",
        smtpHost: "smtp.aol.com",
        passwordHint: "AOL needs an app password. Create one in Account Security → Generate app password."
    )

    private static let outlook = ProviderPreset(
        displayName: "Outlook",
        imapHost: "outlook.office365.com",
        smtpHost: "smtp.office365.com",
        passwordHint: "Many Microsoft accounts no longer allow password sign-in and need OAuth, which Zirbe adds in a later release. If yours requires it, this may fail until then."
    )

    private static let byDomain: [String: ProviderPreset] = [
        "icloud.com": icloud,
        "me.com": icloud,
        "mac.com": icloud,
        "fastmail.com": fastmail,
        "gmail.com": gmail,
        "googlemail.com": gmail,
        "yahoo.com": yahoo,
        "ymail.com": yahoo,
        "rocketmail.com": yahoo,
        "aol.com": aol,
        "outlook.com": outlook,
        "hotmail.com": outlook,
        "live.com": outlook,
        "msn.com": outlook,
    ]
}
