import XCTest
@testable import PMSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class UpstreamConnectionTests: XCTestCase {
    // Wedge-class error used to simulate a poisoned socket.
    private let wedge = URLError(.timedOut)

    func testRetriesOnceAfterRotateOnWedge() async throws {
        let attempts = Counter()
        let rebuilds = Counter()
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 3, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: { rebuilds.increment() },
            fetch: { [wedge] _ in
                let n = attempts.increment()
                if n == 1 { throw wedge }                   // first socket wedged
                return (Data("ok".utf8), Self.http(200))    // fresh socket succeeds
            })
        let (data, resp) = try await conn.send(URLRequest(url: URL(string: "https://x/")!))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(rebuilds.value, 1)
        let count = await conn.rotateCount
        XCTAssertEqual(count, 1)
    }

    func testDoesNotRotateWhenRequestSucceeds() async throws {
        let rebuilds = Counter()
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 3, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: { rebuilds.increment() },
            fetch: { _ in (Data("ok".utf8), Self.http(200)) })
        _ = try await conn.send(URLRequest(url: URL(string: "https://x/")!))
        XCTAssertEqual(rebuilds.value, 0)
        let count = await conn.rotateCount
        XCTAssertEqual(count, 0)
    }

    func testRethrowsWhenBudgetEscalates() async {
        // burstLimit 0 → first rotate request escalates immediately, error rethrown.
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 0, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: {},
            fetch: { [wedge] _ in throw wedge })
        do {
            _ = try await conn.send(URLRequest(url: URL(string: "https://x/")!))
            XCTFail("expected throw")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStaleSiblingFailureRetriesCurrentGenerationWithoutRotatingIt() async throws {
        let gate = StaleFailureGate()
        let rebuilds = Counter()
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 3, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: { rebuilds.increment() },
            fetch: { request in
                let id = request.url!.lastPathComponent
                let attempt = gate.beginAttempt(for: id)
                if attempt == 1 {
                    await gate.waitForRelease(of: id)
                    throw URLError(id == "sibling" ? .cancelled : .timedOut)
                }
                return (Data(id.utf8), Self.http(200))
            })

        let first = Task {
            try await conn.send(URLRequest(url: URL(string: "https://x/first")!))
        }
        let sibling = Task {
            try await conn.send(URLRequest(url: URL(string: "https://x/sibling")!))
        }
        await gate.waitUntilInitialAttemptsStarted(2)

        gate.release("first")
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.0, Data("first".utf8))

        // This cancellation belongs to the now-draining generation. It gets one retry on the session
        // created above, but cannot spend restart budget or rotate that healthy new generation.
        gate.release("sibling")
        let siblingResult = try await sibling.value
        XCTAssertEqual(siblingResult.0, Data("sibling".utf8))
        XCTAssertEqual(rebuilds.value, 1)
        let count = await conn.rotateCount
        XCTAssertEqual(count, 1)
    }

    private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// Thread-safe call counter for the injected closures (they run off the actor).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int { lock.lock(); count += 1; let n = count; lock.unlock(); return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class StaleFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [String: Int] = [:]
    private var released: Set<String> = []
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func beginAttempt(for id: String) -> Int {
        lock.lock()
        attempts[id, default: 0] += 1
        let attempt = attempts[id]!
        let initialCount = attempts.values.filter { $0 >= 1 }.count
        let ready = startedWaiters.filter { initialCount >= $0.count }
        startedWaiters.removeAll { initialCount >= $0.count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
        return attempt
    }

    func waitUntilInitialAttemptsStarted(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let initialCount = attempts.values.filter { $0 >= 1 }.count
            if initialCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                startedWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func waitForRelease(of id: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released.contains(id) {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiters[id, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    func release(_ id: String) {
        lock.lock()
        released.insert(id)
        let waiters = releaseWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}
