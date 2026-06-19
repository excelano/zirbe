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
    /// Returns whether a sync completed, so the caller can report task success to
    /// the scheduler.
    @discardableResult
    public static func run() async -> Bool {
        do {
            let store = try MailStore(path: StoreLocation.databasePath())
            guard let account = try await store.accounts().first,
                  let password = try KeychainStore.password(for: account.id) else {
                return false
            }
            let sync = SyncService(account: account, store: store)
            do {
                try await sync.syncInbox(password: password)
                await sync.disconnect()
                return true
            } catch {
                // Close the brief connection even when the sync itself failed, so
                // nothing lingers open while the app suspends.
                await sync.disconnect()
                return false
            }
        } catch {
            return false
        }
    }
}
