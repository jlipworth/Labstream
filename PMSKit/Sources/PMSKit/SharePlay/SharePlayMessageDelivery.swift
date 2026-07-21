import Foundation

/// Serializes asynchronous message sends without making callers build independent unstructured
/// task chains. Every outstanding link is retained so teardown can cancel both the current send and
/// queued successors, rather than cancelling only the newest tail.
@MainActor
public final class SharePlayOrderedDeliveryTail {
    private var tail: Task<Void, Never>?
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskID: UInt64 = 0

    public init() {}

    public func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        nextTaskID &+= 1
        let taskID = nextTaskID
        let task = Task { @MainActor [weak self] in
            defer { self?.tasks[taskID] = nil }
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        tasks[taskID] = task
    }

    public func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        tail = nil
    }

    /// Deterministic cancellation gate for policy tests and non-UI owners that can suspend.
    /// Do not call this from one of this tail's own operations; it would await itself.
    public func cancelAllAndDrain() async {
        let pending = Array(tasks.values)
        cancelAll()
        for task in pending { await task.value }
    }

    public func drain() async {
        await tail?.value
    }
}

/// Runs a bounded fallback independently of a delivery tail that may be suspended in transport.
@MainActor
public final class SharePlayBoundedFallback {
    private var task: Task<Void, Never>?

    public init() {}

    public func schedule(after delay: Duration,
                         _ operation: @escaping @MainActor () async -> Void) {
        cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    public func drain() async {
        await task?.value
    }
}
