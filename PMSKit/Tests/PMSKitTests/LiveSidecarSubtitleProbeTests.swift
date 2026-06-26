import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Opt-in live Plex sidecar subtitle probe (#119).
///
/// The burn-in probe proves image-subtitle burn decisions; this one proves the other subtitle
/// lane: a real external text stream (`/library/streams/<id>`) can be fetched from PMS and decoded
/// by the same `OfflineTextSubtitleParser` used for cached offline subtitles.
struct LiveSidecarSubtitleProbeTests {

    private struct Config {
        let base: LiveProbeConfig
        let metadataKey: String
        let pinnedSubtitleStreamID: Int?

        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            guard let base = LiveProbeConfig() else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard let key = env["PLEX_LIVE_SIDECAR_SUBTITLE_METADATA_KEY"] ?? env["PLEX_LIVE_METADATA_KEY"],
                  !key.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = Self.metadataPath(key)
            self.pinnedSubtitleStreamID = env["PLEX_LIVE_SIDECAR_SUBTITLE_STREAM_ID"].flatMap(Int.init)
        }

        private static func metadataPath(_ raw: String) -> String {
            raw.hasPrefix("/") ? raw : "/library/metadata/\(raw)"
        }
    }

    private func loadPart(_ cfg: Config) async throws -> Part? {
        guard var components = URLComponents(url: cfg.server, resolvingAgainstBaseURL: false) else { return nil }
        components.path = cfg.metadataKey
        components.queryItems = [.init(name: "includeStreams", value: "1")]
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        for (name, value) in PlexHeaders.standard(identity: cfg.identity, token: cfg.token) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            print(">>> SIDECAR metadata HTTP \(status) — cannot read streams for the item.")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data) else {
            print(">>> SIDECAR metadata HTTP 200 but body did not decode as MetadataResponse (\(data.count) bytes) — skipping.")
            return nil
        }
        return decoded.mediaContainer.metadata.first?.media?.first?.part.first
    }

    private func subtitleURL(server: URL, token: String, key: String) -> URL? {
        let raw = key.hasPrefix("/") ? key : "/\(key)"
        guard var comps = URLComponents(url: server.appendingPathComponent(raw), resolvingAgainstBaseURL: false) else { return nil }
        if var items = comps.queryItems {
            items.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
            comps.queryItems = items.isEmpty ? nil : items
        }
        PlexURLQueryEncoder.appendQueryItems([.init(name: "X-Plex-Token", value: token)], to: &comps)
        return comps.url
    }

    @Test func liveSidecarSubtitleFetchesAndParses() async throws {
        guard let cfg = Config() else {
            print(">>> SIDECAR skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SIDECAR_SUBTITLE_METADATA_KEY to run.")
            return
        }

        guard let part = try await loadPart(cfg) else {
            print(">>> SIDECAR VERDICT: could not load item streams — skipping.")
            return
        }

        let compatible = part.subtitleStreams.filter {
            OfflineTextSubtitleCachePlanner.isCompatibleTextSubtitle($0) && ($0.key?.isEmpty == false)
        }
        let chosen = cfg.pinnedSubtitleStreamID.flatMap { pinned in
            compatible.first { $0.id == pinned }
        } ?? compatible.first
        if let pinned = cfg.pinnedSubtitleStreamID {
            if chosen == nil {
                print(">>> SIDECAR VERDICT: pinned PLEX_LIVE_SIDECAR_SUBTITLE_STREAM_ID=\(pinned) is not a compatible keyed text subtitle on this item — fix the env var. Skipping.")
                return
            }
        }

        guard let stream = chosen, let key = stream.key,
              let url = subtitleURL(server: cfg.server, token: cfg.token, key: key) else {
            print(">>> SIDECAR VERDICT: item has no compatible keyed SRT/VTT subtitle stream — point PLEX_LIVE_SIDECAR_SUBTITLE_METADATA_KEY at an item with external text subtitles.")
            return
        }

        var req = URLRequest(url: url)
        for (name, value) in PlexHeaders.media(identity: cfg.identity, token: cfg.token) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print(">>> SIDECAR fetch stream_id=\(stream.id) codec=\(stream.codec ?? "n/a") HTTP \(status) bytes=\(data.count)")
        #expect(status == 200, "sidecar subtitle stream expected HTTP 200, got \(status)")
        #expect(!data.isEmpty, "sidecar subtitle body should not be empty")

        guard let text = String(data: data, encoding: .utf8) else {
            Issue.record("Sidecar subtitle body was not UTF-8 text.")
            return
        }
        let cues = OfflineTextSubtitleParser.parse(text)
        print(">>> SIDECAR parse cues=\(cues.count)")
        #expect(!cues.isEmpty, "OfflineTextSubtitleParser should decode at least one cue from the live sidecar body")

        if let first = cues.first {
            print(">>> SIDECAR VERDICT: OK — fetched and parsed live \(stream.codec ?? "text") sidecar; firstCueMs=\(first.startMs)-\(first.endMs)")
        }
    }
}
