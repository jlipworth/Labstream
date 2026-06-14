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
        let handle = try await proxy.standUpLoopback(forStream: pmsStart)

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
        let handle = try await proxy.standUpLoopback(
            forStream: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        let (_, resp) = try await URLSession(configuration: .ephemeral).data(from: handle.localURL)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let status = await proxy.status()
        XCTAssertEqual(status.rotateCount, 1)
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

    func testOpenResolvesStreamURLWithOffsetAndRunsDecision() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }
        let recorder = ControlRecorder(response: Self.transcodeDecisionJSON)
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: recorder.send(),
                                      now: Clock(0).now)
        let handle = try await proxy.open(sampleRequest(server: origin.baseURL), offsetMs: 600_000)

        // The proxy ran a decision at the 600s offset, and the loopback URL carries it.
        XCTAssertTrue(recorder.urls.contains { $0.absoluteString.contains("offset=600") },
                      "expected a decision call carrying offset=600; got \(recorder.urls)")
        XCTAssertTrue(handle.localURL.absoluteString.contains("offset=600"))
        let decision = await proxy.currentDecision()?.decision
        XCTAssertEqual(decision, .transcode)
        await proxy.stop(generation: handle.generation)
    }

    func testOpenCommitsDirectPlayStartWhenProbeSavesEncode() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }
        let recorder = ControlRecorder(response: Self.directPlayDecisionJSON)
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: recorder.send(),
                                      now: Clock(0).now)
        let handle = try await proxy.open(sampleRequest(server: origin.baseURL, directStream: true),
                                          offsetMs: 0)
        // savesVideoEncode == true → committed to the direct-play start (directPlay=1).
        XCTAssertTrue(handle.localURL.absoluteString.contains("directPlay=1"))
        await proxy.stop(generation: handle.generation)
    }

    func testMediaSessionRequestAndErrorValueSemantics() {
        let id = ClientIdentity(clientIdentifier: "test", product: "VisionPlex",
                                version: "0", deviceName: "test")
        let a = MediaSessionRequest(server: URL(string: "https://example.internal:32400")!,
                                    token: "tkn", identity: id,
                                    metadataKey: "/library/metadata/1",
                                    maxVideoBitrateKbps: 3000, sessionID: "s",
                                    mediaIndex: 0, partIndex: 0,
                                    burnSubtitleStreamID: nil, directStreamEnabled: false)
        let b = a
        XCTAssertEqual(a, b)
        XCTAssertEqual(MediaSessionError.budgetEscalated(recentCount: 3),
                       MediaSessionError.budgetEscalated(recentCount: 3))
        XCTAssertNotEqual(MediaSessionError.notOpen,
                          MediaSessionError.budgetEscalated(recentCount: 1))
    }

    /// A gated control sender that records every call and blocks the FIRST seek-path decision
    /// (the one carrying an `offset=`, not the un-offset open decision and not the stop call),
    /// signalling `reached` once it is blocked. Lets the test pile up later seeks deterministically.
    private func gatedControlSend(recorder: ControlRecorder, block: Gate, reached: Gate)
        -> @Sendable (PlexRequest) async throws -> Data {
        let seekDecisions = Counter()
        return { req in
            _ = try await recorder.send()(req)
            let isStop = req.url.path.hasSuffix("/universal/stop")
            let isSeekDecision = !isStop && req.url.absoluteString.contains("offset=")
            if isSeekDecision, seekDecisions.increment() == 1 {
                reached.open()
                await block.wait()
            }
            return Self.transcodeDecisionJSON
        }
    }

    func testSeekCoalescesToLatestAndDropsIntermediate() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }
        let recorder = ControlRecorder(response: Self.transcodeDecisionJSON)
        let block = Gate(), reached = Gate()
        // autoAdvance 3s/read: the two coalesced re-primes run back-to-back inside the proxy's
        // loop with no point for the test to advance a manual clock between them, so each read
        // steps past the 2s re-prime cooldown — keeping the budget out of this coalescing test.
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: gatedControlSend(recorder: recorder, block: block, reached: reached),
                                      now: Clock(0, autoAdvance: 3).now)
        let opened = try await proxy.open(sampleRequest(server: origin.baseURL), offsetMs: 0)

        // Fire the first seek; it blocks at its decision.
        async let h1 = proxy.seek(to: 60_000)     // o1 = 60s — in-flight, gated
        await reached.wait()
        // Pile up two more while o1 is blocked; o3 wins, o2 is dropped. Sequence the two
        // enqueues deterministically — `async let` gives no actor-hop ordering guarantee, so we
        // wait for o2 to register as the pending target before firing o3 (which then overwrites
        // it). The re-prime loop is parked at the gate and can't drain `pending` meanwhile.
        async let h2 = proxy.seek(to: 120_000)    // o2 = 120s — dropped
        while await proxy.pendingOffsetMsForTest() != 120_000 { await Task.yield() }
        async let h3 = proxy.seek(to: 180_000)    // o3 = 180s — latest
        while await proxy.pendingOffsetMsForTest() != 180_000 { await Task.yield() }
        block.open()

        let r1 = try await h1, r2 = try await h2, r3 = try await h3
        // Every coalesced caller gets the final (o3) handle.
        XCTAssertEqual(r1, r3)
        XCTAssertEqual(r2, r3)
        XCTAssertTrue(r3.localURL.absoluteString.contains("offset=180"))
        XCTAssertTrue(r3.generation > opened.generation)
        // o2 (120s) was never re-primed.
        XCTAssertFalse(recorder.urls.contains { $0.absoluteString.contains("offset=120") },
                       "intermediate offset=120 should have been dropped; got \(recorder.urls)")
        await proxy.stop(generation: r3.generation)
    }

    func testSeekStopsPreviousTranscodeBeforeRepriming() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }
        let recorder = ControlRecorder(response: Self.transcodeDecisionJSON)
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: recorder.send(),
                                      now: Clock(0).now)
        let opened = try await proxy.open(sampleRequest(server: origin.baseURL), offsetMs: 0)
        let handle = try await proxy.seek(to: 90_000)
        let urls = recorder.urls
        let stopIdx = urls.firstIndex { $0.path.hasSuffix("/universal/stop") }
        let reprimeDecisionIdx = urls.lastIndex { $0.absoluteString.contains("offset=90") }
        XCTAssertNotNil(stopIdx, "expected a /universal/stop call on the re-prime path")
        XCTAssertNotNil(reprimeDecisionIdx)
        XCTAssertLessThan(stopIdx!, reprimeDecisionIdx!, "stop must precede the re-prime decision")
        XCTAssertTrue(handle.generation > opened.generation)
        await proxy.stop(generation: handle.generation)
    }

    func testSeekEscalatesWhenReprimeBudgetExhausted() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }
        let recorder = ControlRecorder(response: Self.transcodeDecisionJSON)
        let clock = Clock(0)
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: recorder.send(),
                                      now: clock.now)
        _ = try await proxy.open(sampleRequest(server: origin.baseURL), offsetMs: 0)
        // budget: cooldown 2s, burstLimit 5, window 60s → 5 allowed, 6th escalates.
        for i in 1...5 {
            clock.advance(3)                         // clear the cooldown each time
            _ = try await proxy.seek(to: i * 60_000)
        }
        clock.advance(3)
        do {
            _ = try await proxy.seek(to: 600_000)
            XCTFail("expected budgetEscalated")
        } catch let MediaSessionError.budgetEscalated(recentCount) {
            XCTAssertEqual(recentCount, 5)
        }
    }
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

