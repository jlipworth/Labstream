// Integration tests for the Apple-only loopback proxy (#33). Gated with the subsystem so the
// Linux CI fleet skips them and still runs the Foundation-only suites (incl. redaction).
#if canImport(Network)
import XCTest
import Network
@testable import PMSKit

/// Ephemeral session with explicit short timeouts so a wedged loopback accept fails fast (a clear
/// per-request timeout) instead of blocking until the suite-level timeout if these socket tests
/// ever run under heavy parallel execution. Loopback is sub-millisecond normally, so 10s is ample.
private func loopbackTestSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 10
    cfg.timeoutIntervalForResource = 15
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
}

final class MediaSessionProxyTests: XCTestCase {
    func testForwardsPlaylistRequestThroughLoopback() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }

        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher())
        let pmsStart = URL(string: "http://127.0.0.1:\(origin.port)/video/:/transcode/universal/start.m3u8?session=abc")!
        let handle = try await proxy.standUpLoopback(forStream: pmsStart)

        XCTAssertEqual(handle.localURL.host, "127.0.0.1")
        XCTAssertTrue(handle.localURL.path.hasSuffix("/start.m3u8"))

        let (data, resp) = try await loopbackTestSession().data(from: handle.localURL)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U"))
        await proxy.stop(generation: handle.generation)
    }

    func testTransparentlyRecoversFromWedgedFirstRequest() async throws {
        // First fetch wedges; the proxy must rotate and the retry must succeed —
        // surfaced as rotateCount == 1 and a 200 to the client.
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\n".utf8))
        }
        defer { origin.stop() }

        let realFetch = origin.fetcher()
        let attempts = Counter()
        let wedgingFetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { req in
            if attempts.increment() == 1 { throw URLError(.timedOut) }  // first socket wedged
            return try await realFetch(req)
        }
        let proxy = MediaSessionProxy(upstreamFetch: wedgingFetch)
        let handle = try await proxy.standUpLoopback(
            forStream: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        let (_, resp) = try await loopbackTestSession().data(from: handle.localURL)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let status = await proxy.status()
        XCTAssertEqual(status.rotateCount, 1)
        await proxy.stop(generation: handle.generation)
    }

    func testInjectedClockControlsUpstreamRestartCooldown() async throws {
        let clock = TestClock(now: 100)
        let attempts = URLAttemptCounter()
        let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            if attempts.increment(for: request.url!) == 1 {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
            return (Data("#EXTM3U\n".utf8), response)
        }
        let proxy = MediaSessionProxy(upstreamFetch: fetch, now: { clock.value })
        let handle = try await proxy.standUpLoopback(
            forStream: URL(string: "http://example.com/start.m3u8")!)

        let first = try await responseStatus(for: handle.localURL, requestID: "first")
        XCTAssertEqual(first, 200)
        var status = await proxy.status()
        XCTAssertEqual(status.rotateCount, 1)

        // With no synthetic time elapsed, the second wedge is inside the five-second
        // cooldown and must surface instead of rotating the upstream again.
        let deferred = try await responseStatus(for: handle.localURL, requestID: "deferred")
        XCTAssertEqual(deferred, 502)
        status = await proxy.status()
        XCTAssertEqual(status.rotateCount, 1)

        clock.advance(by: 5)
        let afterCooldown = try await responseStatus(for: handle.localURL, requestID: "after-cooldown")
        XCTAssertEqual(afterCooldown, 200)
        status = await proxy.status()
        XCTAssertEqual(status.rotateCount, 2)
        await proxy.stop(generation: handle.generation)
    }

    func testStaleStopIsIgnored() async throws {
        let origin = try await StubOrigin.start { _ in (200, "text/plain", Data()) }
        defer { origin.stop() }
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher())
        let opened = try await proxy.standUpLoopback(forStream: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        await proxy.stop(generation: opened.generation - 1)   // stale teardown: must be a no-op
        let status = await proxy.status()
        XCTAssertTrue(status.isOpen)
        await proxy.stop(generation: opened.generation)
    }

    func testRewritesAbsolutePlaylistURLsAndStripsConfiguredQueryItems() async throws {
        let origin = try await StubOrigin.start { head in
            if head.target.hasSuffix("/start.m3u8") {
                let playlist = """
                #EXTM3U
                http://127.0.0.1:\(head.value(for: "Host")?.split(separator: ":").last ?? "0")/video/segment0.ts?api_key=secret&startTimeTicks=123&keep=1
                relative.ts?startTimeTicks=123&keep=2
                """
                return (200, "application/vnd.apple.mpegurl", Data(playlist.utf8))
            }
            return (200, "video/MP2T", Data("segment".utf8))
        }
        defer { origin.stop() }

        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      strippedPlaylistQueryItemNames: ["api_key", "startTimeTicks"])
        let pmsStart = URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!
        let handle = try await proxy.standUpLoopback(forStream: pmsStart)

        let (data, resp) = try await loopbackTestSession().data(from: handle.localURL)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let playlist = String(decoding: data, as: UTF8.self)
        let loopbackBase = "http://\(handle.localURL.host!):\(handle.localURL.port!)"
        XCTAssertTrue(playlist.contains(loopbackBase + "/video/segment0.ts?keep=1"), playlist)
        XCTAssertTrue(playlist.contains("relative.ts?keep=2"), playlist)
        XCTAssertFalse(playlist.contains("api_key="), playlist)
        XCTAssertFalse(playlist.lowercased().contains("starttimeticks="), playlist)
        XCTAssertFalse(playlist.contains("http://127.0.0.1:\(origin.port)/video/segment0.ts"), playlist)
        await proxy.stop(generation: handle.generation)
    }

    func testMediaSessionHandleAndStatusValueSemantics() {
        let url = URL(string: "http://127.0.0.1:1234/start.m3u8")!
        XCTAssertEqual(MediaSessionHandle(localURL: url, generation: 2),
                       MediaSessionHandle(localURL: url, generation: 2))
        XCTAssertEqual(MediaSessionStatus(generation: 2, isOpen: true, rotateCount: 1),
                       MediaSessionStatus(generation: 2, isOpen: true, rotateCount: 1))
    }

}

