// Integration tests for the Apple-only loopback proxy (#33). Gated with the subsystem so the
// Linux CI fleet skips them and still runs the Foundation-only suites (incl. redaction).
#if canImport(Network)
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
                                      controlSend: recorder.send())
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
                                      controlSend: recorder.send())
        let handle = try await proxy.open(sampleRequest(server: origin.baseURL, directStream: true),
                                          offsetMs: 0)
        // savesVideoEncode == true → committed to the direct-play start (directPlay=1).
        XCTAssertTrue(handle.localURL.absoluteString.contains("directPlay=1"))
        XCTAssertTrue(recorder.urls.contains { url in
            url.path == "/video/:/transcode/universal/start.m3u8"
            && url.absoluteString.contains("directPlay=1")
        }, "expected a direct-play start preflight before commit; got \(recorder.urls)")
        await proxy.stop(generation: handle.generation)
    }

    func testOpenFallsBackWhenDirectPlayStartPreflightFails() async throws {
        let origin = try await StubOrigin.start { _ in
            (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\nindex.m3u8\n".utf8))
        }
        defer { origin.stop() }
        let recorder = ControlRecorder(response: Self.directPlayDecisionJSON) { req in
            if req.url.path == "/video/:/transcode/universal/start.m3u8" {
                throw URLError(.badServerResponse)
            }
        }
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: recorder.send())
        let handle = try await proxy.open(sampleRequest(server: origin.baseURL, directStream: true),
                                          offsetMs: 0)
        XCTAssertFalse(handle.localURL.absoluteString.contains("directPlay=1"))
        XCTAssertTrue(handle.localURL.absoluteString.contains("directPlay=0"))
        await proxy.stop(generation: handle.generation)
    }

    func testMediaSessionRequestAndErrorValueSemantics() {
        let id = ClientIdentity(clientIdentifier: "test", product: "VisionPlay",
                                version: "0", deviceName: "test")
        let a = MediaSessionRequest(server: URL(string: "https://example.internal:32400")!,
                                    token: "tkn", identity: id,
                                    metadataKey: "/library/metadata/1",
                                    maxVideoBitrateKbps: 3000, sessionID: "s",
                                    mediaIndex: 0, partIndex: 0,
                                    burnSubtitleStreamID: nil, directStreamEnabled: false)
        let b = a
        XCTAssertEqual(a, b)
        let directURL = URL(string: "https://example.internal/start.m3u8")!
        XCTAssertEqual(MediaSessionError.loopbackUnavailable(directURL: directURL),
                       MediaSessionError.loopbackUnavailable(directURL: directURL))
        XCTAssertNotEqual(MediaSessionError.notOpen,
                          MediaSessionError.loopbackUnavailable(directURL: directURL))
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
            identity: ClientIdentity(clientIdentifier: "test", product: "VisionPlay",
                                     version: "0", deviceName: "test"),
            metadataKey: "/library/metadata/1", maxVideoBitrateKbps: 3000,
            sessionID: "sess", mediaIndex: 0, partIndex: 0,
            burnSubtitleStreamID: nil, directStreamEnabled: directStream)
    }
}

/// Records the control-plane requests the proxy sends and returns a canned decision body.
final class ControlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URL] = []
    private let response: Data
    private let beforeRespond: (@Sendable (PlexRequest) async throws -> Void)?
    init(response: Data,
         beforeRespond: (@Sendable (PlexRequest) async throws -> Void)? = nil) {
        self.response = response
        self.beforeRespond = beforeRespond
    }
    private func record(_ url: URL) { lock.lock(); sent.append(url); lock.unlock() }
    func send() -> @Sendable (PlexRequest) async throws -> Data {
        { [self] req in
            record(req.url)
            try await beforeRespond?(req)
            return response
        }
    }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return sent }
}
#endif
