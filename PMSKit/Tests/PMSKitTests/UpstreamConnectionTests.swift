import XCTest
@testable import PMSKit

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
