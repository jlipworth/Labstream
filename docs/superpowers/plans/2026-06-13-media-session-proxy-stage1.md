# Media Session Proxy — Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Stage 1 `MediaSessionProxy` in PMSKit — an app-owned loopback HTTP origin between AVKit and PMS that makes the media plane recoverable (transparent upstream-socket auto-rotate, #33) without changing seek behavior — and wire it into `PlaybackController`.

**Architecture:** A loopback `NWListener` on `127.0.0.1:0` accepts AVKit's HLS requests, forwards each to PMS over an app-owned ephemeral `URLSession`, rewrites any absolute PMS URLs in playlists back to the loopback base, and rotates the upstream socket once (budget-bounded) when a request wedges past a generous time-to-first-byte deadline. Pure units (HTTP head parsing, URL mapping, playlist rewrite) are unit-tested with no network; the forwarding/rotate path is tested against an in-test stub origin.

**Tech Stack:** Swift, `Network.framework` (`NWListener`/`NWConnection`), `Foundation.URLSession`, `swift test` (XCTest). Reuses `SeekRestartBudget` and `PlexSessionConfiguration` from PMSKit.

**Spec:** `docs/superpowers/specs/2026-06-13-media-session-proxy-design.md`

---

## File structure

All new code lives in a new `MediaSession/` group under PMSKit (request building, sessions, and the budget already live in PMSKit; `Network.framework` is cross-platform so tests run on the macOS host).

- Create `PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift` — contract value types (`MediaSessionHandle`, `MediaSessionStatus`).
- Create `PMSKit/Sources/PMSKit/MediaSession/HTTPMessage.swift` — pure HTTP/1.1 request-head parser + response serializer.
- Create `PMSKit/Sources/PMSKit/MediaSession/UpstreamURLMapper.swift` — pure loopback-target → PMS-URL mapping.
- Create `PMSKit/Sources/PMSKit/MediaSession/PlaylistRewriter.swift` — pure absolute-URL → loopback rewrite safety net.
- Create `PMSKit/Sources/PMSKit/MediaSession/UpstreamConnection.swift` — app-owned `URLSession` wrapper with budget-bounded rotate-and-retry.
- Create `PMSKit/Sources/PMSKit/MediaSession/LoopbackOrigin.swift` — `NWListener` HTTP/1.1 origin (one request per connection, `Connection: close`).
- Create `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift` — the actor that assembles the above behind `open / seek / stop / status`.
- Modify `PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift` — add `mediaUpstream(timeout:)` factory.
- Create tests: `HTTPMessageTests.swift`, `UpstreamURLMapperTests.swift`, `PlaylistRewriterTests.swift`, `UpstreamConnectionTests.swift`, `MediaSessionProxyTests.swift` (+ a `StubOrigin` test helper) under `PMSKit/Tests/PMSKitTests/`.
- Modify `PlexAVPApp/Player/PlaybackController.swift` — route `AVURLAsset` through the proxy URL; tear the proxy down on stop.

**Stage-1 scoping note (intentional, consistent with the spec):** Stage 1's `open(origin:)` takes the already-resolved PMS `start.m3u8` URL that `PlaybackController` already computes from its Direct Stream probe + decision. Migrating the decision/probe build *into* the proxy, and making `seek` re-prime, are Stage 2 — out of scope here. `seek(to:)` is a pass-through that returns the current handle.

---

## Task 1: Contract value types

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift`

- [ ] **Step 1: Write the types**

```swift
import Foundation

/// What `MediaSessionProxy.open`/`seek` hand back to the renderer. No AVFoundation types
/// cross this boundary — the player just consumes `localURL`.
public struct MediaSessionHandle: Sendable, Equatable {
    /// The loopback URL to hand to `AVURLAsset`. e.g. `http://127.0.0.1:51234/video/:/...`.
    public let localURL: URL
    /// Identifies this logical stream. Bumps on each `open`; `stop(generation:)` is a no-op
    /// for a stale generation so a late teardown can't kill a newer session.
    public let generation: Int

    public init(localURL: URL, generation: Int) {
        self.localURL = localURL
        self.generation = generation
    }
}

/// Observable session state for UI/diagnostics/tests. No AVFoundation leakage.
public struct MediaSessionStatus: Sendable, Equatable {
    public let generation: Int
    public let isOpen: Bool
    /// How many times the upstream socket has been rotated this session (#33 recovery count).
    public let rotateCount: Int

