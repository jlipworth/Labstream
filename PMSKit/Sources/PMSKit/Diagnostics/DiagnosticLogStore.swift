import Foundation

/// Bounded in-memory ring buffer for opt-in diagnostics.
public final class DiagnosticLogStore: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private var enabled: Bool
    private let clock: @Sendable () -> Date

    public init(capacity: Int = 300,
                enabled: Bool = false,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.enabled = enabled
        self.clock = clock
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }

    @discardableResult
    public func record(category: DiagnosticCategory,
                       name: String,
                       fields: [String: DiagnosticFieldValue] = [:]) -> DiagnosticEvent? {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return nil
        }
        let event = DiagnosticEvent(timestamp: clock(), category: category, name: name, fields: fields)
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()
        return event
    }

    public func snapshot(limit: Int? = nil) -> [DiagnosticEvent] {
        lock.lock()
        let current = events
        lock.unlock()
        guard let limit, limit >= 0, current.count > limit else { return current }
        return Array(current.suffix(limit))
    }

    public func clear() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
