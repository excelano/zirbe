// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import Foundation

/// Runs `operation`, throwing `MailEngineError.timedOut` if it hasn't finished
/// within `limit`. The caller is released at the deadline even when the
/// operation can't be cancelled, as with a network future that will never
/// complete; the operation is cancelled and left to unwind on its own.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = Outcome<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.continuation = continuation
        let work = Task {
            do {
                outcome.finish(.success(try await operation()))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            work.cancel()
            outcome.finish(.failure(MailEngineError.timedOut))
        }
    }
}

private final class Outcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<T, Error>?

    var continuation: CheckedContinuation<T, Error>? {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    func finish(_ result: Result<T, Error>) {
        let waiting = lock.withLock {
            defer { pending = nil }
            return pending
        }
        waiting?.resume(with: result)
    }
}
