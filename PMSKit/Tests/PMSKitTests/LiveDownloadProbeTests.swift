import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless live Plex download-route probe. OPT-IN: runs only with PLEX_LIVE_* env vars.
///
/// This validates the exact strict rule the app uses before offering "Download original":
/// the PMS direct-play probe must say the whole file direct-plays, AND the source Part's
/// container must be locally playable as an offline file. Direct Stream (copy video /
/// transcode audio or remux container) deliberately routes to the optimizer.
struct LiveDownloadProbeTests {

    private struct LiveConfig {
        let base: LiveProbeConfig
        let metadataKey: String
        let maxVideoBitrateKbps: Int
        let mediaIndex: Int
        let partIndex: Int
        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let base = LiveProbeConfig(env, deviceName: "VisionPlay Live Download Probe"),
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = metadataKey
            self.maxVideoBitrateKbps = env["PLEX_LIVE_MAX_KBPS"].flatMap(Int.init) ?? 200_000
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
        }
    }

    private func request(_ cfg: LiveConfig, path: String, method: String = "GET") -> PlexRequest {
        PlexRequest(url: cfg.server.appendingPathComponent(path),
                    method: method,
                    queryItems: [],
                    headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
    }

    private func send(_ label: String, _ req: PlexRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        let http = response as? HTTPURLResponse
        print(">>> DL [\(label)] HTTP \(http?.statusCode ?? -1), \(data.count) bytes")
        return (data, http)
    }

    private func headDownload(_ cfg: LiveConfig, part: Part) async {
        let url = OptimizeRequest.downloadURL(server: cfg.server, token: cfg.token, partKey: part.key)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        for (k, v) in PlexHeaders.standard(identity: cfg.identity, token: cfg.token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let length = http?.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "nil"
            print(">>> DL [original.head] HTTP \(http?.statusCode ?? -1), Content-Length=\(length), Content-Type=\(type)")
        } catch {
            print(">>> DL [original.head] ERROR \(error)")
        }
    }

    @Test func liveDownloadRouteProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> DL skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }

        let (metadataData, metadataHTTP) = try await send("metadata", request(cfg, path: cfg.metadataKey))
        #expect((200..<300).contains(metadataHTTP?.statusCode ?? -1),
                "metadata expected 2xx, got \(metadataHTTP?.statusCode ?? -1)")
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: metadataData)
        guard let item = metadata.mediaContainer.metadata.first else {
            print(">>> DL route=optimize reason=no_metadata")
            return
        }
        let media = item.media.flatMap { $0.indices.contains(cfg.mediaIndex) ? $0[cfg.mediaIndex] : nil }
        let part = media.flatMap { $0.part.indices.contains(cfg.partIndex) ? $0.part[cfg.partIndex] : nil }
        print("""
        >>> DL source mediaIndex=\(cfg.mediaIndex) partIndex=\(cfg.partIndex) \
        container=\(media?.container ?? part?.container ?? "unknown") \
        video=\(media?.videoCodec ?? part?.videoStreams.first?.codec ?? "unknown") \
        audio=\(media?.audioCodec ?? part?.audioStreams.first?.codec ?? "unknown") \
        partContainer=\(OfflineDownloadDecision.containerLabel(part: part))
        """)

        let transcode = TranscodeRequest(server: cfg.server, token: cfg.token,
                                         identity: cfg.identity,
                                         metadataKey: cfg.metadataKey,
                                         maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
                                         sessionID: "live-download-probe-\(UUID().uuidString)",
                                         mediaIndex: cfg.mediaIndex,
                                         partIndex: cfg.partIndex)
        let (decisionData, decisionHTTP) = try await send("directPlayProbe", transcode.directPlayProbeRequest())
        #expect((200..<300).contains(decisionHTTP?.statusCode ?? -1),
                "directPlayProbe expected 2xx, got \(decisionHTTP?.statusCode ?? -1)")
        let decision = try JSONDecoder().decode(DecisionResponse.self, from: decisionData)
        let eligibility = OfflineDownloadDecision.originalEligibility(decision: decision, part: part)

        print("""
        >>> DL decision general=\(decision.generalDecisionCode.map(String.init) ?? "nil") \
        mde=\(decision.mdeDecisionCode.map(String.init) ?? "nil") \
        part=\(decision.partDecision ?? "nil") video=\(decision.videoDecision ?? "nil") \
        audio=\(decision.audioDecision ?? "nil") savesVideoEncode=\(decision.savesVideoEncode) \
        playsWholeFileDirectly=\(decision.playsWholeFileDirectly)
        >>> DL route=\(eligibility.route) reason=\(eligibility.optimizeReason ?? "none") \
        localPlayableContainer=\(eligibility.localPlayableContainer) container=\(eligibility.container)
        """)

        if eligibility.canDownloadOriginal, let part {
            await headDownload(cfg, part: part)
        }
    }
}
