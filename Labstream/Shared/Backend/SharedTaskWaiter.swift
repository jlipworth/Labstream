import Foundation

/// Lock-backed because a task cancellation handler is not actor-isolated and may race installing
/// the continuation. Exactly one outcome wins; later shared-task completion is ignored.
final class SharedTaskWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: sending Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
