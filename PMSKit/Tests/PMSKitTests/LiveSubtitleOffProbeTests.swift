import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless live probe for the "subtitles show while the picker says Off" class of bug.
/// Answers, against the REAL server, the two questions a unit test cannot:
///
///   1. What subtitle stream (if any) is SELECTED on the part server-side? Plex part-level
///      stream selection is account-sticky and shared across every Plex client, so a
///      selection made elsewhere (or left behind by our own burn path) silently shapes what
///      `subtitles=auto` muxes/burns into our HLS.
///   2. What legible renditions does the app's actual `subtitles=auto` HLS master carry, and
///      with which DEFAULT/AUTOSELECT/FORCED flags? AVFoundation renders FORCED/default
///      renditions matching the audio language even after `select(nil, in: group)` (see the
///      GH #196 note in JellyfinPlayback.visionOSDeviceProfile), so these flags are exactly
///      what decides whether "Off" can be overridden on screen.
///
/// OPT-IN and hermetic by default (same contract as the other Live*Probe tests): with no env
/// config it prints a skip line and returns. The probe item is resolved by SEARCH so the query
/// (a media title) stays in the gitignored env file, never in the repo:
///
///   PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN          (required, shared with the other probes)
///   PLEX_LIVE_SUBTITLE_OFF_QUERY                (required — search title; for a show the most
///                                                recently viewed episode is probed, i.e. the
///                                                one the user just watched)
///   PLEX_LIVE_SUBTITLE_OFF_KBPS                 (optional — capped-lane bitrate, default 3000)
///
/// Run:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveSubtitleOffProbe
///
/// Output lines are prefixed `>>> SUBOFF` and redacted via `LiveProbeConfig.redact`. Stream
/// dumps print language codes/codecs/flags, not display titles (probe output itself may still
/// contain the searched title — read it, don't commit it).
struct LiveSubtitleOffProbeTests {

