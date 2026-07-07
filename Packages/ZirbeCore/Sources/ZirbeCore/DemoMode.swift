// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Demo/screenshot mode. When active, the app skips the real account and shows a
// set of generic sample conversations instead, so App Store screenshots carry no
// real mail. It is DEBUG-only: the flag reads false in release, the seed data is
// compiled out, and even when on it runs against an isolated in-memory store, so
// the signed-in account and its cached mail are never touched.

import Foundation

/// Whether the app should run in demo/screenshot mode. Toggled two ways, either
/// of which wins: the `--demo` launch argument (for automated simulator capture)
/// or the "Demo mode" switch in Settings (for a look on-device). Both resolve to
/// false in a release build, so no demo path can ship to the App Store.
public enum DemoMode {
    /// The UserDefaults key the Settings toggle writes and this flag reads.
    public static let userDefaultsKey = "demoMode"

    public static var isActive: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { return true }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
        #else
        return false
        #endif
    }

    /// Whether to open the top conversation on launch, for capturing the thread
    /// screen without a tap. Set by the `--demo-open` launch argument alongside
    /// `--demo`. Release always returns false.
    public static var opensTopConversation: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--demo-open")
        #else
        return false
        #endif
    }

    /// A search query to pre-fill on launch, for capturing the search-results
    /// screen without typing. Set by `--demo-search <query>` alongside `--demo`;
    /// defaults to a name that matches several sample conversations when no query
    /// follows the flag. Release always returns nil.
    public static var searchQuery: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--demo-search") else { return nil }
        let next = args.indices.contains(i + 1) ? args[i + 1] : ""
        return (next.isEmpty || next.hasPrefix("--")) ? "Priya" : next
        #else
        return nil
        #endif
    }
}

#if DEBUG
/// The sample account and conversations shown in demo mode. Personal, casual mail
/// — the Messages-style warmth Zirbe is built around — with invented people and
/// no real content. Seeded into an in-memory store, then rethreaded so the
/// conversations materialize exactly as synced mail would.
public enum DemoData {
    /// The demo user. Sent bubbles are the messages from this address; everyone
    /// else lands on the left. A neutral personal address, not a real one.
    public static let account = Account(
        emailAddress: "sam.rivera@fastmail.com",
        displayName: "Sam Rivera",
        imapHost: "imap.fastmail.com",
        smtpHost: "smtp.fastmail.com"
    )

    private static let me = account.selfParticipant
    private static let priya = Participant(address: "priya.menon@hey.com", displayName: "Priya Menon")
    private static let daniel = Participant(address: "daniel.okafor@gmail.com", displayName: "Daniel Okafor")
    private static let leo = Participant(address: "leo.brandt@gmail.com", displayName: "Leo Brandt")
    private static let maya = Participant(address: "maya.singh@gmail.com", displayName: "Maya Singh")

    /// Seed a fresh in-memory store with the sample account, an INBOX, and the
    /// conversations, then rethread so the inbox list and previews are ready to
    /// read with no network.
    public static func seed(into store: MailStore) async throws {
        try await store.upsert(account)
        try await store.upsert(Mailbox(accountID: account.id, name: "INBOX", role: .inbox))
        try await store.save(messages(), accountID: account.id, mailboxName: "INBOX")
        try await store.rethread(accountID: account.id)
    }

    /// A date `minutes` before now, for staging the conversations in time.
    private static func ago(_ minutes: Double) -> Date {
        Date().addingTimeInterval(-minutes * 60)
    }

    /// Build one sample message. Bodies are set here so the store serves whole
    /// conversations offline (no lazy body fetch), and `rethread` can derive each
    /// inbox row's preview from them.
    private static func msg(
        _ id: String,
        from: Participant,
        to: [Participant],
        subject: String,
        body: String,
        minutesAgo: Double,
        seen: Bool = true,
        inReplyTo: String? = nil,
        references: [String] = [],
        uid: UInt32
    ) -> Message {
        Message(
            messageID: id,
            uid: uid,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            from: from,
            to: to,
            date: ago(minutesAgo),
            flags: seen ? [.seen] : [],
            bodyText: body
        )
    }

    private static func messages() -> [Message] {
        var all: [Message] = []

        // The hero: a live group thread, unread, with a back-and-forth that shows
        // both incoming bubbles and the user's own sent bubbles.
        let cabin = "Cabin weekend"
        all += [
            msg("cabin-1", from: priya, to: [me, daniel], subject: cabin,
                body: "Okay, I booked the cabin for the 18th–20th! Two bedrooms, sleeps six, and there's a hot tub on the deck.",
                minutesAgo: 46, seen: false, uid: 101),
            msg("cabin-2", from: daniel, to: [me, priya], subject: "Re: \(cabin)",
                body: "Incredible. I'll bring the kayaks and the good coffee.",
                minutesAgo: 33, seen: false, inReplyTo: "cabin-1", references: ["cabin-1"], uid: 102),
            msg("cabin-3", from: me, to: [priya, daniel], subject: "Re: \(cabin)",
                body: "I've got Friday dinner covered. Anyone allergic to anything I should plan around?",
                minutesAgo: 21, inReplyTo: "cabin-2", references: ["cabin-1", "cabin-2"], uid: 103),
            msg("cabin-4", from: priya, to: [me, daniel], subject: "Re: \(cabin)",
                body: "Only Daniel's fear of vegetables. Can't wait!",
                minutesAgo: 7, seen: false, inReplyTo: "cabin-3", references: ["cabin-1", "cabin-2", "cabin-3"], uid: 104),
        ]

        all.append(msg("hike-1", from: priya, to: [me], subject: "Photos from the ridge",
            body: "Sending the good ones before I forget. That shot from the top came out unreal — you can see all the way to the coast.",
            minutesAgo: 5 * 60, seen: false, uid: 105))

        all += [
            msg("lunch-1", from: daniel, to: [me], subject: "Lunch Thursday?",
                body: "Free for lunch Thursday? The ramen place on 5th finally reopened.",
                minutesAgo: 26 * 60, inReplyTo: nil, uid: 106),
            msg("lunch-2", from: me, to: [daniel], subject: "Re: Lunch Thursday?",
                body: "Yes please. 12:30 work?",
                minutesAgo: 25 * 60, inReplyTo: "lunch-1", references: ["lunch-1"], uid: 107),
        ]

        all.append(msg("book-1", from: leo, to: [me, priya, daniel], subject: "Book club: the next pick",
            body: "Votes are in — we're reading Piranesi next. Meeting at my place on the 25th, I'll sort out snacks.",
            minutesAgo: 2 * 24 * 60, uid: 108))

        all += [
            msg("bike-1", from: me, to: [leo], subject: "The bike pump",
                body: "Thanks again for lending me the pump — total lifesaver on the ride home.",
                minutesAgo: 3 * 24 * 60 + 30, inReplyTo: nil, uid: 109),
            msg("bike-2", from: leo, to: [me], subject: "Re: The bike pump",
                body: "Anytime! Keep it as long as you need, I've got a spare.",
                minutesAgo: 3 * 24 * 60, inReplyTo: "bike-1", references: ["bike-1"], uid: 110),
        ]

        all.append(msg("hood-1", from: maya, to: [me], subject: "Welcome to the street!",
            body: "So glad you moved in — we're the blue house two doors down. Coffee this weekend once you're unpacked?",
            minutesAgo: 4 * 24 * 60, uid: 111))

        return all
    }
}
#endif
