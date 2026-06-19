# Issue #33 Stage 2 — Proxy-Owned Seek/Re-Prime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move seek-restart orchestration out of `PlaybackController` into `MediaSessionProxy` so a deep scrub re-primes the PMS transcode through the app-owned loopback (decision + new `localURL` + `replaceItem`), fixing the "drag-twice → sticky + reconnect hell" bug by replacing the fragile player-side seek-restart state machine with a coalescing, latest-wins re-prime owned by the proxy.

**Architecture:** `MediaSessionProxy` (a PMSKit `public actor`) gains a control-plane transport seam — an injected `@Sendable (PlexRequest) async throws -> Data` — so it can run PMS transcode *decisions* itself without importing the app-layer `PlexClient`. `open(_:offsetMs:)` resolves the stream URL (decision/probe) and stands up the loopback; `seek(to:)` coalesces concurrent scrubs into a single latest-wins re-prime loop that stops the previous transcode, re-runs the decision at the new offset, recomputes `localURL` against the **persisted** loopback base (the listener/mapper/rewriter are unchanged — only the `start.m3u8` `offset` query changes), and hands back a fresh handle. A `SeekRestartBudget` inside the proxy escalates abusive scrubbing to a thrown `budgetEscalated`. `PlaybackController` becomes thin: build a `MediaSessionRequest`, `open`, and on each `timeJumpedNotification` either ignore (echo / already-buffered) or `await proxy.seek` then `replaceItem`. The old `handleTimeJump`/`confirmSeekStallRestart`/`pendingSeekTargetMs`/`hasPlayedThisItem`/`lastSettledPlayheadSeconds`/`seekRestartTimer`/`seekRestartBudget`/`seekJumpMinDeltaSeconds`/`seekStallConfirmSeconds` machinery is deleted.

**Tech Stack:** Swift 6 (strict concurrency), `actor` isolation, Swift `Testing` + `XCTest` (PMSKit has both; new proxy tests are XCTest to match `MediaSessionProxyTests`), AVFoundation (app target only — never crosses the PMSKit boundary), `xcodebuild` for the visionOS app target.

---

## Build/Test Sequencing Notes (read before starting)

- **PMSKit tasks (1–3, 5):** verify with `cd PMSKit && swift test`. The PMSKit test target compiles `LiveProxyProbeTests.swift`, so any change to `MediaSessionProxy`'s init/method signatures MUST keep that file compiling within the same task — Task 2 migrates it.
- **App target (Task 4):** `PlaybackController` lives in the app target, NOT PMSKit, so `swift test` does not compile it. The app target will **not** build between Task 2 and Task 4 (the `MediaSessionProxy()` call site is stale). **Do not run `xcodebuild` until Task 4.**
- **Link-skip trap (CLAUDE.md):** every app fix build must `rm -rf` the `.app` product first and verify a fresh binary mtime afterward.
- **No secrets:** the live probe (Task 5) reads creds from the gitignored `scripts/plex-live.env`; never hardcode tokens/hosts. `X-Plex-Client-Profile-Name=Safari` is built by `TranscodeRequest` and must not change.

---

## File Structure

- **Modify** `PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift` — add `MediaSessionRequest` (the Plex-aware open input) and `MediaSessionError`.
- **Modify** `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift` — add control-plane seam + `now` clock + `decoder`; refactor `open(origin:)` into internal `standUpLoopback(forStream:)` + static `loopbackURL(forStream:base:)`; add `resolveStreamURL`, public `open(_:offsetMs:)`, `currentDecision()`, coalescing `seek(to:)`, `runReprimeLoop`, `reprimeOnce`, proxy `stopPreviousTranscode`, the reprime `SeekRestartBudget`, and a monotonic generation counter.
- **Modify** `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift` — migrate transport tests to `standUpLoopback`; delete the Stage-1 pass-through test; add decision/probe/coalescing/budget/stop-order tests plus `Clock`/`ControlRecorder`/`Gate`/`sampleRequest` helpers.
- **Modify** `PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift` — migrate to `open(_:offsetMs:)` with a real control sender; add a deep-offset seek hop.
- **Modify** `VisionPlay/Player/PlaybackController.swift` — wire the proxy (lazy `mediaProxy` with `controlSend`); build `MediaSessionRequest`; new `open` + `loopbackUnavailable` fallback; seed diagnostics from `currentDecision()`; add `handleSeekJump`/`repositionViaProxy`/`loadProxyHandle`/`isWithinLoadedRanges`; delete the old seek-restart machinery.
- **Modify** `TESTING-CHECKLIST.md` — add the manual Stage-2 seek checklist.

---

### Task 1: PMSKit types — `MediaSessionRequest` + `MediaSessionError`

**Files:**
- Modify: `PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift`
- Test: `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MediaSessionProxyTests.swift` (inside the `MediaSessionProxyTests` class):

```swift
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
        XCTAssertEqual(MediaSessionError.budgetEscalated(recentCount: 3),
                       MediaSessionError.budgetEscalated(recentCount: 3))
        XCTAssertNotEqual(MediaSessionError.notOpen,
                          MediaSessionError.budgetEscalated(recentCount: 1))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd PMSKit && swift test --filter testMediaSessionRequestAndErrorValueSemantics`
Expected: FAIL to **compile** — `cannot find 'MediaSessionRequest'` / `'MediaSessionError' in scope`.

- [ ] **Step 3: Add the types**

Append to `PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift`:

```swift
/// The Plex-aware input to `MediaSessionProxy.open` (#33 Stage 2). The proxy builds the
/// `TranscodeRequest` and runs the decision/probe itself from these fields — only the
/// control-plane TRANSPORT is injected (see `MediaSessionProxy.init`), never the app's
/// `PlexClient` (which is app-layer and must not cross into PMSKit).
public struct MediaSessionRequest: Sendable, Equatable {
    public let server: URL
    public let token: String
    public let identity: ClientIdentity
    public let metadataKey: String
    public let maxVideoBitrateKbps: Int
    public let sessionID: String
    public let mediaIndex: Int
    public let partIndex: Int
    /// Subtitle stream to burn in, or nil to leave PMS on `auto` (mirrors the player's
    /// current streaming request, which passes nil).
    public let burnSubtitleStreamID: Int?
    /// When true, the proxy probes the MDE with `directPlay=1` first and commits to the
    /// direct-play start URL when PMS confirms it will copy the video (#7). Off → today's
    /// transcode path, byte-identical.
    public let directStreamEnabled: Bool

    public init(server: URL, token: String, identity: ClientIdentity, metadataKey: String,
                maxVideoBitrateKbps: Int, sessionID: String, mediaIndex: Int, partIndex: Int,
                burnSubtitleStreamID: Int?, directStreamEnabled: Bool) {
        self.server = server
        self.token = token
        self.identity = identity
        self.metadataKey = metadataKey
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.sessionID = sessionID
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.burnSubtitleStreamID = burnSubtitleStreamID
        self.directStreamEnabled = directStreamEnabled
    }
}

/// Errors surfaced across the media-session boundary (#33 Stage 2).
public enum MediaSessionError: Error, Sendable, Equatable {
    /// `seek`/`status` before a successful `open`.
    case notOpen
    /// The re-prime burst budget was exhausted — abusive scrubbing the stream can't sustain.
    /// The caller (PlaybackController) maps this to the failure overlay. `recentCount` is the
    /// number of restarts in the rolling window (for logging).
    case budgetEscalated(recentCount: Int)
    /// The loopback origin could not be stood up; the caller should load `directURL` directly
    /// (the Stage-1 fallback — playback must never depend on the proxy being up).
    case loopbackUnavailable(directURL: URL)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd PMSKit && swift test --filter testMediaSessionRequestAndErrorValueSemantics`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/MediaSessionTypes.swift PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift
