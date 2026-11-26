// The proxy findings exercise the Apple-only loopback proxy (Network framework); Linux CI skips
// them with the subsystem (see LoopbackOrigin / #115).
#if canImport(Network)
import Foundation
import Network
import Testing
@testable import PMSKit

/// Orderings the TLA+ model of the playback proxy found on the current design
/// (`specs/playback/proxy/Finding-*.cfg`, `docs/plans/2026-11-25-playback-tla-model.md`).
///
/// Each test states the behaviour the design wants. A test for an open finding is wrapped in
/// `withKnownIssue`, so the suite stays green while the finding is open. When a fix lands the
/// expectations hold, no issue is recorded, and `withKnownIssue` fails the test: delete the
/// wrapper then, and turn the matching `Finding-*.cfg` into a `Faithful-*-off.cfg`.
///
/// Both pins here drive the real `MediaSessionProxy` and `LoopbackOrigin`; no production seam
/// was added. The controller findings (#524-#532, #535) are pinned in
/// `LabstreamTests/PlaybackFormalModelFindingsTests.swift`.
@Suite("Playback formal-model findings (proxy)", .serialized)
struct PlaybackFormalModelFindingsTests {
    /// Proxy-HandlerOutlivesListener (#533). AVPlayer opens a connection to the proxy; Close
    /// stops the proxy; the connection's request head then completes. `LoopbackOrigin.stop()`
    /// only cancels the listener, and the per-connection handler `Task` is untracked, so the
    /// head is still served and the proxy fetches upstream after `stop(generation:)` returned
    /// (`proxy/Finding-HandlerOutlivesListener.cfg`, `NoFetchAfterStop`).
    @Test("#533: a stopped proxy never fetches upstream for a connection accepted before stop")
    func stoppedProxyDoesNotFetchUpstream() async throws {
        let fetches = LockedCount()
        let proxy = MediaSessionProxy(upstreamFetch: { request in
            fetches.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data("#EXTM3U\n".utf8), response)
        })
        let handle = try await proxy.standUpLoopback(
            forStream: try #require(URL(string: "https://upstream.example.invalid/start.m3u8")))
        let port = try #require(handle.localURL.port)

        // The connection is accepted while the proxy is open; its head arrives after stop.
        let client = NWConnection(host: .ipv4(.loopback), port: try #require(NWEndpoint.Port(rawValue: UInt16(port))),
                                  using: .tcp)
        let queue = DispatchQueue(label: "playback-formal-model.client")
        try await Self.waitUntilReady(client, queue: queue)
        defer { client.cancel() }
        // Let the listener hand the accepted connection to its handler.
        try await Task.sleep(for: .milliseconds(200))
        await proxy.stop(generation: handle.generation)
        #expect(await proxy.status().isOpen == false)

        let head = "GET /start.m3u8 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        client.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        // Long enough for the handler to parse the head and run the fetch (loopback is
        // sub-millisecond); the fetch closure above returns immediately.
        try await Task.sleep(for: .milliseconds(750))

        withKnownIssue("TLA+ finding Proxy-HandlerOutlivesListener (#533): a stopped proxy still serves a connection accepted before stop") {
            #expect(fetches.value == 0, "the proxy fetched upstream \(fetches.value) time(s) after stop(generation:) returned")
        }
    }

    /// Proxy-UpstreamSessionNeverInvalidated (#534). `MediaSessionProxy` invalidates only a
    /// rotated-out upstream `URLSession`; stop never invalidates the current one, so every
    /// proxied playback leaves a session (and its delegate) retained until process exit
    /// (`proxy/Finding-UpstreamSessionNeverInvalidated.cfg`, `UpstreamSessionReleased`).
    /// Observed through the production initializer's trust delegate, which URLSession tells
    /// when its session becomes invalid.
    @Test("#534: stopping the proxy invalidates its upstream URLSession")
    func stopInvalidatesUpstreamSession() async throws {
        let delegate = InvalidationObserver()
        let proxy = MediaSessionProxy(trustDelegate: delegate)
        let handle = try await proxy.standUpLoopback(
            forStream: try #require(URL(string: "https://upstream.example.invalid/start.m3u8")))
        await proxy.stop(generation: handle.generation)
        // Invalidation is reported asynchronously on the session's delegate queue.
        for _ in 0..<50 where !delegate.invalidated { try await Task.sleep(for: .milliseconds(20)) }

        withKnownIssue("TLA+ finding Proxy-UpstreamSessionNeverInvalidated (#534): stop leaves the upstream URLSession valid") {
            #expect(delegate.invalidated, "the upstream URLSession was not invalidated by stop(generation:)")
        }
    }

    private static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
        let once = LockedCount()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.increment() == 1 { continuation.resume() }
                case .failed(let error):
                    if once.increment() == 1 { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.increment() == 1 { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

private final class InvalidationObserver: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didInvalidate = false
    var invalidated: Bool { lock.lock(); defer { lock.unlock() }; return didInvalidate }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); didInvalidate = true; lock.unlock()
    }
}
#endif