    private struct Config {
        let base: LiveProbeConfig
        let query: String
        let cappedKbps: Int

        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let base = LiveProbeConfig(env),
                  let query = env["PLEX_LIVE_SUBTITLE_OFF_QUERY"], !query.isEmpty
            else { return nil }
            self.base = base
            self.query = query
            self.cappedKbps = env["PLEX_LIVE_SUBTITLE_OFF_KBPS"].flatMap(Int.init) ?? 3_000
        }
    }

    // MARK: - Plumbing

    private func get(_ cfg: Config, path: String, query: [URLQueryItem] = []) async throws -> (Int, Data) {
        guard var components = URLComponents(url: cfg.server, resolvingAgainstBaseURL: false) else {
            return (-1, Data())
        }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return (-1, Data()) }
        var req = URLRequest(url: url)
        for (name, value) in PlexHeaders.standard(identity: cfg.identity, token: cfg.token) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    /// Resolve the search query to the metadata key of the item to probe. For a show hit,
    /// descend to allLeaves and pick the most recently viewed episode — the one whose part
    /// selection state actually shaped the user's last session.
    private func resolveItem(_ cfg: Config) async throws -> String? {
        let (status, data) = try await get(cfg, path: "/hubs/search",
                                           query: [.init(name: "query", value: cfg.query),
                                                   .init(name: "limit", value: "10")])
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any],
              let hubs = container["Hub"] as? [[String: Any]] else {
            print(">>> SUBOFF search HTTP \(status) — cannot resolve query.")
            return nil
        }
        let hits = hubs.flatMap { ($0["Metadata"] as? [[String: Any]]) ?? [] }
        func ratingKey(ofType type: String) -> String? {
            hits.first { ($0["type"] as? String) == type }?["ratingKey"] as? String
        }
        if let show = ratingKey(ofType: "show") {
            let (leafStatus, leafData) = try await get(cfg, path: "/library/metadata/\(show)/allLeaves")
            guard leafStatus == 200,
                  let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: leafData) else {
                print(">>> SUBOFF allLeaves HTTP \(leafStatus) — cannot list episodes.")
                return nil
            }
            let episodes = decoded.mediaContainer.metadata
            let probed = episodes.max { ($0.lastViewedAt ?? 0) < ($1.lastViewedAt ?? 0) }
                ?? episodes.first
            guard let probed else { return nil }
            print(">>> SUBOFF resolved show → episode ratingKey=\(probed.ratingKey) lastViewedAt=\(probed.lastViewedAt.map(String.init) ?? "nil")")
            return "/library/metadata/\(probed.ratingKey)"
        }
        if let leaf = ratingKey(ofType: "episode") ?? ratingKey(ofType: "movie") {
            print(">>> SUBOFF resolved leaf ratingKey=\(leaf)")
            return "/library/metadata/\(leaf)"
        }
        print(">>> SUBOFF search returned no show/episode/movie hit.")
        return nil
    }

    /// Dump the part's subtitle streams with the flags that matter (selected/default/forced).
    /// Returns the part so the caller can reason about what `subtitles=auto` will do with it.
    private func dumpPartSelection(_ cfg: Config, metadataKey: String) async throws -> Part? {
        let (status, data) = try await get(cfg, path: metadataKey,
                                           query: [.init(name: "includeStreams", value: "1")])
        guard status == 200,
              let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data),
              let part = decoded.mediaContainer.metadata.first?.media?.first?.part.first else {
            print(">>> SUBOFF metadata HTTP \(status) — cannot read part streams.")
            return nil
        }
        let audio = part.audioStreams.first { $0.selected == true } ?? part.audioStreams.first
        print(">>> SUBOFF part=\(part.id) audioLang=\(audio?.languageTag ?? audio?.languageCode ?? "nil") subtitleStreams=\(part.subtitleStreams.count)")
        for s in part.subtitleStreams {
            print(">>> SUBOFF   sub id=\(s.id) codec=\(s.codec ?? "nil") lang=\(s.languageTag ?? s.languageCode ?? "nil") selected=\(s.selected.map(String.init) ?? "nil") default=\(s.isDefault.map(String.init) ?? "nil") forced=\(s.forced.map(String.init) ?? "nil")")
        }
        if part.subtitleStreams.contains(where: { $0.selected == true }) {
            print(">>> SUBOFF VERDICT: a subtitle stream IS selected on the part server-side — subtitles=auto will mux/burn it regardless of any client-side Off.")
        } else {
            print(">>> SUBOFF part has no server-side selected subtitle stream.")
        }
        return part
    }

    /// Fetch the app's real `subtitles=auto` HLS master at the given cap and print every
    /// legible-rendition line with its flags, then stop the transcode session it spun up.
    private func dumpManifest(_ cfg: Config, metadataKey: String, kbps: Int, label: String) async throws {
        let sessionID = "live-suboff-\(UUID().uuidString)"
        let request = TranscodeRequest(server: cfg.server, token: cfg.token, identity: cfg.identity,
                                       metadataKey: metadataKey,
                                       maxVideoBitrateKbps: kbps,
                                       sessionID: sessionID,
                                       mediaIndex: 0, partIndex: 0)
        defer {
            let stop = TranscodeRequest.stop(server: cfg.server, token: cfg.token,
                                             identity: cfg.identity, sessionID: sessionID)
            Task { _ = try? await URLSession.shared.data(for: stop.urlRequest()) }
        }

        if let (decisionData, _) = try? await URLSession.shared.data(for: request.decisionRequest().urlRequest()),
           let decision = try? JSONDecoder().decode(DecisionResponse.self, from: decisionData) {
            print(">>> SUBOFF [\(label)] decision video=\(decision.videoDecision ?? "nil") audio=\(decision.audioDecision ?? "nil")")
        }

        var req = URLRequest(url: request.startM3U8URL())
        for (name, value) in PlexHeaders.standard(identity: cfg.identity, token: cfg.token) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200, "live [\(label)] start.m3u8 expected HTTP 200, got \(status)")
        guard let manifest = String(data: data, encoding: .utf8) else {
            print(">>> SUBOFF [\(label)] start.m3u8 body not utf8 (\(data.count) bytes).")
            return
        }
        let legible = manifest.split(separator: "\n").filter {
            $0.contains("TYPE=SUBTITLES") || $0.contains("SUBTITLES=")
        }
        if legible.isEmpty {
            print(">>> SUBOFF [\(label)] master carries NO legible renditions.")
        }
        for line in legible {
            print(">>> SUBOFF [\(label)] \(LiveProbeConfig.redact(String(line), token: cfg.token, server: cfg.server))")
        }
    }

    /// PUT the part-level subtitle selection (0 = deselect) — the same mechanic the app's
    /// burn path uses, and the mechanic an explicit "Off" must use to stop `subtitles=auto`
    /// from burning a server-selected stream.
    private func putSubtitleSelection(_ cfg: Config, partID: Int, streamID: Int) async throws -> Int {
        let req = StreamSelectionRequest.selectSubtitleStream(server: cfg.server, token: cfg.token,
                                                              identity: cfg.identity,
                                                              partID: partID,
                                                              subtitleStreamID: streamID)
        let (_, response) = try await URLSession.shared.data(for: req.urlRequest())
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    @Test func liveSubtitleOffProbe() async throws {
        guard let cfg = Config() else {
            print(">>> SUBOFF skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SUBTITLE_OFF_QUERY to run.")
            return
        }
        guard let metadataKey = try await resolveItem(cfg) else { return }
        let part = try await dumpPartSelection(cfg, metadataKey: metadataKey)
        // Copy lane (Maximum) and a capped transcode lane — the muxed/burned outcome can differ.
        try await dumpManifest(cfg, metadataKey: metadataKey, kbps: 200_000, label: "copy")
        try await dumpManifest(cfg, metadataKey: metadataKey, kbps: cfg.cappedKbps, label: "capped")

        // Optional MUTATION phase (PLEX_LIVE_SUBTITLE_OFF_MUTATE=1): prove causation by
        // deselecting the part's subtitle, re-probing, then RESTORING the original selection —
        // server state is left exactly as found. This is the flip that shows the part-level
        // selection (not the item, not the profile) is what makes `subtitles=auto` burn.
        guard ProcessInfo.processInfo.environment["PLEX_LIVE_SUBTITLE_OFF_MUTATE"] == "1",
              let part,
              let selected = part.subtitleStreams.first(where: { $0.selected == true }) else { return }
        let clearStatus = try await putSubtitleSelection(cfg, partID: part.id, streamID: 0)
        print(">>> SUBOFF MUTATE deselect part=\(part.id) HTTP \(clearStatus)")
        guard clearStatus == 200 else { return }
        try await dumpManifest(cfg, metadataKey: metadataKey, kbps: 200_000, label: "copy-deselected")
        try await dumpManifest(cfg, metadataKey: metadataKey, kbps: cfg.cappedKbps, label: "capped-deselected")
        let restoreStatus = try await putSubtitleSelection(cfg, partID: part.id, streamID: selected.id)
        print(">>> SUBOFF MUTATE restored stream=\(selected.id) HTTP \(restoreStatus)")
        #expect(restoreStatus == 200, "failed to restore the original part subtitle selection")
    }
}
