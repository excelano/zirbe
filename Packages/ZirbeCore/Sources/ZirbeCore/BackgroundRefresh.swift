// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The headless background poll. iOS occasionally wakes the app (BGTaskScheduler
// app-refresh) and runs this with no UI on screen: open the store, find the
// saved account and its device-bound Keychain password, and run one inbox sync.
//
// This is the background ceiling, and deliberately so. There is no instant push:
// real push needs a server to hold the connection and notify the device, and the
// no-backend privacy posture forbids one. So new mail surfaces three ways, in
// descending immediacy: live while the inbox is foregrounded (IMAP IDLE), at the
// next background poll iOS grants, and on pull-to-refresh. This is the middle one.

import Foundation

/// The outcome of one background poll, for the caller to act on. `.newMail`
/// carries the arrivals to notify and the inbox's unread count for the app badge;
/// `.upToDate` means the sync ran but found nothing new; `.failed` means it
/// couldn't run (no account, no password, server unreachable).
public enum BackgroundRefreshResult: Sendable {
    case newMail([NewMailItem], unreadCount: Int)
    case upToDate
    case failed
}

/// The background inbox poll, run headless when iOS grants the app refresh time.
public enum BackgroundRefresh {
    /// The BGTaskScheduler task identifier. Declared in the app's Info.plist
    /// under `BGTaskSchedulerPermittedIdentifiers` and handled by the app's
    /// `.backgroundTask(.appRefresh:)`; the app target schedules and reschedules
    /// requests against it.
    public static let taskIdentifier = "com.excelano.Zirbe.refresh"

    /// Sync the inbox once, if an account and its stored password are both
    /// present. Best effort by design: any failure — no account signed in, no
    /// Keychain password, the server unreachable on the background's brief, lossy
    /// network — returns without throwing, since a missed poll is covered by the
    /// next one and by the foreground sync on reopen. The fresh connection is
    /// closed before returning so nothing lingers while the app is suspended.
    /// Returns the poll's outcome, so the caller can notify for new mail and report
    /// task completion to the scheduler. New arrivals are read against the stored
    /// high-water mark before it is advanced, so the same mail is never notified
    /// twice across polls.
    @discardableResult
    public static func run() async -> BackgroundRefreshResult {
        do {
            let store = try MailStore(path: StoreLocation.databasePath())
            guard let account = try await store.accounts().first,
                  let password = try KeychainStore.password(for: account.id) else {
                return .failed
            }
            let sync = SyncService(account: account, store: store)
            do {
                try await sync.syncInbox(password: password)
                // Read what's new since the last surfaced UID, then advance the
                // mark so the next poll starts above these. The unread count is the
                // app badge.
                let arrivals = try await store.unnotifiedInboxArrivals(accountID: account.id)
                let unreadCount = try await store.unreadCounts(accountID: account.id)["INBOX"] ?? 0
                try await store.markNotificationWatermark(accountID: account.id)
                await sync.disconnect()
                return arrivals.isEmpty ? .upToDate : .newMail(arrivals, unreadCount: unreadCount)
            } catch {
                // Close the brief connection even when the sync itself failed, so
                // nothing lingers open while the app suspends.
                await sync.disconnect()
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
