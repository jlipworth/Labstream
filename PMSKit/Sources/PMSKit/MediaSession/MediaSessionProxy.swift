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

    /// Production initializer: build the upstream `URLSession` from `mediaUpstream`, mirroring
    /// the app's trust posture (default trust works for `*.plex.direct`; pass a host-scoped
    /// insecure-LAN delegate only when the user enabled it).
    public init(timeout: TimeInterval = 20,
                trustDelegate: URLSessionDelegate? = nil,
                controlSend: @escaping @Sendable (PlexRequest) async throws -> Data,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        // A box so `rebuild` can swap the session that `fetch` reads (the one thing
        // AVFoundation's own media-plane pool won't do — guarantee a fresh socket).
        let box = SessionBox(config: PlexSessionConfiguration.mediaUpstream(timeout: timeout),
                             delegate: trustDelegate)
        self.upstreamFetch = { req in try await box.fetch(req) }
        self.rebuildUpstream = { box.rebuild() }
        self.controlSend = controlSend
        self.now = now
    }

    /// Test initializer: inject the upstream fetcher directly (no live session). `controlSend`
    /// defaults to a no-op (transport tests don't exercise the decision path); `now` defaults
    /// to real uptime but is overridable for deterministic budget tests. `rebuild` is a no-op
    /// because there is no real socket to rotate; the rotate *count* still increments.
    init(upstreamFetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
         controlSend: @escaping @Sendable (PlexRequest) async throws -> Data = { _ in Data() },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.upstreamFetch = upstreamFetch
        self.rebuildUpstream = {}
        self.controlSend = controlSend
        self.now = now
    }

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

    public func stop(generation: Int) async {
        guard current?.generation == generation else { return }   // ignore stale teardown
        origin.stop()
        connection = nil
        current = nil
    }

    public func status() async -> MediaSessionStatus {
        let rotates = (await connection?.rotateCount) ?? 0
        return MediaSessionStatus(generation: current?.generation ?? 0,
                                  isOpen: current != nil,
                                  rotateCount: rotates)
    }

    /// One inbound request → upstream fetch (with rotate) → playlist rewrite → response.
    private static func serve(_ head: HTTPRequestHead,
                              mapper: UpstreamURLMapper,
                              connection: UpstreamConnection,
                              rewriter: PlaylistRewriter?) async -> HTTPResponse {
        guard let upstreamURL = mapper.upstreamURL(forTarget: head.target) else {
            return HTTPResponse(status: 400, reason: "Bad Request", headers: [], body: Data())
        }
        var req = URLRequest(url: upstreamURL)
        req.httpMethod = head.method
        // Forward the request headers AVKit relies on (Range drives HLS byte-range segments).
        for name in ["Range", "Accept", "Accept-Encoding", "User-Agent"] {
            if let v = head.value(for: name) { req.setValue(v, forHTTPHeaderField: name) }
        }
        do {
            let (data, resp) = try await connection.send(req)
            let contentType = resp.value(forHTTPHeaderField: "Content-Type")
            let body = rewriter?.rewrite(data, contentType: contentType) ?? data
            // Forward upstream response headers except framing/encoding ones we (re)compute.
            // Notably preserves Content-Range/Accept-Ranges so 206 range responses stay valid;
            // body length is reset by `HTTPResponse.serialized()`.
            let drop: Set<String> = ["content-length", "connection", "transfer-encoding", "content-encoding"]
            var headers: [(name: String, value: String)] = []
            for (k, v) in resp.allHeaderFields {
                guard let name = k as? String, let value = v as? String,
                      !drop.contains(name.lowercased()) else { continue }
                headers.append((name, value))
            }
            return HTTPResponse(status: resp.statusCode, reason: Self.reason(resp.statusCode),
                                headers: headers, body: body)
        } catch {
            return HTTPResponse(status: 502, reason: "Bad Gateway", headers: [], body: Data())
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "OK"
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
        // Read the session under the lock in a *synchronous* scope (NSLock is unavailable
        // across an await), then perform the request without holding it.
        let (data, resp) = try await currentSession().data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func currentSession() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func rebuild() {
        lock.lock()
        session.invalidateAndCancel()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        lock.unlock()
    }
}

/// Thread-safe holder for the playlist rewriter, populated immediately after the loopback
/// listener binds (its port — and thus the loopback base — is not known until then).
private final class RewriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rewriter: PlaylistRewriter?
    func set(_ r: PlaylistRewriter) { lock.lock(); rewriter = r; lock.unlock() }
    var value: PlaylistRewriter? { lock.lock(); defer { lock.unlock() }; return rewriter }
}
