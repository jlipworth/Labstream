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

    /// Production initializer: build the upstream `URLSession` from `mediaUpstream`, mirroring
    /// the app's trust posture (default trust works for `*.plex.direct`; pass a host-scoped
    /// insecure-LAN delegate only when the user enabled it).
    public init(timeout: TimeInterval = 20, trustDelegate: URLSessionDelegate? = nil) {
        // A box so `rebuild` can swap the session that `fetch` reads (the one thing
        // AVFoundation's own media-plane pool won't do — guarantee a fresh socket).
        let box = SessionBox(config: PlexSessionConfiguration.mediaUpstream(timeout: timeout),
                             delegate: trustDelegate)
        self.upstreamFetch = { req in try await box.fetch(req) }
        self.rebuildUpstream = { box.rebuild() }
    }

    /// Test initializer: inject the upstream fetcher directly (no live session). `rebuild` is a
    /// no-op because there is no real socket to rotate; the rotate *count* still increments.
    init(upstreamFetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.upstreamFetch = upstreamFetch
        self.rebuildUpstream = {}
    }

    public func open(origin pmsStart: URL) async throws -> MediaSessionHandle {
        // Re-open (e.g. a bitrate reload) reuses this proxy: tear down any prior listener
        // before binding a fresh one so we don't leak the old port/connection.
        if current != nil {
            origin.stop()
            connection = nil
            current = nil
        }
        // Derive PMS origin (scheme/host/port) and keep the loopback-facing path+query verbatim.
        guard let comps = URLComponents(url: pmsStart, resolvingAgainstBaseURL: false),
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

        // The loopback base (and thus the rewriter) is only known once the listener is bound,
        // but no request arrives until `open` returns and the renderer loads `localURL` — so a
        // box that we populate just after `start` is safe and avoids a chicken-and-egg.
        let rewriterBox = RewriterBox()
        let port = try await origin.start { [mapper, conn, rewriterBox] head in
            await Self.serve(head, mapper: mapper, connection: conn, rewriter: rewriterBox.value)
        }

        var loop = URLComponents()
        loop.scheme = "http"
        loop.host = "127.0.0.1"
        loop.port = port
        loop.path = comps.path
        loop.percentEncodedQuery = comps.percentEncodedQuery
        guard let localURL = loop.url,
              let loopbackBase = URL(string: "http://127.0.0.1:\(port)") else {
            throw URLError(.badURL)
        }
        rewriterBox.set(PlaylistRewriter(upstreamBase: upstreamBase, loopbackBase: loopbackBase))

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
