import Foundation
import Observation
import Testing

/// Lock-backed test state that can safely be captured by `@Sendable` closures.
final class TestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

/// Deterministic continuation gate for coordinating races without wall-clock sleeps.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Minimal async counter for observing how many times a closure ran.
actor TestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Observe actual transitions on the caller's actor; timeout only bounds a broken test.
@MainActor
func waitForObservedState(_ condition: @escaping @MainActor () -> Bool) async throws {
    let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let timeout = Task {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        events.continuation.finish()
    }
    defer {
        timeout.cancel()
        events.continuation.finish()
    }
    var iterator = events.stream.makeAsyncIterator()
    while !Task.isCancelled {
        let ready = withObservationTracking { condition() } onChange: {
            events.continuation.yield(())
        }
        if ready { return }
        guard await iterator.next() != nil else { break }
    }
    try #require(condition(), "Observed controller state did not transition before outer test guard")
}

/// Monotonic manual nanosecond clock suitable for dependency closures.
final class ManualTestClock: @unchecked Sendable {
    private let state: TestLockedBox<UInt64>

    init(nowNanoseconds: UInt64 = 0) {
        state = TestLockedBox(nowNanoseconds)
    }

    var nowNanoseconds: UInt64 { state.value }

    func advance(byNanoseconds delta: UInt64) {
        state.withValue { value in
            let (next, overflow) = value.addingReportingOverflow(delta)
            precondition(!overflow, "manual test clock overflow")
            value = next
        }
    }

    func advance(toNanoseconds deadline: UInt64) {
        state.withValue { $0 = max($0, deadline) }
    }
}

/// Per-test owner for a `URLProtocol` route. Retain this owner for the life of
/// the URL session; teardown removes only this route, so parallel tests cannot
/// replace one global handler.
final class TestURLProtocolStub: @unchecked Sendable {
    let configuration: URLSessionConfiguration
    private let identifier: String

    init(handler: @escaping TestURLProtocol.Handler) {
        identifier = UUID().uuidString
        TestURLProtocol.register(identifier: identifier, handler: handler)
        configuration = .ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        configuration.httpAdditionalHeaders = [TestURLProtocol.routeHeader: identifier]
    }

    deinit {
        TestURLProtocol.unregister(identifier: identifier)
    }
}

/// Session-scoped `URLProtocol`; use `TestURLProtocolStub` rather than globally
/// registering this class or mutating process-wide protocol state.
final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    fileprivate static let routeHeader = "X-Labstream-Test-Protocol-Route"
    private static let handlers = TestLockedBox<[String: Handler]>([:])

    fileprivate static func register(identifier: String, handler: @escaping Handler) {
        handlers.withValue { $0[identifier] = handler }
    }

    fileprivate static func unregister(identifier: String) {
        handlers.withValue { $0.removeValue(forKey: identifier) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: routeHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let identifier = request.value(forHTTPHeaderField: Self.routeHeader),
              let handler = Self.handlers.value[identifier] else {
            client?.urlProtocol(self, didFailWithError: TestURLProtocolError.missingHandler)
            return
        }
        do {
            var routedRequest = request
            routedRequest.setValue(nil, forHTTPHeaderField: Self.routeHeader)
            let (response, data) = try handler(routedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private enum TestURLProtocolError: Error {
        case missingHandler
    }
}