git commit -m "MediaSessionProxy (#33): add MediaSessionRequest + MediaSessionError types"
```

---

### Task 2: Proxy open path — control-plane seam, `standUpLoopback` refactor, Plex-aware `open`

**Files:**
- Modify: `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift`
- Modify: `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`
- Modify: `PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift`

This task adds the control-plane transport, refactors the Stage-1 `open(origin:)` body into a reusable `standUpLoopback(forStream:)` + `loopbackURL` helper (no behavior change to forwarding), and adds the Plex-aware `open(_:offsetMs:)` that resolves the stream URL (decision/probe) itself. `seek` stays the Stage-1 pass-through until Task 3.

- [ ] **Step 1: Migrate the test helpers + transport tests to the new shape (write the failing tests)**

In `MediaSessionProxyTests.swift`:

First, give `StubOrigin` a base URL accessor. Add inside `final class StubOrigin` (after the `port` line):

```swift
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
```

Replace `testForwardsPlaylistRequestThroughLoopback` and `testTransparentlyRecoversFromWedgedFirstRequest`'s `proxy.open(origin:)` calls with `standUpLoopback(forStream:)`. The full replacements:

```swift
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
```

Replace `testStaleStopIsIgnored`'s `proxy.open(origin:)` with `standUpLoopback`:

```swift
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
```

**Leave `testSeekIsPassThroughInStage1` unchanged for now** — its `proxy.open(origin:)` call will break compilation, so change ONLY its open call to `standUpLoopback`:

```swift
    func testSeekIsPassThroughInStage1() async throws {
        let origin = try await StubOrigin.start { _ in (200, "text/plain", Data()) }
        defer { origin.stop() }
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher())
        let opened = try await proxy.standUpLoopback(forStream: URL(string: "http://127.0.0.1:\(origin.port)/start.m3u8")!)
        let sought = try await proxy.seek(to: 120_000)
        XCTAssertEqual(sought, opened)   // same handle, same generation
        await proxy.stop(generation: opened.generation)
    }
```

Now add the new decision-on-open tests + shared helpers. Add these test methods inside the class:

```swift
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
        XCTAssertEqual(await proxy.currentDecision()?.decision, .transcode)
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
```

Add the shared helpers and canned JSON at file scope (after the `Counter` class, before end of file):

```swift
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

/// Monotonic injectable clock for the proxy's `now` seam (budget escalation determinism).
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ start: TimeInterval = 0) { t = start }
    func advance(_ d: TimeInterval) { lock.lock(); t += d; lock.unlock() }
    var now: @Sendable () -> TimeInterval { { [self] in lock.lock(); defer { lock.unlock() }; return t } }
}

/// Records the control-plane requests the proxy sends and returns a canned decision body.
final class ControlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URL] = []
    private let response: Data
    init(response: Data) { self.response = response }
    func send() -> @Sendable (PlexRequest) async throws -> Data {
        { [self] req in lock.lock(); sent.append(req.url); lock.unlock(); return response }
    }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return sent }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test 2>&1 | tail -30`
Expected: FAIL to compile — `value of type 'MediaSessionProxy' has no member 'standUpLoopback'`, `no member 'open' that takes (..., offsetMs:)`, `no member 'currentDecision'`, and the `MediaSessionProxy(upstreamFetch:controlSend:now:)` initializer doesn't exist.

- [ ] **Step 3: Add the control-plane seam + refactor `open` in `MediaSessionProxy.swift`**

Add stored properties. Replace the property block (lines ~12–15, the `upstreamFetch`/`rebuildUpstream`/`connection`/`current` declarations) — keep those four and add the new ones below them:

```swift
    private let origin = LoopbackOrigin()
    private let upstreamFetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let rebuildUpstream: @Sendable () -> Void
    private var connection: UpstreamConnection?
    private var current: MediaSessionHandle?

    // --- Stage 2: control plane + Plex-aware open/seek ---
    /// App-injected control-plane transport. The proxy builds PMSKit `PlexRequest`s
    /// (decision/probe/stop) and sends them through this; the app wires it to `PlexClient`
    /// (which is app-layer and must not be imported here).
    private let controlSend: @Sendable (PlexRequest) async throws -> Data
    /// Monotonic clock for the reprime budget (injected for deterministic tests).
    private let now: @Sendable () -> TimeInterval
    private let decoder = JSONDecoder()
    /// The active Plex-aware request, retained so a re-prime can rebuild the stream URL.
    private var request: MediaSessionRequest?
    /// The most recent PMS decision (for the player's Stats overlay via `currentDecision()`).
    private var lastDecision: DecisionResponse?
    /// The loopback base (`http://127.0.0.1:<port>`), persisted across re-primes: the listener,
    /// mapper and rewriter are keyed on the (unchanged) upstream PMS host, so a re-prime only
    /// recomputes `localURL` for the new `start.m3u8` offset query against this base.
    private var loopbackBase: URL?
    /// Strictly increasing handle generation across `open` AND every re-prime.
    private var generationCounter = 0
    /// Rate-limit policy for re-primes (#27). Lean params: re-prime itself takes ~2s (the
    /// stop+decision), so the short cooldown rarely defers a legitimate second drag; only a
    /// genuine burst escalates. Reset on each `open` (a fresh session re-earns self-healing).
    private var reprimeBudget = SeekRestartBudget(cooldownSeconds: 2, burstLimit: 5, burstWindowSeconds: 60)
    /// Single-flight re-prime task + the latest pending target (latest-wins coalescing).
    private var reprimeTask: Task<MediaSessionHandle, Error>?
    private var pendingLatestOffsetMs: Int?
