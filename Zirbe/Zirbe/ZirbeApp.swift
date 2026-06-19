// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The app entry point. Everything below RootView reads from ZirbeCore's store;
// the network only ever fills that store.

import SwiftUI
import ZirbeCore

@main
struct ZirbeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // The background poll: iOS wakes the app on its own schedule, we sync the
        // inbox once headless, then queue the next request. Registration of the
        // task identifier is implicit in this modifier; the first request is
        // queued when the inbox backgrounds (see InboxView).
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await BackgroundRefresh.run()
            BackgroundRefreshScheduler.schedule()
        }
    }
}