private func responseStatus(for baseURL: URL, requestID: String) async throws -> Int? {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "request", value: requestID)]
    var request = URLRequest(url: components.url!)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (_, response) = try await loopbackTestSession().data(for: request)
    return (response as? HTTPURLResponse)?.statusCode
}

/// In-test PMS stand-in: an NWListener that answers each request via a closure.
final class StubOrigin: @unchecked Sendable {
    private let origin = LoopbackOrigin()
    private(set) var port = 0
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    typealias Respond = @Sendable (HTTPRequestHead) -> (status: Int, contentType: String, body: Data)

    static func start(_ respond: @escaping Respond) async throws -> StubOrigin {
        let s = StubOrigin()
        s.port = try await s.origin.start { head in
            let (status, ct, body) = respond(head)
            return HTTPResponse(status: status, reason: "OK",
                                headers: [("Content-Type", ct)], body: body)
        }
        return s
    }

    func stop() { origin.stop() }

    /// A fetcher the proxy can use as its upstream: a plain URLSession hitting this origin.
    func fetcher() -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { req in
            let (data, resp) = try await loopbackTestSession().data(for: req)
            return (data, resp as! HTTPURLResponse)
        }
    }
}

/// Thread-safe call counter for closures that run off the actor (Swift 6 forbids capturing a
/// mutable `var` in a `@Sendable` closure).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int { lock.lock(); count += 1; let n = count; lock.unlock(); return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class URLAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]

    func increment(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counts[url, default: 0] += 1
        return counts[url]!
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now += interval
        lock.unlock()
    }
}
#endif