```

Update **both** initializers to take `controlSend`/`now`. Replace the production init:

```swift
    public init(timeout: TimeInterval = 20,
                trustDelegate: URLSessionDelegate? = nil,
                controlSend: @escaping @Sendable (PlexRequest) async throws -> Data,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let box = SessionBox(config: PlexSessionConfiguration.mediaUpstream(timeout: timeout),
                             delegate: trustDelegate)
        self.upstreamFetch = { req in try await box.fetch(req) }
        self.rebuildUpstream = { box.rebuild() }
        self.controlSend = controlSend
        self.now = now
    }
```

Replace the test init:

```swift
    /// Test initializer: inject the upstream fetcher directly (no live session). `controlSend`
    /// defaults to a no-op (transport tests don't exercise the decision path); `now` defaults
    /// to real uptime but is overridable for deterministic budget tests.
    init(upstreamFetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
         controlSend: @escaping @Sendable (PlexRequest) async throws -> Data = { _ in Data() },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.upstreamFetch = upstreamFetch
        self.rebuildUpstream = {}
        self.controlSend = controlSend
        self.now = now
    }
```

Now replace the Stage-1 `open(origin:)` method (the whole `public func open(origin pmsStart: URL) ... return handle }` block) with the refactored primitive + the new Plex-aware open + helpers:

```swift
    /// Plex-aware open (#33 Stage 2): resolve the stream URL (decision/probe owned HERE) at
    /// `offsetMs`, then stand up the loopback fronting it. Cancels any in-flight re-prime and
    /// resets coalescing/budget state first so a re-open is a clean slate. Throws
    /// `MediaSessionError.loopbackUnavailable(directURL:)` if the loopback can't bind — the
    /// caller loads the direct URL (Stage-1 fallback).
    public func open(_ request: MediaSessionRequest, offsetMs: Int) async throws -> MediaSessionHandle {
        if let task = reprimeTask {
            task.cancel()
            _ = try? await task.value
            reprimeTask = nil
        }
        pendingLatestOffsetMs = nil
        self.request = request
        reprimeBudget.reset()
        let (streamURL, decision) = await resolveStreamURL(request, offsetMs: offsetMs)
        self.lastDecision = decision
        do {
            return try await standUpLoopback(forStream: streamURL)
        } catch {
            throw MediaSessionError.loopbackUnavailable(directURL: streamURL)
        }
    }

    /// The most recent PMS decision (Stats overlay). Nil before the first `open`/decision.
    public func currentDecision() -> DecisionResponse? { lastDecision }

    /// Run the PMS decision/probe and return the stream URL to front + the decision. Mirrors
    /// `PlaybackController.startStreaming`'s logic exactly: probe with `directPlay=1` first when
    /// enabled and commit to the direct-play start ONLY when PMS confirms it copies the video
    /// (`savesVideoEncode`); otherwise the production transcode start.m3u8. Decision/probe
    /// failures are non-fatal — fall through to the plain transcode start (Stage-1 behavior).
    private func resolveStreamURL(_ request: MediaSessionRequest, offsetMs: Int)
        async -> (URL, DecisionResponse?) {
        let offsetSeconds: Int? = offsetMs > 0 ? offsetMs / 1000 : nil
        let transcode = TranscodeRequest(
            server: request.server, token: request.token, identity: request.identity,
            metadataKey: request.metadataKey, maxVideoBitrateKbps: request.maxVideoBitrateKbps,
            sessionID: request.sessionID, mediaIndex: request.mediaIndex, partIndex: request.partIndex,
            burnSubtitleStreamID: request.burnSubtitleStreamID, startOffsetSeconds: offsetSeconds)

        var decision: DecisionResponse?
        var streamURL = transcode.startM3U8URL()
        if request.directStreamEnabled {
            do {
                let data = try await controlSend(transcode.directPlayProbeRequest())
                let probe = try decoder.decode(DecisionResponse.self, from: data)
                if probe.savesVideoEncode {
                    decision = probe
                    streamURL = transcode.directPlayStartM3U8URL()
                }
            } catch {
                // Fall through to the transcode path (byte-identical to a failed probe).
            }
        }
        if decision == nil {
            do {
                let data = try await controlSend(transcode.decisionRequest())
                decision = try decoder.decode(DecisionResponse.self, from: data)
            } catch {
                // Non-fatal: attempt start.m3u8 anyway.
            }
        }
        return (streamURL, decision)
    }

    /// Bind the app-owned loopback origin in front of `streamURL`'s PMS host and return a
    /// handle whose `localURL` mirrors `streamURL`'s path+query onto the loopback. Persists
    /// `loopbackBase` so re-primes can recompute `localURL` without rebinding (the upstream
    /// host is unchanged across a re-prime — only the offset query differs). This is the
    /// former Stage-1 `open(origin:)` body, made reusable.
    func standUpLoopback(forStream streamURL: URL) async throws -> MediaSessionHandle {
        // Re-open reuses this proxy: tear down any prior listener before binding a fresh one.
        if current != nil {
            origin.stop()
            connection = nil
            current = nil
        }
        guard let comps = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
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
            rebuild: rebuildUpstream,
            fetch: upstreamFetch)
        self.connection = conn

        let rewriterBox = RewriterBox()
        let port = try await origin.start { [mapper, conn, rewriterBox] head in
            await Self.serve(head, mapper: mapper, connection: conn, rewriter: rewriterBox.value)
        }

        guard let loopbackBase = URL(string: "http://127.0.0.1:\(port)"),
              let localURL = Self.loopbackURL(forStream: streamURL, base: loopbackBase) else {
            throw URLError(.badURL)
        }
        self.loopbackBase = loopbackBase
        rewriterBox.set(PlaylistRewriter(upstreamBase: upstreamBase, loopbackBase: loopbackBase))

        generationCounter += 1
        let handle = MediaSessionHandle(localURL: localURL, generation: generationCounter)
        current = handle
        return handle
    }

    /// Map a PMS stream URL's path+query onto the loopback base (scheme/host/port from `base`).
    /// AVKit resolves the playlist's relative URIs against this, routing every hop back through
    /// the proxy; a re-prime changes only `streamURL`'s `offset` query, so the listener stands.
    static func loopbackURL(forStream streamURL: URL, base loopbackBase: URL) -> URL? {
        guard let streamComps = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
              var baseComps = URLComponents(url: loopbackBase, resolvingAgainstBaseURL: false)
        else { return nil }
        baseComps.path = streamComps.path
        baseComps.percentEncodedQuery = streamComps.percentEncodedQuery
        return baseComps.url
    }