extension MediaSessionProxyTests {
    /// A transcode (general 1001) decision body.
    static let transcodeDecisionJSON =
        Data(#"{"MediaContainer":{"generalDecisionCode":1001,"generalDecisionText":"Transcode"}}"#.utf8)
    /// A direct-play (MDE 1000) decision body — `savesVideoEncode` is true.
    static let directPlayDecisionJSON =
        Data(#"{"MediaContainer":{"mdeDecisionCode":1000,"mdeDecisionText":"Direct play OK"}}"#.utf8)

    func sampleRequest(server: URL, directStream: Bool = false) -> MediaSessionRequest {
        MediaSessionRequest(
            server: server, token: "tkn",
            identity: ClientIdentity(clientIdentifier: "test", product: "VisionPlex",
                                     version: "0", deviceName: "test"),
            metadataKey: "/library/metadata/1", maxVideoBitrateKbps: 3000,
            sessionID: "sess", mediaIndex: 0, partIndex: 0,
            burnSubtitleStreamID: nil, directStreamEnabled: directStream)
    }
}

/// Monotonic injectable clock for the proxy's `now` seam (budget escalation determinism).
/// `autoAdvance` (default 0 = off) bumps the clock by that many seconds AFTER each read, so a
/// test whose re-primes run back-to-back inside the proxy's own loop — with no test-side
/// synchronization point to `advance()` between them — still clears the re-prime cooldown each
/// iteration (see `testSeekCoalescesToLatestAndDropsIntermediate`).
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    private let step: TimeInterval
    init(_ start: TimeInterval = 0, autoAdvance step: TimeInterval = 0) { t = start; self.step = step }
    func advance(_ d: TimeInterval) { lock.lock(); t += d; lock.unlock() }
    var now: @Sendable () -> TimeInterval {
        { [self] in lock.lock(); defer { lock.unlock() }; let v = t; t += step; return v }
    }
}

/// Records the control-plane requests the proxy sends and returns a canned decision body.
final class ControlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URL] = []
    private let response: Data
    init(response: Data) { self.response = response }
    private func record(_ url: URL) { lock.lock(); sent.append(url); lock.unlock() }
    func send() -> @Sendable (PlexRequest) async throws -> Data {
        { [self] req in record(req.url); return response }
    }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return sent }
}

/// One-shot async gate: callers `await wait()`; `open()` releases all waiters and makes
/// subsequent waits pass through.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            waiters.append(c); lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let ws = waiters; waiters = []; lock.unlock()
        ws.forEach { $0.resume() }
    }
}
