import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Representative END-TO-END live path for issue #75: proves the harness can catch a real
/// SUBTITLE nuance that no mock can surface — does PMS actually honor `subtitles=burn` +
/// `subtitleStreamID`, and does selecting an image-based subtitle force the video re-encode the
/// player must expect?
///
/// Why this is the right "nuance" proof. The issue calls out "subtitles not working or not
/// applying during playback" as a regression class. The whole app-side subtitle-burn path
/// (`TranscodeRequest.burnSubtitleStreamID` → `subtitles=burn`/`subtitleStreamID`/`subtitleSize`
/// in `sharedQueryItems()`) is exercised by `TranscodeRequestTests` against the *string we build*,
/// but a unit test cannot answer the question that actually strands users: does the real server
/// ACCEPT that param set, and does burning a PGS/VOBSUB track flip the Media Decision Engine's
/// `videoDecision` from `copy` to `transcode`? If a server/profile change ever made PMS silently
/// ignore the burn request (return `directPlay`/`copy`), the subtitle would never appear on screen
/// and every mocked test would still pass. This probe is the wire-level tripwire for that.
///
/// Faithful reproduction of the app: like the other Live*Probe tests, it sends the real PMSKit
/// request builders through `URLSession.shared` — the exact thing `PlexClient.send` does — so the
/// metadata fetch, the auto-subtitle decision, and the burn decision are byte-for-byte what the
/// app issues. Nothing is hardcoded: server, token and the item key all arrive via the
/// environment, so no secret is ever committed.
///
/// OPT-IN and HERMETIC by default: with no creds it prints a skip line and returns, so plain
/// `swift test` and CI stay green. Run it via `./scripts/live-subtitle-burn-probe.sh` or:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveSubtitleBurnProbe
///
/// Inputs (env, shared with the decision probe):
///   PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN          (required)
///   PLEX_LIVE_SUBTITLE_METADATA_KEY             (required — an item that HAS an embedded
///                                                image-based subtitle track, e.g. a PGS/VOBSUB
///                                                Blu-ray rip; falls back to PLEX_LIVE_METADATA_KEY)
///   PLEX_LIVE_SUBTITLE_STREAM_ID                (optional — pin a specific subtitle stream id;
///                                                otherwise the probe auto-picks the first
///                                                image-based subtitle stream on the item)
struct LiveSubtitleBurnProbeTests {