```

Leave the Stage-1 `seek(to:)` pass-through, `stop`, `status`, `serve`, and `reason` exactly as they are (Task 3 replaces `seek`).

- [ ] **Step 4: Migrate `LiveProxyProbeTests.swift` so the test target compiles**

In `LiveProxyProbeTests.swift`, replace the proxy setup + open (the block from `// The real proxy fronting the LIVE server` through the `proxy.open(origin: startURL)` line and its log) with a control-sender-wired `open(_:offsetMs:)`. Replace these lines:

```swift
        let transcode = TranscodeRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey, maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
            sessionID: "live-proxy-\(UUID().uuidString)",
            mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex,
            startOffsetSeconds: cfg.offsetSeconds)
        let startURL = transcode.startM3U8URL()

        print(String(format: ">>> PROXY probe: offset=%ds cap=%dkbps — fronting live PMS through the app-owned loopback origin.",
                     cfg.offsetSeconds, cfg.maxVideoBitrateKbps))

        // The real proxy fronting the LIVE server (default trust works for *.plex.direct).
        let proxy = MediaSessionProxy(timeout: 30)
        let handle = try await proxy.open(origin: startURL)
        print(String(format: ">>> PROXY open: loopback=%@", handle.localURL.absoluteString))
```

with:

```swift
        let sessionID = "live-proxy-\(UUID().uuidString)"
        let mediaRequest = MediaSessionRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey, maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
            sessionID: sessionID, mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex,
            burnSubtitleStreamID: nil, directStreamEnabled: false)

        print(String(format: ">>> PROXY probe: offset=%ds cap=%dkbps — fronting live PMS through the app-owned loopback origin.",
                     cfg.offsetSeconds, cfg.maxVideoBitrateKbps))

        // The real proxy fronting the LIVE server (default trust works for *.plex.direct). The
        // control plane is a plain ephemeral session that folds PlexRequest.queryItems into the
        // URL (exactly what PlexClient.send does in the app).
        let controlSession = URLSession(configuration: .ephemeral)
        let proxy = MediaSessionProxy(timeout: 30, controlSend: { req in
            var comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)!
            if !req.queryItems.isEmpty { comps.queryItems = (comps.queryItems ?? []) + req.queryItems }
            var urlReq = URLRequest(url: comps.url!)
            urlReq.httpMethod = req.method
            for (k, v) in req.headers { urlReq.setValue(v, forHTTPHeaderField: k) }
            urlReq.httpBody = req.body
            let (data, _) = try await controlSession.data(for: urlReq)
            return data
        })
        let handle = try await proxy.open(mediaRequest, offsetMs: cfg.offsetSeconds * 1000)
        print(String(format: ">>> PROXY open: loopback=%@", handle.localURL.absoluteString))
```

(The seek-hop addition comes in Task 5.)

- [ ] **Step 5: Build and run the PMSKit tests**

Run: `cd PMSKit && swift test 2>&1 | tail -30`
Expected: PASS — transport tests (now via `standUpLoopback`), `testSeekIsPassThroughInStage1`, `testStaleStopIsIgnored`, `testOpenResolvesStreamURLWithOffsetAndRunsDecision`, `testOpenCommitsDirectPlayStartWhenProbeSavesEncode`, and Task 1's type test all green. `LiveProxyProbe` no-ops (no creds).

