import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Phase 0 — LIVE optimize/background-processing DISCOVERY probe (offline-download
/// redesign). OPT-IN: runs only when PLEX_LIVE_* env vars are present, otherwise a no-op,
/// so plain `swift test` and CI stay hermetic and no secret is committed.
///
/// PURPOSE: discover the server-specific Media Optimizer contract that cannot be reached
/// from CI — the background-processing playlist key, the real target tag IDs, the POST
/// grammar PMS accepts, how a finished optimized Part appears, and that a static part's
/// `?download=1` carries a real Content-Length. It only LOGS (`>>> LIVE` lines); it does not
/// assert a contract, because the contract is exactly what we're discovering.
///
/// Run it (creds live in a gitignored env file — reuse scripts/plex-live.env):
///   ./scripts/live-optimize-probe.sh
/// or directly:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveOptimizeProbe
///
/// Faithful to the app: requests go through `URLSession.shared.data(for:)` exactly like
/// `PlexClient.send`, so the wire shape matches the visionOS app.
struct LiveOptimizeProbeTests {

    private struct LiveConfig {
        let base: LiveProbeConfig
        let metadataKey: String          // /library/metadata/<ratingKey>
        let ratingKey: String
        let title: String
        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let base = LiveProbeConfig(env),
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = metadataKey
            self.ratingKey = (metadataKey as NSString).lastPathComponent
            self.title = env["PLEX_LIVE_TITLE"] ?? "VisionPlay Probe Optimize"
        }
    }

    /// Build a request the way the app does: standard identity headers + token, query items.
    private func request(_ cfg: LiveConfig, path: String, method: String = "GET",
                         query: [URLQueryItem] = []) -> PlexRequest {
        PlexRequest(url: cfg.server.appendingPathComponent(path),
                    method: method,
                    queryItems: query,
                    headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
    }

    /// Send + dump status, headers of interest, and raw body. The raw body carries real media
    /// titles/paths, so it is scrubbed through `LiveProbeConfig.redact` before logging (public repo).
    /// Returns (body, status) or nil on a transport error.
    @discardableResult
    private func dump(_ label: String, _ req: PlexRequest, _ cfg: LiveConfig) async -> (Data, Int)? {
        do {
            let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentLength = http?.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            let rawBody = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-utf8>"
            let body = LiveProbeConfig.redact(rawBody, token: cfg.token, server: cfg.server)
            print("""
            >>> LIVE [\(label)] HTTP \(status), Content-Length=\(contentLength), \(data.count) bytes
            >>> LIVE [\(label)] body:
            \(body)
            >>> LIVE [\(label)] end body
            """)
            return (data, status)
        } catch {
            print(">>> LIVE [\(label)] ERROR: \(error)")
            return nil
        }
    }

    @Test func liveOptimizeDiscoveryDump() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }

        // 1. Background-processing playlist: GET /playlists?type=42 → read its `key`.
        await dump("playlists.type42",
                   request(cfg, path: "/playlists", query: [.init(name: "type", value: "42")]), cfg)

        // 2. Server's real media-processing targets (name + targetTagID). The exact path is
        //    what we're confirming; try the best-known endpoint and log whatever comes back.
        await dump("mediaProcessingTargets", request(cfg, path: "/media/processing/targets"), cfg)

        // 3. Item metadata BEFORE optimize — snapshot existing Media/Part ids. This is a
        //    deterministic authenticated GET: assert it succeeds so the probe fails loudly on an
        //    unreachable server / bad token instead of "passing" green. (The experimental optimize
        //    POSTs below stay logged-only — discovering their accepted shape is the point.)
        let before = await dump("metadata.before", request(cfg, path: cfg.metadataKey), cfg)
        #expect(before?.1 == 200, "metadata.before expected HTTP 200, got \(before?.1.description ?? "transport error")")

        // 4. Attempt to enqueue an optimize via the playlist `items` grammar. We POST to the
        //    conventional background-processing items path; READ THE STATUS/BODY to learn the
        //    accepted shape. (If step 1 reported a different `key`, re-run with that path.)
        let optimizeItems: [URLQueryItem] = [
            .init(name: "Item[type]", value: "42"),
            .init(name: "Item[title]", value: cfg.title),
            .init(name: "Item[target]", value: "Optimized for TV"),
            // targetTagID is SERVER-SPECIFIC — substitute the id from step 2 when re-running.
            .init(name: "Item[targetTagID]", value: "2"),
            .init(name: "Item[Location][uri]",
                  value: "server://\(cfg.identity.clientIdentifier)/com.plexapp.plugins.library\(cfg.metadataKey)"),
            .init(name: "Item[MediaSettings][videoQuality]", value: "100"),
            .init(name: "Item[MediaSettings][maxVideoBitrate]", value: "8000"),
            .init(name: "Item[MediaSettings][videoResolution]", value: "1920x1080"),
        ]
        await dump("optimize.post",
                   request(cfg, path: "/playlists/items", method: "POST", query: optimizeItems), cfg)

        // 5. Item metadata AFTER optimize — show how the new optimized Media/Part appears
        //    (diff its ids against step 3). May need a delay before the part materializes.
        await dump("metadata.after", request(cfg, path: cfg.metadataKey), cfg)

        // 6. Static-part Content-Length: HEAD the FIRST existing part with ?download=1 and
        //    confirm a real Content-Length (proves the static-file download premise).
        if let (data, _) = await dump("metadata.forParts", request(cfg, path: cfg.metadataKey), cfg),
           let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data),
           let partKey = decoded.mediaContainer.metadata.first?.media?.first?.part.first?.key {
            var headReq = request(cfg, path: partKey,
                                  query: [.init(name: "download", value: "1"),
                                          .init(name: "X-Plex-Token", value: cfg.token)])
            headReq = PlexRequest(url: headReq.url, method: "HEAD",
                                  queryItems: headReq.queryItems, headers: headReq.headers)
            await dump("part.download.head", headReq, cfg)
        }

        print(">>> LIVE optimize discovery complete — read the lines above for the contract.")
    }
}