    private struct Config {
        let server: URL
        let token: String
        let metadataKey: String
        let pinnedSubtitleStreamID: Int?
        let identity: ClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let serverString = env["PLEX_LIVE_SERVER"], let server = URL(string: serverString),
                  let token = env["PLEX_LIVE_TOKEN"], !token.isEmpty
            else { return nil }
            // Prefer a subtitle-specific item; fall back to the shared decision-probe item so a
            // single env file can drive every Plex live probe.
            guard let key = env["PLEX_LIVE_SUBTITLE_METADATA_KEY"] ?? env["PLEX_LIVE_METADATA_KEY"],
                  !key.isEmpty
            else { return nil }
            self.server = server
            self.token = token
            self.metadataKey = key
            self.pinnedSubtitleStreamID = env["PLEX_LIVE_SUBTITLE_STREAM_ID"].flatMap(Int.init)
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplay-live-probe",
                product: "VisionPlay",
                version: "0.1.0",
                deviceName: "VisionPlay Live Probe")
        }
    }

    /// Fetch full metadata for the item, including its per-part streams, so we can discover a
    /// real subtitle stream id to burn. This is the same `/library/metadata/<id>` request the app
    /// loads before presenting the track picker; `includeStreams=1` makes PMS emit every track,
    /// not just the selected ones.
    private func loadStreams(_ cfg: Config) async throws -> Part? {
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
            print(">>> SUBBURN metadata HTTP \(status) — cannot read streams for \(cfg.metadataKey).")
            return nil
        }
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)
        return decoded.mediaContainer.metadata.first?.media?.first?.part.first
    }

    /// Send a decision request and return its decoded verdict, dumping status + the key fields.
    private func decision(_ label: String, _ req: PlexRequest) async throws -> DecisionResponse? {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, let decoded = try? JSONDecoder().decode(DecisionResponse.self, from: data) else {
            print(">>> SUBBURN [\(label)] HTTP \(status) — no decodable decision (\(data.count) bytes).")
            return nil
        }
        print(">>> SUBBURN [\(label)] video=\(decoded.videoDecision ?? "nil") audio=\(decoded.audioDecision ?? "nil") savesVideoEncode=\(decoded.savesVideoEncode)")
        return decoded
    }

    private func makeRequest(_ cfg: Config, burnSubtitleStreamID: Int?) -> TranscodeRequest {
        TranscodeRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey,
            // Maximum-quality ceiling so the ONLY reason PMS would re-encode video is the burn-in,
            // not a bitrate/resolution cap. This isolates the subtitle nuance.
            maxVideoBitrateKbps: 200_000,
            sessionID: "live-subburn-\(UUID().uuidString)",
            mediaIndex: 0, partIndex: 0,
            burnSubtitleStreamID: burnSubtitleStreamID)
    }

    @Test func liveSubtitleBurnForcesVideoTranscode() async throws {
        guard let cfg = Config() else {
            print(">>> SUBBURN skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SUBTITLE_METADATA_KEY to run.")
            return
        }

        // 1) Discover a subtitle stream id to burn. Image-based subtitles (PGS/VOBSUB) MUST be
        //    burned in — they can't be passed as a sidecar text track — so they are the cleanest
        //    way to prove burn-in actually re-encodes the picture.
        let pinnedID = cfg.pinnedSubtitleStreamID
        var subtitleStreamID: Int? = pinnedID
        if subtitleStreamID == nil {
            guard let part = try await loadStreams(cfg) else {
                print(">>> SUBBURN VERDICT: could not load item streams — set PLEX_LIVE_SUBTITLE_STREAM_ID to skip discovery.")
                return
            }
            let subs = part.subtitleStreams
            // Prefer an image-based subtitle (codec pgs/vobsub/dvd_subtitle) — it forces burn-in.
            let imageBased = subs.first { stream in
                let codec = (stream.codec ?? "").lowercased()
                return codec.contains("pgs") || codec.contains("vobsub") || codec.contains("dvd")
            }
            subtitleStreamID = (imageBased ?? subs.first)?.id
            // Codec only — never the title/language VALUE (could carry a media name). Safe to log.
            print(">>> SUBBURN discovered \(subs.count) subtitle stream(s); chose id=\(subtitleStreamID.map(String.init) ?? "nil") codec=\((imageBased ?? subs.first)?.codec ?? "n/a") imageBased=\(imageBased != nil ? "YES" : "no")")
            guard subtitleStreamID != nil else {
                print(">>> SUBBURN VERDICT: item has no subtitle streams — point PLEX_LIVE_SUBTITLE_METADATA_KEY at an item that does.")
                return
            }
        }

        // 2) Baseline: the SAME item with subtitles=auto. This is the control. For a
        //    direct-play-eligible source, PMS should NOT re-encode video here.
        let auto = try await decision("auto", makeRequest(cfg, burnSubtitleStreamID: nil).decisionRequest())

        // 3) Burn: request subtitles=burn for the chosen stream. This is the byte-for-byte app
        //    path through TranscodeRequest. The nuance: PMS must accept the burn AND re-encode.
        guard let burn = try await decision("burn id=\(subtitleStreamID!)",
                                            makeRequest(cfg, burnSubtitleStreamID: subtitleStreamID!).decisionRequest()) else {
            Issue.record("Burn decision did not return a decodable response — PMS rejected the subtitles=burn param set (likely a profile/wire regression).")
            return
        }

        // 4) THE ASSERTION the harness exists for: burning a subtitle into the picture is a pixel
        //    operation, so PMS cannot codec-copy the video — `videoDecision` must be `transcode`.
        //    If it comes back `copy`/`directplay` (or nil), the server is silently ignoring the
        //    burn request and the subtitle will never appear on screen during playback — exactly
        //    the "subtitles not applying" regression #75 wants surfaced.
        let burnVideo = (burn.videoDecision ?? "").lowercased()
        if let autoVideo = auto?.videoDecision?.lowercased() {
            print(">>> SUBBURN compare: auto.video=\(autoVideo) → burn.video=\(burnVideo)")
        }
        #expect(burnVideo == "transcode",
                "Subtitle burn-in must force a video transcode, but PMS returned videoDecision=\(burn.videoDecision ?? "nil"). The server is not applying the burned subtitle — playback would show no subtitle.")

        if burnVideo == "transcode" {
            print(">>> SUBBURN VERDICT: OK — PMS honored subtitles=burn (videoDecision=transcode). The burned subtitle path the app builds is live-accepted by the server.")
        } else {
            print(">>> SUBBURN VERDICT: REGRESSION — PMS did NOT re-encode for the burn (videoDecision=\(burn.videoDecision ?? "nil")). Subtitles would not render. Investigate the profile / subtitles=burn handling.")
        }
    }
}