- [ ] **Step 6: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift
git commit -m "MediaSessionProxy (#33): control-plane seam + Plex-aware open (decision owned by proxy)"
```

---

### Task 3: Coalescing proxy-owned `seek` — latest-wins re-prime loop + budget

**Files:**
- Modify: `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift`
- Modify: `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`

- [ ] **Step 1: Replace the pass-through test with the coalescing/budget/ordering tests (write the failing tests)**

In `MediaSessionProxyTests.swift`, **delete** `testSeekIsPassThroughInStage1` entirely and add the `Gate` helper at file scope (after `ControlRecorder`):

```swift
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
```

Add the new tests inside the class:

```swift
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
        let proxy = MediaSessionProxy(upstreamFetch: origin.fetcher(),
                                      controlSend: gatedControlSend(recorder: recorder, block: block, reached: reached),
                                      now: Clock(0).now)
        let opened = try await proxy.open(sampleRequest(server: origin.baseURL), offsetMs: 0)

        // Fire the first seek; it blocks at its decision.
        async let h1 = proxy.seek(to: 60_000)     // o1 = 60s — in-flight, gated
        await reached.wait()
        // Pile up two more while o1 is blocked; o3 wins, o2 is dropped.
        async let h2 = proxy.seek(to: 120_000)    // o2 = 120s — dropped
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd PMSKit && swift test 2>&1 | tail -30`
Expected: FAIL to compile — `no member 'pendingOffsetMsForTest'`; and the coalescing/escalation behavior doesn't exist (seek is still pass-through, so `r3.generation > opened.generation` and the escalation throw fail).

- [ ] **Step 3: Replace the Stage-1 `seek` with the coalescing re-prime in `MediaSessionProxy.swift`**

Replace the Stage-1 `seek(to:)` method (the `guard let current ... return current` pass-through) with:

```swift
    /// Coalescing, latest-wins re-prime (#33 Stage 2). Concurrent scrubs collapse onto one
    /// in-flight re-prime: each call records the latest target and joins the single re-prime
    /// task, which drains to the newest target. Returns the handle of the re-prime that served
    /// the latest target. Throws `budgetEscalated` when scrubbing outpaces what PMS can sustain.
    public func seek(to offsetMs: Int) async throws -> MediaSessionHandle {
        guard request != nil, loopbackBase != nil else { throw MediaSessionError.notOpen }
        pendingLatestOffsetMs = offsetMs
        if reprimeTask == nil {
            reprimeTask = Task { try await self.runReprimeLoop() }
        }
        return try await reprimeTask!.value
    }

    /// Drain the latest pending target until none remains. CRITICAL: `reprimeTask = nil` is set
    /// in the SAME atomic actor step as the failing `pendingLatestOffsetMs == nil` check (no
    /// await between), so a late `seek` either enqueues before this step (loop continues) or
    /// after the task returns (spawns a fresh task) — never strands a target on a dead task.
    private func runReprimeLoop() async throws -> MediaSessionHandle {
        var last: MediaSessionHandle?
        while true {
            guard let target = pendingLatestOffsetMs else {
                reprimeTask = nil                       // atomic with the guard — no await above
                if let last { return last }
                throw MediaSessionError.notOpen         // unreachable: seek always sets pending first
            }
            pendingLatestOffsetMs = nil
            switch reprimeBudget.requestRestart(now: now()) {
            case .allow:
                last = try await reprimeOnce(toOffsetMs: target)
            case .deferred(let remaining):
                pendingLatestOffsetMs = target          // keep the latest; wait out the cooldown
                try await Task.sleep(for: .seconds(remaining))
            case .escalate(let recentCount):
                reprimeTask = nil                       // atomic with the throw — no await below
                throw MediaSessionError.budgetEscalated(recentCount: recentCount)
            }
        }
    }

    /// One re-prime: stop the previous transcode, re-run the decision at `offsetMs`, recompute
    /// `localURL` against the persisted loopback base (listener untouched), bump generation.
    private func reprimeOnce(toOffsetMs offsetMs: Int) async throws -> MediaSessionHandle {
        guard let request, let loopbackBase else { throw MediaSessionError.notOpen }
        await stopPreviousTranscode(request)
        let (streamURL, decision) = await resolveStreamURL(request, offsetMs: offsetMs)
        self.lastDecision = decision
        guard let localURL = Self.loopbackURL(forStream: streamURL, base: loopbackBase) else {
            throw URLError(.badURL)
        }
        generationCounter += 1
        let handle = MediaSessionHandle(localURL: localURL, generation: generationCounter)
        current = handle
        return handle
    }

    /// Tell PMS to kill this session's current transcoder before the re-prime requests a new
    /// start.m3u8 for the same `sessionID`. Awaited (so the stop can't race past the new start
    /// and whack the replacement) but bounded to 2s so a dead network can't stall the re-prime.
    private func stopPreviousTranscode(_ request: MediaSessionRequest) async {
        let req = TranscodeRequest.stop(server: request.server, token: request.token,
                                        identity: request.identity, sessionID: request.sessionID)
        let send = controlSend
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await send(req) }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Test-only: the latest pending re-prime target (lets a coalescing test wait for the
    /// queue to settle before releasing a gate).
    func pendingOffsetMsForTest() -> Int? { pendingLatestOffsetMs }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd PMSKit && swift test 2>&1 | tail -30`
Expected: PASS — all proxy tests including the three new coalescing/ordering/escalation tests.

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift
git commit -m "MediaSessionProxy (#33): coalescing latest-wins seek re-prime + reprime budget"
```

---

### Task 4: Wire `PlaybackController` to the proxy-owned seek; delete the old machinery

**Files:**
- Modify: `VisionPlay/Player/PlaybackController.swift`

This is the app-target task. After it, run `xcodebuild` (see Build/Test Sequencing). No new unit test framework runs against the app target here; correctness is verified by build + the live probe (Task 5) + the manual checklist (Task 6).

- [ ] **Step 1: Make `mediaProxy` a lazy var wired with the control-plane sender**

Replace the property at line ~196:

```swift
    private let mediaProxy = MediaSessionProxy()
```

with:

```swift
    private lazy var mediaProxy = MediaSessionProxy(controlSend: { [weak self] req in
        guard let self else { throw URLError(.cancelled) }
        return try await self.sendControl(req)
    })
```

Add the main-actor helper near `stopPreviousTranscode` (after the `teardownMediaProxy()` method at line ~1177):

```swift
    /// Control-plane bridge for the media-session proxy (#33 Stage 2): the proxy builds PMSKit
    /// `PlexRequest`s for its decision/probe/stop calls and sends them through here. `client` is
    /// a recovery-swappable `var`, so reading it at call time picks up a post-`retry()` client.
    private func sendControl(_ req: PlexRequest) async throws -> Data {
        try await client.send(req)
    }
```

- [ ] **Step 2: Add the proxy-seek state properties**

Add near the `mediaProxyGeneration` property (line ~197):

```swift
    /// The offset (ms) we last primed the proxy at (initial resume or a proxy seek). The
    /// player's own resume seek fires a `timeJumpedNotification` landing here; suppressing
    /// jumps within `proxySeekEchoEpsilonMs` of it (by VALUE) keeps a re-prime from echoing
    /// into another re-prime. Replaces the old `hasPlayedThisItem`/`pendingSeekTargetMs` dance.
    private var lastProxySeekTargetMs = 0
    /// The proxy handle generation already loaded into the player, so coalesced `seek` callers
    /// (which all return the same final handle) don't each trigger a redundant `replaceItem`.
    private var lastLoadedProxyGeneration: Int?
    private static let proxySeekEchoEpsilonMs = 2000
```

- [ ] **Step 3: Rewrite the proxy open in `startStreaming` to build `MediaSessionRequest` and own the decision**

Replace the block from the `let transcode = TranscodeRequest(...)` (line ~1070) through the `load(playerItem, resumeOffsetMs: resumeMs)` (line ~1168) — i.e. the decision/probe section, the diagnostics seed, the `mediaProxy.open(origin:)` block, and the asset/load — with:

```swift
        // The proxy now owns the PMS decision/probe and the re-prime. Build the player-agnostic
        // request and let it resolve the stream URL + stand up the loopback (#33 Stage 2). On a
        // loopback bind failure it hands back the resolved direct URL so playback never depends
        // on the proxy being up (the Stage-1 fallback).
        let req = MediaSessionRequest(
            server: server, token: token, identity: identity,
            metadataKey: metadataKey, maxVideoBitrateKbps: requestedCap,
            sessionID: sessionID, mediaIndex: mediaIndex, partIndex: 0,
            burnSubtitleStreamID: nil,
            directStreamEnabled: UserDefaults.standard.bool(forKey: Self.directStreamEnabledKey))

        var assetURL: URL
        do {
            let handle = try await mediaProxy.open(req, offsetMs: resumeMs ?? 0)
            guard !Task.isCancelled, generation == playbackGeneration else {
                await teardownMediaProxy(); return
            }
            mediaProxyGeneration = handle.generation
            lastLoadedProxyGeneration = handle.generation
            assetURL = handle.localURL
            NSLog("PlaybackController: media proxy open ok, loopback=%@", handle.localURL.absoluteString)
        } catch let MediaSessionError.loopbackUnavailable(directURL) {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            assetURL = directURL
            NSLog("PlaybackController: media proxy loopback unavailable; using direct stream URL")
        } catch {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            NSLog("PlaybackController: media proxy open failed (%@); surfacing failure", String(describing: error))
            surfaceFailure(error)
            return
        }

        // Seed Stats-for-Nerds from the proxy's decision (it owns decision/probe now).
        let decision = await mediaProxy.currentDecision()
        diagnostics.applyStatic(item: item,
                                mediaIndex: mediaIndex,
                                decision: decision,
                                server: server,
                                targetBitrateKbps: maxVideoBitrateKbps)

        let asset = AVURLAsset(url: assetURL)
        let playerItem = AVPlayerItem(asset: asset)
        guard !Task.isCancelled, generation == playbackGeneration else {
            await teardownMediaProxy()
            return
        }
        load(playerItem, resumeOffsetMs: resumeMs)
```

(The comment block at lines 1080–1085 and 1107–1110 about the decision logic moves into the proxy, so it is removed here along with the code it described. The `// #4 probe (since removed)` comment block at 1134–1137 is informational and may be kept or dropped; dropping it is fine since the proxy comment now explains the media plane.)

- [ ] **Step 4: Set the echo baseline in `load`; remove the old per-item seek flags**

In `load(_:resumeOffsetMs:)`, replace the per-item reset block. Change lines 1349–1358 from:

```swift
        didSeek = false
        hasPlayedThisItem = false
        timeline.isReadyForReporting = false
        didApplySavedSubtitle = false
        didApplyAudioPreference = false
        pendingResumeMs = resumeOffsetMs
        // Seed the jump-delta baseline to the (re)start offset so the restarted stream's own
        // re-prime / HLS-discontinuity jumps register as SMALL deltas and don't re-trigger a
        // restart (#27 livelock). Updated continuously while `.playing` by the marker observer.
        lastSettledPlayheadSeconds = Double(resumeOffsetMs ?? 0) / 1000.0
```

to:

```swift
        didSeek = false
        timeline.isReadyForReporting = false
        didApplySavedSubtitle = false
        didApplyAudioPreference = false
        pendingResumeMs = resumeOffsetMs
        // Echo baseline (#33 Stage 2): the resume seer's own `timeJumpedNotification` lands at
        // this offset; `handleSeekJump` suppresses jumps within an epsilon of it so a re-prime
        // (or the initial resume) can't echo into another re-prime.
        lastProxySeekTargetMs = resumeOffsetMs ?? 0
```

- [ ] **Step 5: Repurpose the time-jump observer; strip the `.playing`-branch and marker-observer seek state**

In `installObservers`, change the `timeJumpedObserver` callback (line ~1484) from `self?.handleTimeJump()` to `self?.handleSeekJump()`:

```swift
        timeJumpedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSeekJump()
            }
        }
```

In the buffering observer's `.playing` branch (lines 1550–1555), delete the two lines that maintained the old seek state. Change:

```swift
                } else if status == .playing {
                    self.cancelStallWatchdog()
                    // The item has genuinely played: from here on, a time jump that strands the
                    // player starved is a dead seek (#25), not a slow initial prime.
                    self.hasPlayedThisItem = true
                    // Playback is advancing again — any pending seek target has been honored (or
                    // is moot). Don't carry it into a later, unrelated jump.
                    self.pendingSeekTargetMs = nil
                    // Real playback = the failure is over. Clear any surfaced error so its
```

to:

```swift
                } else if status == .playing {
                    self.cancelStallWatchdog()
                    // Real playback = the failure is over. Clear any surfaced error so its
```

In the marker observer (lines 1512–1516), delete the `lastSettledPlayheadSeconds` tracking block. Change:

```swift
                self.updateSkipMarker(at: time.seconds)
                // Drive the Up Next card (#15) off the same fine-grained observer.
                self.updateUpNext(at: time.seconds)
                // Track the settled playhead while genuinely playing, so `handleTimeJump` can
                // measure how far a subsequent jump moved (#27 livelock guard).
                if self.player.timeControlStatus == .playing, time.seconds.isFinite {
                    self.lastSettledPlayheadSeconds = time.seconds
                }
```

to:

```swift
                self.updateSkipMarker(at: time.seconds)
                // Drive the Up Next card (#15) off the same fine-grained observer.
                self.updateUpNext(at: time.seconds)
```

- [ ] **Step 6: Remove the stale `seekRestartTimer` teardown from `removeObservers`**

In `removeObservers` (lines 1608–1611), delete:

```swift
        // Cancel a pending seek-stall confirmation so it can't fire across a reload/teardown
        // and restart a freshly-loaded session at a stale offset (#25).
        seekRestartTimer?.invalidate()
        seekRestartTimer = nil
```

(Keep the `timeJumpedObserver` removal block immediately above it — the observer is still used.)

- [ ] **Step 7: Remove the `seekRestartBudget.reset()` calls in `reload`/`retry`**

In `reload(bitrateKbps:)`, delete line 971 `seekRestartBudget.reset()` and update the comment at 967–969 (it references the burst budget). Change:

```swift
        // A reload is a fresh session: restore the auto-retry budget and the seek-restart
        // burst budget (#27) — explicit user intent re-earns self-healing. (didScrobble is
        // intentionally NOT reset — the same content shouldn't re-scrobble mid-watch.)
        didAutoRetry = false
        seekRestartBudget.reset()
        removeObservers()
```

to:

```swift
        // A reload is a fresh session: restore the auto-retry budget — explicit user intent
        // re-earns self-healing. The proxy's re-prime budget is reset inside `mediaProxy.open`.
        // (didScrobble is intentionally NOT reset — the same content shouldn't re-scrobble.)
        didAutoRetry = false
        removeObservers()
```

In `retry()`, delete line 989 `seekRestartBudget.reset()` and its comment 988. Change:

```swift
        switchToRecoveryControlClient()
        // Explicit user intent re-earns the seek-restart burst budget (#27).
        seekRestartBudget.reset()
        playbackError.clear()
```

to:

```swift
        switchToRecoveryControlClient()
        playbackError.clear()
```

- [ ] **Step 8: Delete the old seek-restart machinery and add the proxy seek handlers**

Replace the entire `// MARK: - Seek-during-stall recovery (#25)` section — the `seekStallConfirmSeconds`, `seekJumpMinDeltaSeconds`, `seekRestartBudget` properties (lines 1904–1937) and the `handleTimeJump()` (1947–1992) and `confirmSeekStallRestart()` (2002–2065) methods — with the proxy-owned seek handlers. **Keep `seekableRangesDescription()` (line ~2069) — it has a non-seek consumer in `armStallWatchdog` (line ~1857).** The replacement (delete from the `// MARK: - Seek-during-stall recovery (#25)` line through the end of `confirmSeekStallRestart()`, i.e. the line before `seekableRangesDescription()`'s doc comment):

```swift
    // MARK: - Seek (proxy-owned re-prime, #33 Stage 2)

    /// Handle a playhead jump on the current item. Streaming only. The proxy now owns the
    /// re-prime, so the player's job is narrow: ignore the jump if it's the echo of an offset
    /// we just primed, or if the target is already buffered (AVKit seeks there natively);
    /// otherwise ask the proxy to re-prime the transcode at the new offset.
    ///
    /// `timeJumpedNotification` is the only in-process seek signal on visionOS (the AVKit
    /// user-navigation delegate callbacks are `API_UNAVAILABLE(visionos)`), and it fires for
    /// our own programmatic seeks too — hence the echo guard runs FIRST, by VALUE, so a
    /// re-prime's own resume seek can't trigger another re-prime.
    private func handleSeekJump() {
        guard isStreaming, !playbackError.isFailed else { return }
        let now = player.currentTime().seconds
        guard now.isFinite, now >= 0 else { return }
        let targetMs = Int(now * 1000)

        // Echo of an offset we just primed (initial resume or a prior proxy seek): not a user seek.
        if abs(targetMs - lastProxySeekTargetMs) <= Self.proxySeekEchoEpsilonMs { return }

        // Already buffered → AVKit can seek there natively; no re-prime needed.
        if isWithinLoadedRanges(seconds: now) { return }

        // Genuine deep seek outside the transcoder's produced range — re-prime through the proxy.
        repositionViaProxy(toMs: targetMs)
    }

    /// True if `seconds` falls within (a small slack around) any of the item's loaded time
    /// ranges — i.e. AVKit already has data there and can seek natively. Retires the old
    /// fixed `seekJumpMinDeltaSeconds` heuristic in favor of the player's real buffer state.
    private func isWithinLoadedRanges(seconds: Double) -> Bool {
        guard let item = player.currentItem else { return false }
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            let start = r.start.seconds
            let end = (r.start + r.duration).seconds
            guard start.isFinite, end.isFinite else { continue }
            if seconds >= start - 1, seconds <= end + 1 { return true }
        }
        return false
    }

    /// Re-prime the transcode at `targetMs` through the proxy (coalescing/latest-wins/budget all
    /// live in `MediaSessionProxy`), then swap the player to the new loopback URL. Budget
    /// escalation surfaces the failure overlay (Retry / lower quality resets it via `open`).
    private func repositionViaProxy(toMs targetMs: Int) {
        // Mark the target as primed up front so the reload's own resume seek is suppressed as an
        // echo, not read as a fresh user seek.
        lastProxySeekTargetMs = targetMs
        NSLog("%@", String(format: "[VP] seek: proxy re-prime to %dms", targetMs))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let handle = try await self.mediaProxy.seek(to: targetMs)
                self.loadProxyHandle(handle, resumeMs: targetMs)
            } catch let MediaSessionError.budgetEscalated(recentCount) {
                NSLog("%@", String(format: "[VP] seek: proxy reprime budget escalated (%d) — surfacing failure", recentCount))
                self.surfaceFailure(NSError(
                    domain: "VisionPlay.Playback", code: -1002,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Playback keeps falling behind the server. Tap Retry to rebuild the stream, or lower the quality setting."]))
            } catch {
                NSLog("PlaybackController: proxy reprime failed (%@)", String(describing: error))
                self.surfaceFailure(NSError(
                    domain: "VisionPlay.Playback", code: -1003,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't seek to that position. Tap Retry to rebuild the stream."]))
            }
        }
    }

    /// Swap the player to a re-primed proxy handle's loopback URL (the "new localURL +
    /// replaceItem" reload). Coalesced `seek` callers all return the same final handle, so the
    /// generation guard makes the redundant ones no-ops.
    private func loadProxyHandle(_ handle: MediaSessionHandle, resumeMs: Int) {
        guard handle.generation != lastLoadedProxyGeneration else { return }
        lastLoadedProxyGeneration = handle.generation
        mediaProxyGeneration = handle.generation
        let asset = AVURLAsset(url: handle.localURL)
        let playerItem = AVPlayerItem(asset: asset)
        removeObservers()
        load(playerItem, resumeOffsetMs: resumeMs)
    }

```

- [ ] **Step 9: Delete the now-orphaned `seekRestartTimer`, `hasPlayedThisItem`, `lastSettledPlayheadSeconds`, `pendingSeekTargetMs` properties**

Delete these four property declarations (lines ~165, ~170, ~178, ~186 — verify each is no longer referenced after Steps 4–8):

```swift
    private var seekRestartTimer: Timer?
```
```swift
    private var hasPlayedThisItem = false
```
```swift
    private var lastSettledPlayheadSeconds: Double = 0
```
```swift
    private var pendingSeekTargetMs: Int?
```

(Each of these had an explanatory doc comment above it; delete the comment with the property. Their surrounding context is documented in the file — confirm with a grep below that nothing else references them.)

- [ ] **Step 10: Verify no dangling references**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
rg -n "handleTimeJump|confirmSeekStallRestart|seekRestartTimer|hasPlayedThisItem|lastSettledPlayheadSeconds|pendingSeekTargetMs|seekRestartBudget|seekJumpMinDeltaSeconds|seekStallConfirmSeconds|mediaProxy\.open\(origin" VisionPlay/Player/PlaybackController.swift
```
Expected: NO output (all removed). If any line prints, fix it before building.

- [ ] **Step 11: Build the app (link-skip guard) and verify a fresh binary**

```bash
cd "$(git rev-parse --show-toplevel)"
rm -rf $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app | head -1)
/bin/ls -la "$APP/VisionPlay"
```
Expected: BUILD SUCCEEDED, and the binary mtime is fresh (now).

- [ ] **Step 12: Commit**

```bash
git add VisionPlay/Player/PlaybackController.swift
git commit -m "PlaybackController (#33 Stage 2): proxy-owned seek; delete player-side seek-restart machinery"
```

---

### Task 5: Extend the live proxy probe with a deep-offset seek hop

**Files:**
- Modify: `PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift`

This proves the proxy's `seek(to:)` re-primes against the LIVE server and the new `localURL` forwards a primed segment at the second offset. Opt-in (creds-gated); no secrets committed.

- [ ] **Step 1: Add a second-offset seek + forward check after the first segment check**

In `liveProxyForwardsPlaylistsAndSegmentThroughLoopback`, replace the final verdict block (from `let status = await proxy.status()` through `await proxy.stop(generation: handle.generation)`) with a seek hop that re-primes at a deeper offset and re-fetches start.m3u8 through the new loopback URL:

```swift
        // 4) Re-prime via the proxy's OWN seek to a deeper offset (#33 Stage 2). This drives the
        //    coalescing re-prime against the LIVE server: stop previous transcode → fresh
        //    decision at the new offset → new loopback URL. Then fetch start.m3u8 through the new
        //    URL to prove the re-primed media plane forwards. A second offset 600s past the first
        //    (clamped so we don't run past short items is the caller's concern via the env knob).
        let secondOffsetSeconds = cfg.offsetSeconds + 600
        let seekHandle: MediaSessionHandle
        do {
            seekHandle = try await proxy.seek(to: secondOffsetSeconds * 1000)
            print(String(format: ">>> PROXY seek: re-primed to %ds, loopback=%@",
                         secondOffsetSeconds, seekHandle.localURL.absoluteString))
        } catch {
            print(">>> PROXY VERDICT: seek re-prime threw — \(String(describing: error)).")
            await proxy.stop(generation: handle.generation); return
        }
        let reprimedOK = (seekHandle.generation > handle.generation)
            && seekHandle.localURL.absoluteString.contains("offset=\(secondOffsetSeconds)")
        let seekStart = await fetch(client, "start.m3u8@reprime", seekHandle.localURL)
        let seekForwarded = seekStart.map {
            (200...299).contains($0.status) && (String(data: $0.data, encoding: .utf8)?.contains("#EXTM3U") ?? false)
        } ?? false

        let status = await proxy.status()
        if realMedia && reprimedOK && seekForwarded {
            print(">>> PROXY VERDICT: PROXY OK — initial forward + a proxy-owned re-prime seek (new offset, new loopback URL, start.m3u8 forwarded) both succeeded against the live server (rotateCount=\(status.rotateCount)). Stage-2 seek is a correct re-prime.")
        } else if realMedia && !seekForwarded {
            print(">>> PROXY VERDICT: initial forward OK but the re-primed start.m3u8 did NOT forward (reprimedOK=\(reprimedOK)) — Stage-2 seek re-prime is broken.")
        } else {
            print(">>> PROXY VERDICT: forwarding works but the offset segment was empty/stub (rotateCount=\(status.rotateCount)) — a PMS prime issue (see LiveSegmentProbe), not a proxy fault.")
        }
        await proxy.stop(generation: seekHandle.generation)
```

- [ ] **Step 2: Build the probe (hermetic, no creds — must compile and no-op)**

Run: `cd PMSKit && swift test --filter LiveProxyProbe 2>&1 | tail -10`
Expected: builds; prints `>>> PROXY skipped: ...` (no creds) and the test passes as a no-op.

- [ ] **Step 3 (optional, only if live creds are present): run the live probe**

Run: `./scripts/live-proxy-probe.sh`
Expected (with creds): a `>>> PROXY VERDICT: PROXY OK ...` line confirming the re-prime seek forwarded. If no `scripts/plex-live.env`, this is skipped — note that in the report.

- [ ] **Step 4: Commit**

```bash
git add PMSKit/Tests/PMSKitTests/LiveProxyProbeTests.swift
git commit -m "LiveProxyProbe (#33 Stage 2): add a proxy-owned re-prime seek hop"
```

---

### Task 6: Update the manual testing checklist

**Files:**
- Modify: `TESTING-CHECKLIST.md`

- [ ] **Step 1: Add the Stage-2 proxy-seek section**

Add a new section to `TESTING-CHECKLIST.md` (place it near the existing seek/#25/#27 items; match the file's existing formatting/heading style):

```markdown
## #33 Stage 2 — proxy-owned seek/re-prime (manual sim)

These exercise the bug this stage fixes ("drag once = slow but works; drag twice = sticky +
reconnect hell") now that the proxy owns the re-prime. Claude self-serves screenshots/logs
(`xcrun simctl io booted screenshot`, `log show --predicate 'process == "VisionPlay"'`).

- [ ] **Single deep drag still works.** Start a transcoded item, let it play, drag the scrubber
      far ahead (minutes). Playback resumes at the new spot within a few seconds. Log shows a
      single `[VP] seek: proxy re-prime to <ms>` and no failure overlay.
- [ ] **Drag twice in quick succession — the original bug.** Drag deep, then immediately drag
      somewhere else before the first re-prime lands. Playback ends up at the SECOND target (not
      stuck at the first or snapped back to the start), with no "Reconnecting…"/Retry overlay and
      no reconnect loop. Log shows the intermediate target coalesced away (latest-wins).
- [ ] **Small in-buffer scrub is instant.** Drag a few seconds within already-buffered content.
      It seeks natively (no `proxy re-prime` log line, no transcode restart).
- [ ] **Resume doesn't self-trigger a re-prime.** Open an item with a saved deep resume point.
      It resumes once and keeps playing — no spurious `proxy re-prime` line from the resume seek
      (echo suppression).
- [ ] **Scrub-spam escalates gracefully.** Rapidly drag many times. After the burst budget is
      spent the failure overlay appears (not an endless rebuild). Tapping Retry restores playback
      and re-earns the budget.
- [ ] **Quality reload / audio switch still resume at the playhead** (regression — these share
      the rebuild path; the proxy re-opens and resets its budget).
- [ ] **Forced upstream wedge still self-heals** (manual: kill/restore the server mid-play; the
      loopback rotate recovers without a Retry tap). rotateCount > 0 in `proxy.status()` logging.
```

- [ ] **Step 2: Commit**

```bash
git add TESTING-CHECKLIST.md
git commit -m "TESTING-CHECKLIST: add #33 Stage 2 proxy-owned seek manual items"
```

---

## Self-Review (run after the plan is written; fix inline)

- **Spec coverage** (spec testing strategy → task):
  - coalescing-never-drops-latest → Task 3 `testSeekCoalescesToLatestAndDropsIntermediate` ✓
  - latest-wins-under-N → Task 3 (same test asserts r1==r2==r3 and o2 dropped) ✓
  - budget-escalation-throws → Task 3 `testSeekEscalatesWhenReprimeBudgetExhausted` ✓
  - decision-re-run-on-reprime → Task 2 `testOpenResolvesStreamURLWithOffsetAndRunsDecision` (open) + Task 3 `testSeekStopsPreviousTranscodeBeforeRepriming` asserts the reprime decision carries `offset=90` ✓
  - stopPreviousTranscode-before-reprime → Task 3 `testSeekStopsPreviousTranscodeBeforeRepriming` ✓
  - live-proxy-probe seek-hop → Task 5 ✓
  - manual sim checklist → Task 6 ✓
  - contract `open/seek/stop/status` → `open(_:offsetMs:)` (Task 2), `seek(to:)` (Task 3), `stop`/`status` unchanged ✓
  - "New localURL + replaceItem" reload → Task 4 `loadProxyHandle` ✓
  - "Proxy owns PMS decision" → Task 2 `resolveStreamURL` ✓
  - open-failure surfaces as Stage 1 (direct-URL fallback) → Task 4 `loopbackUnavailable` catch ✓
- **Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows full code. ✓
- **Type consistency:** `standUpLoopback(forStream:)`, `loopbackURL(forStream:base:)`, `open(_:offsetMs:)`, `seek(to:)`, `currentDecision()`, `pendingOffsetMsForTest()`, `MediaSessionError.{notOpen,budgetEscalated(recentCount:),loopbackUnavailable(directURL:)}`, `MediaSessionRequest` memberwise init — names match across the proxy, the tests, and the PlaybackController wiring. ✓
- **Sequencing:** PMSKit test target compiles after every PMSKit task (LiveProxyProbe migrated in Task 2); app target only built at Task 4. ✓
- **Don't-regress:** `X-Plex-Client-Profile-Name=Safari` is built by `TranscodeRequest` (untouched); `seekableRangesDescription()` retained (consumer at `armStallWatchdog`); no tokens/hosts hardcoded. ✓