    public init(generation: Int, isOpen: Bool, rotateCount: Int) {
        self.generation = generation
        self.isOpen = isOpen
        self.rotateCount = rotateCount
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd PMSKit && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift
git commit -m "MediaSessionProxy: contract value types (#33)"
```

---

## Task 2: HTTP/1.1 request-head parser + response serializer (pure)

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/HTTPMessage.swift`
- Test: `PMSKit/Tests/PMSKitTests/HTTPMessageTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PMSKit

final class HTTPMessageTests: XCTestCase {
    func testParsesRequestLineAndHeaders() {
        let raw = "GET /video/index.m3u8?session=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\n\r\n"
        let parsed = HTTPRequestHead.parse(Data(raw.utf8))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.head.method, "GET")
        XCTAssertEqual(parsed?.head.target, "/video/index.m3u8?session=abc")
        XCTAssertEqual(parsed?.head.value(for: "range"), "bytes=0-99") // case-insensitive
        XCTAssertEqual(parsed?.head.value(for: "Host"), "127.0.0.1")
    }

    func testReturnsNilWhenHeadIncomplete() {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n" // no terminating blank line
        XCTAssertNil(HTTPRequestHead.parse(Data(raw.utf8)))
    }

    func testReportsHeadByteCountSoBodyCanBeSplitOff() {
        let raw = "GET / HTTP/1.1\r\n\r\nLEFTOVER"
        let parsed = HTTPRequestHead.parse(Data(raw.utf8))
        XCTAssertEqual(parsed?.headByteCount, raw.count - "LEFTOVER".count)
    }

    func testSerializesResponseWithConnectionClose() {
        let resp = HTTPResponse(status: 200,
                                reason: "OK",
                                headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                                body: Data("#EXTM3U".utf8))
        let bytes = resp.serialized()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/vnd.apple.mpegurl\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n#EXTM3U"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test --filter HTTPMessageTests`
Expected: FAIL — `HTTPRequestHead` / `HTTPResponse` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A parsed HTTP/1.1 request head (everything up to and including the blank line).
/// Pure and allocation-light: parsing is just a scan for the CRLFCRLF terminator and a
/// split of the lines above it. We only ever receive GET requests from AVKit (HLS), so
/// there is no request body to read.
struct HTTPRequestHead: Equatable {
    var method: String
    /// The request-target as sent, e.g. `/video/:/transcode/universal/index.m3u8?session=…`.
    var target: String
    var headers: [(name: String, value: String)]

    static func == (lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target
            && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
    }

    /// Case-insensitive header lookup (first match).
    func value(for name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Parse a request head from `data`. Returns nil if the terminating blank line
    /// (`\r\n\r\n`) has not arrived yet, so the caller knows to read more.
    /// `headByteCount` is the number of bytes consumed by the head, so any trailing
    /// bytes already read can be split off.
    static func parse(_ data: Data) -> (head: HTTPRequestHead, headByteCount: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }
        let headBytes = data[data.startIndex..<range.lowerBound]
        guard let headText = String(data: headBytes, encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let head = HTTPRequestHead(method: parts[0], target: parts[1], headers: headers)
        return (head, range.upperBound - data.startIndex)
    }
}

/// A response to serialize back to AVKit. We always close the connection after one
/// response (`Connection: close`) — one request per connection keeps the loopback origin
/// trivial. Keep-alive is a later refinement, not needed for correctness.
struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [(name: String, value: String)]
    var body: Data

    init(status: Int, reason: String, headers: [(name: String, value: String)], body: Data) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        // Drop any upstream framing headers we are about to set ourselves.
        for (name, value) in headers
        where !["content-length", "connection", "transfer-encoding"].contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd PMSKit && swift test --filter HTTPMessageTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/HTTPMessage.swift PMSKit/Tests/PMSKitTests/HTTPMessageTests.swift
git commit -m "MediaSessionProxy: HTTP/1.1 request-head parser + response serializer (#33)"
```

---

## Task 3: Loopback-target → PMS-URL mapping (pure)

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/UpstreamURLMapper.swift`
- Test: `PMSKit/Tests/PMSKitTests/UpstreamURLMapperTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PMSKit

final class UpstreamURLMapperTests: XCTestCase {
    let mapper = UpstreamURLMapper(upstreamBase: URL(string: "https://pms.example:32400")!)

    func testMapsTargetOntoUpstreamSchemeHostPort() {
        let url = mapper.upstreamURL(forTarget: "/video/:/transcode/universal/index.m3u8?session=abc")
        XCTAssertEqual(url?.absoluteString,
                       "https://pms.example:32400/video/:/transcode/universal/index.m3u8?session=abc")
    }

    func testPreservesPercentEncodingInTarget() {
        let url = mapper.upstreamURL(forTarget: "/a%20b/seg.ts?x=%3D")
        XCTAssertEqual(url?.absoluteString, "https://pms.example:32400/a%20b/seg.ts?x=%3D")
    }

    func testRejectsTargetWithoutLeadingSlash() {
        XCTAssertNil(mapper.upstreamURL(forTarget: "video/index.m3u8"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test --filter UpstreamURLMapperTests`
Expected: FAIL — `UpstreamURLMapper` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Maps a loopback request-target back onto the PMS origin. Because PMS emits *relative*
/// playlist/segment URIs and `AVURLAsset` resolves them against the loopback base, every
/// request-target AVKit sends is already a valid PMS path+query — so mapping is a pure
/// origin swap (scheme/host/port), preserving the target's existing percent-encoding.
struct UpstreamURLMapper {
    /// PMS origin: scheme + host + port only (no path/query). Derive with
    /// `MediaSessionProxy` from the `start.m3u8` URL passed to `open`.
    let upstreamBase: URL

    func upstreamURL(forTarget target: String) -> URL? {
        guard target.hasPrefix("/") else { return nil }
        // Build by string concatenation (not URLComponents) to preserve the exact
        // percent-encoding AVKit sent — re-encoding can corrupt the X-Plex token/query.
        var base = upstreamBase.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + target)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd PMSKit && swift test --filter UpstreamURLMapperTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/UpstreamURLMapper.swift PMSKit/Tests/PMSKitTests/UpstreamURLMapperTests.swift
git commit -m "MediaSessionProxy: loopback-target to PMS-URL mapper (#33)"
```

---

## Task 4: Playlist absolute-URL rewrite safety net (pure)

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/PlaylistRewriter.swift`
- Test: `PMSKit/Tests/PMSKitTests/PlaylistRewriterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PMSKit

final class PlaylistRewriterTests: XCTestCase {
    let rewriter = PlaylistRewriter(
        upstreamBase: URL(string: "https://pms.example:32400")!,
        loopbackBase: URL(string: "http://127.0.0.1:51234")!)

    func testRewritesAbsoluteUpstreamURLsToLoopback() {
        let body = "#EXTM3U\nhttps://pms.example:32400/video/seg0.ts\n"
        let out = rewriter.rewrite(Data(body.utf8), contentType: "application/vnd.apple.mpegurl")
        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       "#EXTM3U\nhttp://127.0.0.1:51234/video/seg0.ts\n")
    }

    func testLeavesRelativeURIsUntouched() {
        let body = "#EXTM3U\nindex.m3u8\nseg0.ts\n"
        let out = rewriter.rewrite(Data(body.utf8), contentType: "application/vnd.apple.mpegurl")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), body)
    }

    func testDoesNotRewriteNonPlaylistBodies() {
        // A segment body that happens to contain the upstream bytes must NOT be mangled.
        let body = "https://pms.example:32400/x"
        let out = rewriter.rewrite(Data(body.utf8), contentType: "video/mp2t")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), body)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test --filter PlaylistRewriterTests`
Expected: FAIL — `PlaylistRewriter` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Safety net: PMS normally emits relative URIs (which resolve back to the loopback base on
/// their own), but if a playlist ever contains an *absolute* PMS URL, rewrite it to the
/// loopback base so the follow-up request comes back through the proxy. Only touches playlist
/// bodies — never segment/media bytes, which could coincidentally contain the upstream string.
struct PlaylistRewriter {
    let upstreamBase: URL
    let loopbackBase: URL

    func rewrite(_ body: Data, contentType: String?) -> Data {
        guard isPlaylist(contentType: contentType, body: body) else { return body }
        guard let text = String(data: body, encoding: .utf8) else { return body }
        var up = upstreamBase.absoluteString
        while up.hasSuffix("/") { up.removeLast() }
        var loop = loopbackBase.absoluteString
        while loop.hasSuffix("/") { loop.removeLast() }
        guard text.contains(up) else { return body }
        return Data(text.replacingOccurrences(of: up, with: loop).utf8)
    }

    private func isPlaylist(contentType: String?, body: Data) -> Bool {
        if let ct = contentType?.lowercased(),
           ct.contains("mpegurl") || ct.contains("m3u") {
            return true
        }
        // Fallback to content sniffing: HLS playlists start with the #EXTM3U tag.
        return body.starts(with: Data("#EXTM3U".utf8))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd PMSKit && swift test --filter PlaylistRewriterTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/PlaylistRewriter.swift PMSKit/Tests/PMSKitTests/PlaylistRewriterTests.swift
git commit -m "MediaSessionProxy: playlist absolute-URL rewrite safety net (#33)"
```

---

## Task 5: `mediaUpstream` session configuration

**Files:**
- Modify: `PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift`
- Test: `PMSKit/Tests/PMSKitTests/PlexSessionConfigurationTests.swift`

- [ ] **Step 1: Write the failing test** (append to the existing test file)

```swift
func testMediaUpstreamConfigIsEphemeralWithGenerousTimeout() {
    let cfg = PlexSessionConfiguration.mediaUpstream(timeout: 20)
    XCTAssertEqual(cfg.timeoutIntervalForRequest, 20)
    XCTAssertNil(cfg.urlCache)
    XCTAssertEqual(cfg.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(cfg.waitsForConnectivity)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd PMSKit && swift test --filter PlexSessionConfigurationTests`
Expected: FAIL — `mediaUpstream` not defined.

- [ ] **Step 3: Add the factory** (mirror `recoveryControlPlane`, but the timeout is the generous time-to-first-byte deadline that sits above the deep-seek prime ceiling so a real prime is not mistaken for a wedge)

```swift
/// Upstream session config for the media-session proxy (#33). Like `recoveryControlPlane`
/// (ephemeral, no cache/cookies, no connectivity wait) but `timeout` is deliberately
/// GENEROUS: it is the time-to-first-byte deadline, and a deep-seek prime can hold the
/// connection silent for ~7–9s before PMS emits the first segment. Set the deadline above
/// that ceiling so a legitimate prime completes inside it; a socket that produces nothing
/// past the deadline is treated as wedged and triggers a rotate.
public static func mediaUpstream(timeout: TimeInterval = 20) -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.waitsForConnectivity = false
    return config
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd PMSKit && swift test --filter PlexSessionConfigurationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift PMSKit/Tests/PMSKitTests/PlexSessionConfigurationTests.swift
git commit -m "MediaSessionProxy: mediaUpstream session config (#33)"
```

---

## Task 6: Upstream connection with budget-bounded rotate-and-retry

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/UpstreamConnection.swift`
- Test: `PMSKit/Tests/PMSKitTests/UpstreamConnectionTests.swift`

Design: `UpstreamConnection` is an actor wrapping a fetcher closure (so tests inject a fake instead of a live `URLSession`). On a wedge-class `URLError`, it consults a `SeekRestartBudget`; `.allow` rebuilds the session and retries once, bumping `rotateCount`; `.deferred`/`.escalate` rethrow so the existing failure path surfaces. Real wiring passes a closure that calls `session.data(for:)`; `rebuild()` does `invalidateAndCancel()` + a fresh session.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PMSKit

final class UpstreamConnectionTests: XCTestCase {
    // Wedge-class error used to simulate a poisoned socket.
    private let wedge = URLError(.timedOut)

    func testRetriesOnceAfterRotateOnWedge() async throws {
        var attempts = 0
        var rebuilds = 0
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 3, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: { rebuilds += 1 },
            fetch: { _ in
                attempts += 1
                if attempts == 1 { throw self.wedge }      // first socket wedged
                return (Data("ok".utf8), Self.http(200))   // fresh socket succeeds
            })
        let (data, resp) = try await conn.send(URLRequest(url: URL(string: "https://x/")!))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rebuilds, 1)
        let count = await conn.rotateCount
        XCTAssertEqual(count, 1)
    }

    func testDoesNotRotateWhenRequestSucceeds() async throws {
        var rebuilds = 0
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 3, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: { rebuilds += 1 },
            fetch: { _ in (Data("ok".utf8), Self.http(200)) })
        _ = try await conn.send(URLRequest(url: URL(string: "https://x/")!))
        XCTAssertEqual(rebuilds, 0)
        let count = await conn.rotateCount
        XCTAssertEqual(count, 0)
    }

    func testRethrowsWhenBudgetEscalates() async {
        // burstLimit 0 → first rotate request escalates immediately, error rethrown.
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 0, burstLimit: 0, burstWindowSeconds: 60),
            now: { 0 },
            rebuild: {},
            fetch: { _ in throw self.wedge })
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test --filter UpstreamConnectionTests`
Expected: FAIL — `UpstreamConnection` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// App-owned upstream transport for the proxy (#33). The one thing app code *can* do that
/// AVFoundation's own media-plane pool will not: guarantee a fresh socket. On a wedge-class
/// error it rotates (rebuilds the session) once, budget-permitting, and retries — so the user
/// never has to tap Retry. A genuinely-down server exhausts the budget and the error surfaces
/// through the existing failure path instead of reconnecting forever.
///
/// `fetch`/`rebuild`/`now` are injected so the rotate logic is unit-testable without a live
/// `URLSession`. Production wiring (in `MediaSessionProxy`) passes a `fetch` that calls
/// `session.data(for:)` and a `rebuild` that does `invalidateAndCancel()` + a fresh session.
actor UpstreamConnection {
    private var budget: SeekRestartBudget
    private let now: @Sendable () -> TimeInterval
    private let rebuild: @Sendable () -> Void
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private(set) var rotateCount = 0

    init(budget: SeekRestartBudget,
         now: @escaping @Sendable () -> TimeInterval,
         rebuild: @escaping @Sendable () -> Void,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.budget = budget
        self.now = now
        self.rebuild = rebuild
        self.fetch = fetch
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await fetch(request)
        } catch let error where Self.isWedge(error) {
            switch budget.requestRestart(now: now()) {
            case .allow:
                rebuild()
                rotateCount += 1
                return try await fetch(request)   // one retry on the fresh socket
            case .deferred, .escalate:
                throw error                        // surface; do not reconnect-storm
            }
        }
    }

    /// Errors that indicate a poisoned/half-open socket rather than a clean HTTP error.
    private static func isWedge(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd PMSKit && swift test --filter UpstreamConnectionTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/UpstreamConnection.swift PMSKit/Tests/PMSKitTests/UpstreamConnectionTests.swift
git commit -m "MediaSessionProxy: budget-bounded upstream rotate-and-retry (#33)"
```

---

## Task 7: Loopback `NWListener` HTTP origin

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/LoopbackOrigin.swift`

This is the I/O glue; it is exercised end-to-end by Task 8's proxy tests against a stub origin rather than in isolation. One request per connection, `Connection: close`.

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import Network

/// A minimal loopback HTTP/1.1 origin. Binds `127.0.0.1:0`, and for each inbound connection
/// reads exactly one request head (GET, no body — HLS), hands it to `handler`, writes the
/// serialized response, and closes. One request per connection keeps this trivial and is
/// correct for HLS; keep-alive is a deferred refinement.
final class LoopbackOrigin: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestHead) async -> HTTPResponse

    private let queue = DispatchQueue(label: "media-session-proxy.loopback")
    private var listener: NWListener?

    /// Start listening and resume with the bound port once ready.
    func start(handler: @escaping Handler) async throws -> Int {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let params = NWParameters.tcp
                    params.requiredInterfaceType = .loopback
                    let listener = try NWListener(using: params, on: .any)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] conn in
                        self?.handle(conn, handler: handler)
                    }
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let port = listener.port?.rawValue {
                                cont.resume(returning: Int(port))
                            } else {
                                cont.resume(throwing: URLError(.cannotConnectToHost))
                            }
                        case .failed(let err):
                            cont.resume(throwing: err)
                        default:
                            break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ conn: NWConnection, handler: @escaping Handler) {
        conn.start(queue: queue)
        readHead(conn, buffer: Data()) { head in
            guard let head else { conn.cancel(); return }
            Task {
                let response = await handler(head)
                conn.send(content: response.serialized(), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    /// Accumulate bytes until the request head is complete (`\r\n\r\n`), then deliver it.
    private func readHead(_ conn: NWConnection, buffer: Data, done: @escaping (HTTPRequestHead?) -> Void) {
        if let parsed = HTTPRequestHead.parse(buffer) {
            done(parsed.head)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if let parsed = HTTPRequestHead.parse(next) {
                done(parsed.head)
            } else if isComplete || error != nil {
                done(nil)
            } else {
                self.readHead(conn, buffer: next, done: done)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd PMSKit && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/LoopbackOrigin.swift
git commit -m "MediaSessionProxy: loopback NWListener HTTP origin (#33)"
```

---

## Task 8: `MediaSessionProxy` actor — assemble the contract

**Files:**
- Create: `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift`
- Test: `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`

The proxy ties the pieces together behind `open / seek / stop / status`. Tests run it end-to-end against a **stub origin** (an in-test `NWListener`-backed PMS) so we assert real loopback→upstream forwarding, including the wedge→rotate path, with no live PMS.

- [ ] **Step 1: Write the failing tests** (includes the `StubOrigin` helper)

```swift
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

        let (data, resp) = try await URLSession.shared.data(from: handle.localURL)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U"))
        await proxy.stop(generation: handle.generation)
    }

    func testTransparentlyRecoversFromWedgedFirstRequest() async throws {
        // First fetch wedges; the proxy must rotate and the retry must succeed —
        // surfaced as rotateCount == 1 and a 200 to the client.
        var attempts = 0
        let origin = try await StubOrigin.start { _ in
            attempts += 1
            // StubOrigin can't itself wedge URLSession; the wedge is injected at the
            // fetcher layer below, so this body is only hit on the retry.
            return (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\n".utf8))
        }
        defer { origin.stop() }

        let realFetch = origin.fetcher()
        let wedgingFetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { req in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return try await realFetch(req)
        }
        let proxy = MediaSessionProxy(upstreamFetch: wedgingFetch)
        let handle = try await proxy.open(
            origin: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        let (_, resp) = try await URLSession.shared.data(from: handle.localURL)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test --filter MediaSessionProxyTests`
Expected: FAIL — `MediaSessionProxy` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Player-agnostic media session service (#33). Interposes an app-owned loopback HTTP origin
/// between the renderer and PMS so the media plane becomes recoverable (transparent upstream
/// rotate). The renderer consumes `localURL` and reports events; no AVFoundation types cross
/// this boundary.
///
/// Stage 1 scope: `open` fronts an already-resolved PMS `start.m3u8` URL; `seek` is a
/// pass-through (AVKit still seeks natively); `stop` tears down the loopback. Owning the
/// decision/probe build and re-priming seeks is Stage 2.
public actor MediaSessionProxy {
    private let origin = LoopbackOrigin()
    private let upstreamFetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var connection: UpstreamConnection?
    private var current: MediaSessionHandle?
    private var rotateCount = 0

    /// Production initializer: build the upstream `URLSession` from `mediaUpstream`, mirroring
    /// the app's trust posture (default trust works for `*.plex.direct`; pass a host-scoped
    /// insecure-LAN delegate only when the user enabled it).
    public init(timeout: TimeInterval = 20, trustDelegate: URLSessionDelegate? = nil) {
        let config = PlexSessionConfiguration.mediaUpstream(timeout: timeout)
        // A box so `rebuild` can swap the session that `fetch` reads.
        let box = SessionBox(config: config, delegate: trustDelegate)
        self.upstreamFetch = { req in try await box.fetch(req) }
        self.rebuildBox = { box.rebuild() }
    }

    /// Test initializer: inject the upstream fetcher directly (no live session).
    init(upstreamFetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.upstreamFetch = upstreamFetch
        self.rebuildBox = {}
    }

    private let rebuildBox: @Sendable () -> Void

    public func open(origin pmsStart: URL) async throws -> MediaSessionHandle {
        // Derive PMS origin (scheme/host/port) and the loopback-facing path+query.
        guard var comps = URLComponents(url: pmsStart, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme, let host = comps.host else {
            throw URLError(.badURL)
        }
        var baseComps = URLComponents()
        baseComps.scheme = scheme
        baseComps.host = host
        baseComps.port = comps.port
        guard let upstreamBase = baseComps.url else { throw URLError(.badURL) }

        let mapper = UpstreamURLMapper(upstreamBase: upstreamBase)
        let conn = UpstreamConnection(
            budget: SeekRestartBudget(cooldownSeconds: 5, burstLimit: 3, burstWindowSeconds: 60),
            now: { ProcessInfo.processInfo.systemUptime },
            rebuild: rebuildBox,
            fetch: upstreamFetch)
        self.connection = conn

        let port = try await origin.start { [mapper] head in
            await Self.serve(head, mapper: mapper, upstreamBase: upstreamBase,
                             connection: conn, loopbackPort: nil)
        }

        // Build the loopback URL the renderer will load: same path+query as the PMS start URL.
        var loop = URLComponents()
        loop.scheme = "http"
        loop.host = "127.0.0.1"
        loop.port = port
        loop.path = comps.path
        loop.percentEncodedQuery = comps.percentEncodedQuery
        guard let localURL = loop.url else { throw URLError(.badURL) }

        let generation = (current?.generation ?? 0) + 1
        let handle = MediaSessionHandle(localURL: localURL, generation: generation)
        current = handle
        return handle
    }

    /// Stage 1: pass-through. AVKit still performs the native seek; the proxy does not yet
    /// re-prime PMS. Returns the current handle unchanged. (Stage 2 makes this authoritative.)
    public func seek(to offsetMs: Int) async throws -> MediaSessionHandle {
        guard let current else { throw URLError(.badURL) }
        return current
    }

    public func stop(generation: Int) async {
        guard current?.generation == generation else { return }   // ignore stale teardown
        origin.stop()
        current = nil
    }

    public func status() -> MediaSessionStatus {
        MediaSessionStatus(generation: current?.generation ?? 0,
                           isOpen: current != nil,
                           rotateCount: rotateCount)
    }

    /// One inbound request → upstream fetch (with rotate) → rewrite → response.
    private static func serve(_ head: HTTPRequestHead,
                              mapper: UpstreamURLMapper,
                              upstreamBase: URL,
                              connection: UpstreamConnection,
                              loopbackPort: Int?) async -> HTTPResponse {
        guard let upstreamURL = mapper.upstreamURL(forTarget: head.target) else {
            return HTTPResponse(status: 400, reason: "Bad Request", headers: [], body: Data())
        }
        var req = URLRequest(url: upstreamURL)
        req.httpMethod = head.method
        if let range = head.value(for: "Range") { req.setValue(range, forHTTPHeaderField: "Range") }
        do {
            let (data, resp) = try await connection.send(req)
            let contentType = resp.value(forHTTPHeaderField: "Content-Type")
            // Loopback base is known after `open`; rewriter uses the actual port via the
            // request Host header AVKit sent, which already targets the loopback origin.
            let body = data
            var headers: [(name: String, value: String)] = []
            if let ct = contentType { headers.append(("Content-Type", ct)) }
            return HTTPResponse(status: resp.statusCode, reason: "OK", headers: headers, body: body)
        } catch {
            return HTTPResponse(status: 502, reason: "Bad Gateway", headers: [], body: Data())
        }
    }
}

/// Holds the live upstream `URLSession` so a rotate can swap it without disturbing callers.
private final class SessionBox: @unchecked Sendable {
    private let config: URLSessionConfiguration
    private let delegate: URLSessionDelegate?
    private let lock = NSLock()
    private var session: URLSession

    init(config: URLSessionConfiguration, delegate: URLSessionDelegate?) {
        self.config = config
        self.delegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func fetch(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); let s = session; lock.unlock()
        let (data, resp) = try await s.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }

    func rebuild() {
        lock.lock()
        session.invalidateAndCancel()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        lock.unlock()
    }
}
```

> **Implementation note for the executor:** `rotateCount` must reflect the connection's rotates. Wire it through — after `connection.send`, read `await connection.rotateCount` into the proxy's `rotateCount` (or expose a callback). The test `testTransparentlyRecoversFromWedgedFirstRequest` asserts `status().rotateCount == 1`; make that pass by surfacing the connection's count. Also fold the `PlaylistRewriter` into `serve` once the loopback port is threaded through (the rewrite is a safety net; the forwarding tests pass without it because PMS URIs are relative). Keep the public contract (`open/seek/stop/status`) exactly as written; refine internals to satisfy the tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd PMSKit && swift test --filter MediaSessionProxyTests`
Expected: PASS (3 tests). Fix wiring (rotateCount surfacing, rewriter threading) until green.

- [ ] **Step 5: Run the full PMSKit suite**

Run: `cd PMSKit && swift test`
Expected: all green (no regressions in existing suites).

- [ ] **Step 6: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift
git commit -m "MediaSessionProxy: assemble open/seek/stop/status over loopback origin (#33)"
```

---

## Task 9: Wire the proxy into `PlaybackController`

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackController.swift` (the `AVURLAsset(url: streamURL)` site ~line 1124, and teardown/stop).

Goal: keep the player thin. The controller still computes `streamURL` exactly as today (Direct Stream probe + decision); it then asks the proxy to front that URL and points `AVURLAsset` at the returned loopback URL. On teardown it stops the proxy generation. No seek behavior changes (Stage 1 `seek` is pass-through, so the existing seek path is untouched).

- [ ] **Step 1: Add a proxy property and open it before building the asset**

Find where `streamURL` is computed and the asset is built (around the `let asset = AVURLAsset(url: streamURL)` line). Add a `MediaSessionProxy` owned by the controller, and replace the asset URL:

```swift
// Property on PlaybackController:
private let mediaProxy = MediaSessionProxy()
private var mediaProxyGeneration: Int?

// Where the asset is built (replacing `let asset = AVURLAsset(url: streamURL)`):
let handle = try await mediaProxy.open(origin: streamURL)
mediaProxyGeneration = handle.generation
let asset = AVURLAsset(url: handle.localURL)
```

(If the surrounding function is not already `async throws` at that point, wrap the `open` call to match the existing structure — the asset build is already inside the streaming setup path which is async.)

- [ ] **Step 2: Tear the proxy down on stop**

In the controller's teardown/stop path (where `removeObservers()` / PMS `TranscodeRequest.stop` already run), add:

```swift
if let gen = mediaProxyGeneration {
    Task { await mediaProxy.stop(generation: gen) }
    mediaProxyGeneration = nil
}
```

Leave the existing PMS `TranscodeRequest.stop(...)` call in place — Stage 1 does not move server-side teardown into the proxy.

- [ ] **Step 3: Build the app (guard the link-skip trap)**

```bash
rm -rf $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
```

Expected: BUILD SUCCEEDED; a fresh `PlexAVPApp.app` exists (verify mtime).

- [ ] **Step 4: Install + relaunch, confirm the installed binary is the fresh one**

```bash
APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app | head -1)
xcrun simctl install booted "$APP"
xcrun simctl terminate booted com.jlipworth.VisionPlay; xcrun simctl launch booted com.jlipworth.VisionPlay
xcrun simctl get_app_container booted com.jlipworth.VisionPlay app   # compare against $APP
```

- [ ] **Step 5: Commit**

```bash
git add PlexAVPApp/Player/PlaybackController.swift
git commit -m "Route AVURLAsset through MediaSessionProxy loopback (#33)"
```

---

## Task 10: ATS fallback (only if AVKit refuses the loopback load)

**Files:**
- Modify (conditionally): `Config/Info.plist`

- [ ] **Step 1: Exercise playback once (user drives the sim); read the log**

```bash
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"'
```

If playback works through the loopback URL, **skip the rest of this task** — no ATS change needed.

- [ ] **Step 2: Only if the load is blocked by ATS**, add a scoped local-networking exception (NOT `NSAllowsArbitraryLoads`):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

- [ ] **Step 3: Rebuild/install/relaunch (Task 9 Steps 3–4), confirm playback loads, commit**

```bash
git add Config/Info.plist
git commit -m "Allow loopback local networking for MediaSessionProxy (#33)"
```

---

## Task 11: Live-through-proxy test hook + checklist

**Files:**
- Create: `PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift` (gated on live creds, never committed — mirror `LiveSegmentProbeTests`'s skip-without-env pattern).
- Modify: `TESTING-CHECKLIST.md`

- [ ] **Step 1: Add a live probe that fetches index.m3u8 + one segment THROUGH the proxy**

Mirror `LiveSegmentProbeTests`: read live PMS creds from the gated env file; if absent, `throw XCTSkip`. Build a `start.m3u8` `TranscodeRequest`, `MediaSessionProxy().open(origin:)`, then fetch `handle.localURL` and assert a `#EXTM3U` body; resolve one variant + one segment URI through the loopback and assert 200/206. (Use the existing live-creds gate; never hardcode token/host.)

- [ ] **Step 2: Run it (skips cleanly without creds)**

Run: `cd PMSKit && swift test --filter LiveProxyProbeTests`
Expected: SKIPPED without creds; PASS with creds.

- [ ] **Step 3: Add a TESTING-CHECKLIST.md section** for the manual sim pass:

```markdown
## MediaSessionProxy (#33)
- [ ] Normal play: title starts through the loopback proxy (no behavior change vs. direct).
- [ ] Deep seek (prime): seek far ahead; ~7–9s prime succeeds, NOT mistaken for a wedge.
- [ ] Forced wedge → transparent recovery: induce a stall; playback self-heals with NO
      "Reconnecting" box and NO manual Retry (status.rotateCount increments).
- [ ] Close mid-stall: closing the player does not leave a black screen.
```

- [ ] **Step 4: Commit**

```bash
git add PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift TESTING-CHECKLIST.md
git commit -m "MediaSessionProxy: live-through-proxy probe + checklist (#33)"
```

---

## Self-review notes (author)

- **Spec coverage:** contract (Task 1, 8) · loopback NWListener transport (Task 7) · app-owned upstream + rotate (Task 6) · transparent auto-rotate with generous TTFB discriminator + budget (Task 6, Task 5 config) · relative-URL-resolves-naturally + absolute-URL rewrite safety net (Task 4, threaded in Task 8) · trust posture mirror (Task 8 `trustDelegate`) · ATS fallback (Task 10) · staged plan with `seek` pass-through (Task 8) · player stays thin (Task 9) · testing strategy: pure unit + stub-origin integration + live-through-proxy (Tasks 2–4, 8, 11). Stages 2–3 intentionally out of scope.
- **Known executor follow-ups (flagged inline in Task 8):** surface `UpstreamConnection.rotateCount` into `MediaSessionProxy.status()`; thread the loopback port into `serve` so `PlaylistRewriter` can run (safety net — forwarding tests pass without it). These are wiring details, not design gaps.
- **Type consistency:** `MediaSessionHandle{localURL, generation}`, `MediaSessionStatus{generation,isOpen,rotateCount}`, `HTTPRequestHead{method,target,headers}.parse->(head,headByteCount)` / `.value(for:)`, `HTTPResponse{status,reason,headers,body}.serialized()`, `UpstreamURLMapper{upstreamBase}.upstreamURL(forTarget:)`, `PlaylistRewriter{upstreamBase,loopbackBase}.rewrite(_:contentType:)`, `UpstreamConnection.init(budget:now:rebuild:fetch:).send(_:)`/`.rotateCount`, `LoopbackOrigin.start(handler:)->Int`/`.stop()`, `MediaSessionProxy.open(origin:)`/`seek(to:)`/`stop(generation:)`/`status()` — consistent across tasks.
```
