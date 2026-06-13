import XCTest
import Network
@testable import PMSKit

final class MediaSessionProxyTests: XCTestCase {
    func testForwardsPlaylistRequestThroughLoopback() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }

        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher())
        let pmsStart = URL(string: "http://127.0.0.1:\(origin.port)/video/:/transcode/universal/start.m3u8?session=abc")!
        let handle = try await proxy.open(origin: pmsStart)

        // The local URL must point at the loopback origin and carry the PMS path+query.
        XCTAssertEqual(handle.localURL.host, "127.0.0.1")
        XCTAssertTrue(handle.localURL.path.hasSuffix("/start.m3u8"))

        let (data, resp) = try await URLSession(configuration: .ephemeral).data(from: handle.localURL)
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
        let handle = try await proxy.open(
            origin: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        let (_, resp) = try await URLSession(configuration: .ephemeral).data(from: handle.localURL)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let status = await proxy.status()
        XCTAssertEqual(status.rotateCount, 1)
        await proxy.stop(generation: handle.generation)
    }

    func testSeekIsPassThroughInStage1() async throws {
        let origin = try await StubOrigin.start { _ in (200, "text/plain", Data()) }
        defer { origin.stop() }
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher())
        let opened = try await proxy.open(origin: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        let sought = try await proxy.seek(to: 120_000)
        XCTAssertEqual(sought, opened)   // same handle, same generation
        await proxy.stop(generation: opened.generation)
    }

    func testStaleStopIsIgnored() async throws {
        let origin = try await StubOrigin.start { _ in (200, "text/plain", Data()) }
        defer { origin.stop() }
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher())
        let opened = try await proxy.open(origin: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        await proxy.stop(generation: opened.generation - 1)   // stale teardown: must be a no-op
        let status = await proxy.status()
        XCTAssertTrue(status.isOpen)
        await proxy.stop(generation: opened.generation)
    }
}

/// In-test PMS stand-in: an NWListener that answers each request via a closure.
final class StubOrigin: @unchecked Sendable {
    private let origin = LoopbackOrigin()
    private(set) var port = 0
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
            let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
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
