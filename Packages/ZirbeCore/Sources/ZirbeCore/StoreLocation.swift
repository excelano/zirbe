// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The on-device location of the single SQLite store. Resolved here, in one
// place, so the live session (AppSession) and the headless background refresh
// (BackgroundRefresh) open the very same file rather than drifting to two.

import Foundation

/// Where the offline mail store lives on device: a single SQLite file under
/// Application Support. Both the foreground session and the background poll
/// resolve the path through here.
enum StoreLocation {
    /// The store's URL, creating the Application Support directory if needed.
    static func databaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent("zirbe.sqlite")
    }

    /// The store's filesystem path, for `MailStore(path:)`.
    static func databasePath() throws -> String {
        try databaseURL().path
    }
}
