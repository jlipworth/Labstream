import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Opt-in live fixture probe for offline playback routing (#120).
///
/// This intentionally does NOT open AVPlayer or a server stream. It proves the routing invariant
/// with a real PMS item fixture: once the live item has a completed local-file record, the shared
/// decision helper returns `.localFile` and has no server/session inputs through which it could
/// accidentally start a live transcode.
struct LiveOfflinePlaybackDecisionProbeTests {

    private struct Config {
        let base: LiveProbeConfig
        let metadataKey: String
        let localFile: URL

        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            guard let base = LiveProbeConfig() else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard let key = env["PLEX_LIVE_OFFLINE_METADATA_KEY"] ?? env["PLEX_LIVE_METADATA_KEY"],
                  !key.isEmpty,
                  let file = env["PLEX_LIVE_OFFLINE_FILE"], !file.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = key.hasPrefix("/") ? key : "/library/metadata/\(key)"
            self.localFile = URL(fileURLWithPath: file)
        }
    }

    private func loadItem(_ cfg: Config) async throws -> MediaItem? {
        let req = PlexRequest(url: cfg.server.appendingPathComponent(cfg.metadataKey),
                              method: "GET",
                              headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            print(">>> OFFLINEPLAY metadata HTTP \(status) — cannot read fixture item.")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data),
              let item = decoded.mediaContainer.metadata.first else {
            print(">>> OFFLINEPLAY metadata HTTP 200 but body did not decode as MetadataResponse — skipping.")
            return nil
        }
        return item
    }

    @Test func liveOfflinePlaybackPrefersDownloadedCopy() async throws {
        guard let cfg = Config() else {
            print(">>> OFFLINEPLAY skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_OFFLINE_METADATA_KEY / PLEX_LIVE_OFFLINE_FILE to run.")
            return
        }

        guard FileManager.default.fileExists(atPath: cfg.localFile.path) else {
            print(">>> OFFLINEPLAY VERDICT: PLEX_LIVE_OFFLINE_FILE does not exist locally — point it at a downloaded fixture file. Skipping.")
            return
        }
        guard let item = try await loadItem(cfg) else {
            print(">>> OFFLINEPLAY VERDICT: could not load the live fixture item — skipping.")
            return
        }

        let record = DownloadRecord(ratingKey: OfflinePlaybackDecision.recordKey(for: item.ratingKey,
                                                                                 backend: .plex),
                                    title: item.title,
                                    localURL: cfg.localFile,
                                    bytes: 1,
                                    progress: 1,
                                    status: .complete)
        let route = OfflinePlaybackDecision.route(for: item, backend: .plex, records: [record])

        print(">>> OFFLINEPLAY route=\(route == .localFile(cfg.localFile) ? "localFile" : "remoteStream") fixture_ratingKey=\(item.ratingKey)")
        #expect(route == .localFile(cfg.localFile),
                "completed downloaded fixture should route to the local file, not a live/server stream")

        let noDownloadRoute = OfflinePlaybackDecision.route(for: item, backend: .plex, records: [])
        #expect(noDownloadRoute == .remoteStream,
                "without a completed local row, the same live item should fall back to remote playback")

        print(">>> OFFLINEPLAY VERDICT: OK — completed local fixture wins; the decision helper has no server-session side effect path.")
    }
}
