import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

/// Opt-in control-plane acceptance using the same request builders as the app.
/// Does not assert AVPlayer rendering, HDR presentation, seeking, or hardware decoder use.
struct LiveClientFirstPlaybackProbeTests {
    @Test func videoCopyHLSNegotiationAndStart() async {
        let env = ProcessInfo.processInfo.environment
        guard let config = LiveProbeConfig(env),
              let key = env["PLEX_LIVE_METADATA_KEY"], !key.isEmpty else { return }
        let sessionID = "client-first-probe-\(UUID().uuidString)"
        let request = TranscodeRequest(server: config.server, token: config.token,
            identity: config.identity, metadataKey: key,
            maxVideoBitrateKbps: StreamingQuality.maxTranscodedKbps,
            sessionID: sessionID, mediaIndex: env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0,
            partIndex: 0, forceTranscode: false)
        let stop = TranscodeRequest.stop(server: config.server, token: config.token,
            identity: config.identity, sessionID: sessionID)
        do {
            let (data, response) = try await URLSession.shared.data(for: request.decisionRequest().urlRequest())
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            let decision = try JSONDecoder().decode(DecisionResponse.self, from: data)
            let needsConsent = VideoTranscodeConsentPolicy.requiresConsent(selectedQualityKbps: 0,
                approvedForCurrentItem: false, videoDecision: decision.videoDecision,
                forcesVideoEncoding: false)
            print(">>> LIVE client-first decision confirmedVideoCopy=\(!needsConsent)")
            try #require(!needsConsent, "Fixture must support video copy; no media request made without it")
            let url = request.startM3U8URL()
            let headers = PlexHeaders.media(identity: config.identity, token: config.token)
            let (masterData, masterResponse) = try await URLSession.shared.data(for:
                PlexRequest(url: url, method: "GET", headers: headers).urlRequest())
            try #require((masterResponse as? HTTPURLResponse)?.statusCode == 200)
            let master = try #require(String(data: masterData, encoding: .utf8))
            let child = PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: master, baseURL: url,
                hdrDisplayEligible: false)
            print(">>> LIVE client-first masterHTTP=200 selectedHDRMediaPlaylist=\(child != nil)")
            if let child {
                let (media, mediaResponse) = try await URLSession.shared.data(for:
                    PlexRequest(url: child, method: "GET", headers: headers).urlRequest())
                try #require((mediaResponse as? HTTPURLResponse)?.statusCode == 200)
                try #require(String(data: media, encoding: .utf8)?.hasPrefix("#EXTM3U") == true)
                print(">>> LIVE client-first mediaHTTP=200 bytes=\(media.count)")
            }
        } catch {
            // Do not print URLSession errors: failing URLs can carry credentials.
            Issue.record("Client-first live probe failed; inspect private server evidence")
        }
        _ = try? await URLSession.shared.data(for: stop.urlRequest())
        print(">>> LIVE client-first cleanup requested")
    }
}
