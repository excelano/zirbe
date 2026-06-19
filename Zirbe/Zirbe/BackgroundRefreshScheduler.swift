// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Submits the next background app-refresh request to iOS. Scheduling is a
// request, never a guarantee: iOS decides whether and when to actually wake the
// app, weighing battery, usage patterns, and its own budget. Only one
// app-refresh request is ever queued at a time, so a fresh submit replaces any
// pending one. Paired with the app's `.backgroundTask(.appRefresh:)` handler,
// which runs `BackgroundRefresh.run()` and then reschedules.

import BackgroundTasks
import ZirbeCore

/// Queues the next background inbox poll with the system scheduler.
enum BackgroundRefreshScheduler {
    /// Ask iOS to wake the app for a refresh no sooner than this far out. The
    /// system clamps and defers to its own budget regardless, so this is a floor,
    /// not a promise.
    private static let earliestInterval: TimeInterval = 15 * 60

    /// Submit a refresh request. Failures (the simulator, which doesn't grant
    /// background tasks, or a system that's declined) are swallowed: a poll that
    /// never runs is covered by the foreground sync on reopen.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        try? BGTaskScheduler.shared.submit(request)
    }
}
