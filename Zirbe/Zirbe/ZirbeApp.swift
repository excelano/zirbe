// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The app entry point. Everything below RootView reads from ZirbeCore's store;
// the network only ever fills that store.

import SwiftUI
import ZirbeCore

@main
struct ZirbeApp: App {
    init() {
        // Become the notification delegate at launch, early enough to catch a tap
        // that woke the app from the lock screen (its thread is buffered until
        // RootView is up to route it).
        NewMailNotifier.shared.registerAsDelegate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // The background poll: iOS wakes the app on its own schedule, we sync the
        // inbox once headless, post a notification for anything new, then queue the
        // next request. Registration of the task identifier is implicit in this
        // modifier; the first request is queued when the inbox backgrounds (see
        // InboxView).
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            if case let .newMail(arrivals, unreadCount) = await BackgroundRefresh.run() {
                await NewMailNotifier.shared.post(arrivals, badgeCount: unreadCount)
            }
            BackgroundRefreshScheduler.schedule()
        }
    }
}
