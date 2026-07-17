// Apple-only: depends on LoopbackOrigin (Network framework). Gated so PMSKit builds on Linux
// for CI. The app (Apple-only) always has canImport(Network) == true. See LoopbackOrigin / #115.
#if canImport(Network)
import Foundation

/// Player-agnostic loopback media forwarder. It interposes an app-owned HTTP origin between
/// a renderer and an already-resolved HLS stream so the media plane can rotate a wedged
/// upstream socket and rewrite playlists. Plex playback decisions and stream starts are owned
/// by `PlaybackController`, not this proxy; keep this type stream-only.
public actor MediaSessionProxy {
    private let origin = LoopbackOrigin()
    private let upstreamFetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let rebuildUpstream: @Sendable () -> Void
    private let now: @Sendable () -> TimeInterval
    private let strippedPlaylistQueryItemNames: Set<String>
    private let injectedPlaylistStartTimeOffsetSeconds: Double?
    /// GH #196 spike (b): DV attributes injected into master playlists (experimental gate).
    private let dolbyVisionInjection: MediaSessionDolbyVisionInjection?
    /// Extra headers applied to every upstream fetch (Plex media-plane requests can 400
    /// without the X-Plex identity header set — see PlaybackController's asset options).
    private let extraUpstreamHeaders: [String: String]
    private var connection: UpstreamConnection?
    private var current: MediaSessionHandle?

    /// The loopback base (`http://127.0.0.1:<port>`) for the current forwarding session.
    private var loopbackBase: URL?
    /// Strictly increasing handle generation across loopback opens.
    private var generationCounter = 0

    /// Production initializer: build the upstream `URLSession` from `mediaUpstream`, mirroring
    /// the app's trust posture (default trust works for `*.plex.direct`; pass a host-scoped
    /// insecure-LAN delegate only when the user enabled it).
    public init(timeout: TimeInterval = 20,
                trustDelegate: URLSessionDelegate? = nil,
                strippedPlaylistQueryItemNames: Set<String> = [],
                injectedPlaylistStartTimeOffsetSeconds: Double? = nil,
                dolbyVisionInjection: MediaSessionDolbyVisionInjection? = nil,
                extraUpstreamHeaders: [String: String] = [:],
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        // A box so `rebuild` can swap the session that `fetch` reads (the one thing
        // AVFoundation's own media-plane pool won't do — guarantee a fresh socket).
        let box = SessionBox(config: PlexSessionConfiguration.mediaUpstream(timeout: timeout),
                             delegate: trustDelegate)
        self.upstreamFetch = { req in try await box.fetch(req) }
        self.rebuildUpstream = { box.rebuild() }
        self.now = now
        self.strippedPlaylistQueryItemNames = strippedPlaylistQueryItemNames.map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }
        self.injectedPlaylistStartTimeOffsetSeconds = injectedPlaylistStartTimeOffsetSeconds
        self.dolbyVisionInjection = dolbyVisionInjection
        self.extraUpstreamHeaders = extraUpstreamHeaders
    }

    /// Test initializer: inject the upstream fetcher directly (no live session). `rebuild` is
    /// a no-op because there is no real socket to rotate; the rotate *count* still increments.
    init(upstreamFetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
         strippedPlaylistQueryItemNames: Set<String> = [],
         injectedPlaylistStartTimeOffsetSeconds: Double? = nil,
         dolbyVisionInjection: MediaSessionDolbyVisionInjection? = nil,
         extraUpstreamHeaders: [String: String] = [:],
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.upstreamFetch = upstreamFetch
        self.rebuildUpstream = {}
        self.now = now
        self.strippedPlaylistQueryItemNames = strippedPlaylistQueryItemNames.map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }
        self.injectedPlaylistStartTimeOffsetSeconds = injectedPlaylistStartTimeOffsetSeconds
        self.dolbyVisionInjection = dolbyVisionInjection
        self.extraUpstreamHeaders = extraUpstreamHeaders
    }

    /// Bind the app-owned loopback origin in front of `streamURL`'s PMS host and return a
    /// handle whose `localURL` mirrors `streamURL`'s path+query onto the loopback.
    public func standUpLoopback(forStream streamURL: URL) async throws -> MediaSessionHandle {
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
            now: now,
            rebuild: rebuildUpstream,
            fetch: upstreamFetch)
        self.connection = conn

        let rewriterBox = RewriterBox()
        let port: Int
        do {
            port = try await origin.start { [mapper, conn, rewriterBox, extraUpstreamHeaders] head in
                await Self.serve(head, mapper: mapper, connection: conn, rewriter: rewriterBox.value,
                                 extraHeaders: extraUpstreamHeaders)
            }
        } catch {
            origin.stop()
            connection = nil
            current = nil
            loopbackBase = nil
            throw error
        }

        guard let loopbackBase = URL(string: "http://127.0.0.1:\(port)"),
              let localURL = Self.loopbackURL(forStream: streamURL, base: loopbackBase) else {
            origin.stop()
            connection = nil
            current = nil
            self.loopbackBase = nil
            throw URLError(.badURL)
        }
        self.loopbackBase = loopbackBase
        rewriterBox.set(PlaylistRewriter(upstreamBase: upstreamBase,
                                         loopbackBase: loopbackBase,
                                         strippedQueryItemNames: strippedPlaylistQueryItemNames,
                                         injectedStartTimeOffsetSeconds: injectedPlaylistStartTimeOffsetSeconds,
                                         dolbyVisionInjection: dolbyVisionInjection))

        generationCounter += 1
        let handle = MediaSessionHandle(localURL: localURL, generation: generationCounter)
        current = handle
        return handle
    }

    /// Map a PMS stream URL's path+query onto the loopback base (scheme/host/port from `base`).
    /// AVKit resolves the playlist's relative URIs against this, routing every hop back through
    /// the proxy.
    static func loopbackURL(forStream streamURL: URL, base loopbackBase: URL) -> URL? {
        guard let streamComps = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
              var baseComps = URLComponents(url: loopbackBase, resolvingAgainstBaseURL: false)
        else { return nil }
        baseComps.path = streamComps.path
        baseComps.percentEncodedQuery = streamComps.percentEncodedQuery
        return baseComps.url
    }

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
                              rewriter: PlaylistRewriter?,
                              extraHeaders: [String: String] = [:]) async -> HTTPResponse {
        guard let upstreamURL = mapper.upstreamURL(forTarget: head.target) else {
            return HTTPResponse(status: 400, reason: "Bad Request", headers: [], body: Data())
        }
        var req = URLRequest(url: upstreamURL)
        req.httpMethod = head.method
        // Forward the request headers AVKit relies on (Range drives HLS byte-range segments).
        for name in ["Range", "Accept", "Accept-Encoding", "User-Agent"] {
            if let v = head.value(for: name) { req.setValue(v, forHTTPHeaderField: name) }
        }
        // Identity headers for upstreams that require them (Plex media plane).
        for (name, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: name)
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
#endif
