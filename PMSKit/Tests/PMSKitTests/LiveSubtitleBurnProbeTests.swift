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
/// PROOF DISCIPLINE (why the assertion is a FLIP, not an absolute). Asserting only
/// `burn.videoDecision == transcode` is unsound: if the item already transcodes for an unrelated
/// reason (codec/bitrate/profile), the burn check passes green even when burn was silently ignored
/// — the exact failure it exists to catch. So the baseline (`subtitles=auto`) is a PRECONDITION:
/// the item must be direct-play-eligible (baseline video decision is `copy`/`directplay`, or nil
/// which PMS uses for a clean direct-play). If the baseline already transcodes, the subtitle nuance
/// cannot be isolated → SKIP (not pass/fail). The real assertion is the FLIP: direct-play baseline
/// → `transcode` under burn, so the burn is provably what CAUSED the re-encode.
///
/// Faithful reproduction of the app: like the other Live*Probe tests, it sends the real PMSKit
/// request builders through `URLSession.shared` — the exact thing `PlexClient.send` does.
///
/// OPT-IN and HERMETIC by default: with no creds it prints a skip line and returns, so plain
/// `swift test` and CI stay green. Run it via `./scripts/live-subtitle-burn-probe.sh` or:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveSubtitleBurnProbe
///
/// Inputs (env, shared with the decision probe):
///   PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN          (required)
///   PLEX_LIVE_SUBTITLE_METADATA_KEY             (required — a DIRECT-PLAY-ELIGIBLE item that HAS an
///                                                embedded image-based subtitle track, e.g. a
///                                                PGS/VOBSUB Blu-ray rip; falls back to
///                                                PLEX_LIVE_METADATA_KEY)
///   PLEX_LIVE_SUBTITLE_STREAM_ID                (optional — pin a specific subtitle stream id; it
///                                                is still validated against the item's streams)
struct LiveSubtitleBurnProbeTests {

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
            // Prefer a subtitle-specific item; fall back to the shared decision-probe item so a
            // single env file can drive every Plex live probe.
            guard let key = env["PLEX_LIVE_SUBTITLE_METADATA_KEY"] ?? env["PLEX_LIVE_METADATA_KEY"],
                  !key.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = key
            self.pinnedSubtitleStreamID = env["PLEX_LIVE_SUBTITLE_STREAM_ID"].flatMap(Int.init)
        }
    }

    /// Fetch full metadata for the item, including its per-part streams. Decodes leniently: a 200
    /// with an unexpected body returns nil (→ caller skips with a diagnostic) rather than throwing
    /// a false RED. This is the same `/library/metadata/<id>` request the app loads before the
    /// track picker; `includeStreams=1` makes PMS emit every track, not just the selected ones.
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
            print(">>> SUBBURN metadata HTTP \(status) — cannot read streams for the item.")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data) else {
            print(">>> SUBBURN metadata HTTP 200 but body did not decode as MetadataResponse (\(data.count) bytes) — skipping.")
            return nil
        }
        return decoded.mediaContainer.metadata.first?.media?.first?.part.first
    }

    /// Send a decision request and return its decoded verdict. Returns nil (and logs) on any
    /// non-200 or undecodable body so callers can distinguish "control leg failed" from a real
    /// verdict — never silently swallowed.
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

    /// Image-based subtitles (PGS/VOBSUB/DVD) can't be passed as a sidecar text track, so they MUST
    /// be burned in — the cleanest way to prove burn-in actually re-encodes the picture. Takes the
    /// codec string directly to dodge the `Stream` vs `Foundation.Stream` name clash.
    private static func isImageBasedCodec(_ codec: String?) -> Bool {
        let c = (codec ?? "").lowercased()
        return c.contains("pgs") || c.contains("vobsub") || c.contains("dvd")
    }

    /// A video decision counts as "direct-play eligible" if it copies/direct-plays OR is nil
    /// (PMS leaves the video decision unset on a clean direct-play). Anything that already says
    /// `transcode` means we can't isolate the subtitle nuance.
    private func isDirectPlayEligible(_ videoDecision: String?) -> Bool {
        guard let v = videoDecision?.lowercased() else { return true }   // nil → direct-play
        return v == "copy" || v == "directplay" || v == "direct play"
    }

    @Test func liveSubtitleBurnForcesVideoTranscode() async throws {
        guard let cfg = Config() else {
            print(">>> SUBBURN skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SUBTITLE_METADATA_KEY to run.")
            return
        }

        // 1) Resolve + VALIDATE the subtitle stream id against the item's real streams — even when
        //    pinned (a pinned id that isn't actually a subtitle stream would silently mis-test).
        guard let part = try await loadStreams(cfg) else {
            print(">>> SUBBURN VERDICT: could not load item streams — skipping.")
            return
        }
        let subs = part.subtitleStreams

        let subtitleStreamID: Int
        if let pinned = cfg.pinnedSubtitleStreamID {
            guard let pinnedStream = subs.first(where: { $0.id == pinned }) else {
                print(">>> SUBBURN VERDICT: pinned PLEX_LIVE_SUBTITLE_STREAM_ID=\(pinned) is not a subtitle stream on this item — fix the env var. Skipping.")
                return
            }
            subtitleStreamID = pinned
            print(">>> SUBBURN using pinned subtitle id=\(pinned) codec=\(pinnedStream.codec ?? "n/a") imageBased=\(Self.isImageBasedCodec(pinnedStream.codec) ? "YES" : "no")")
        } else {
            // Prefer an image-based subtitle (codec pgs/vobsub/dvd_subtitle) — it forces burn-in.
            guard let chosen = subs.first(where: { Self.isImageBasedCodec($0.codec) }) ?? subs.first else {
                print(">>> SUBBURN VERDICT: item has no subtitle streams — point PLEX_LIVE_SUBTITLE_METADATA_KEY at an item that does.")
                return
            }
            subtitleStreamID = chosen.id
            // Codec only — never the title/language VALUE (could carry a media name). Safe to log.
            print(">>> SUBBURN discovered \(subs.count) subtitle stream(s); chose id=\(chosen.id) codec=\(chosen.codec ?? "n/a") imageBased=\(Self.isImageBasedCodec(chosen.codec) ? "YES" : "no")")
        }

        // 2) Baseline / PRECONDITION: the SAME item with subtitles=auto. A failed control leg must
        //    NOT be swallowed — record it and stop, since the FLIP can't be evaluated without it.
        guard let auto = try await decision("auto", makeRequest(cfg, burnSubtitleStreamID: nil).decisionRequest()) else {
            Issue.record("Control (subtitles=auto) decision did not return a decodable response — cannot establish the direct-play baseline, so the burn flip is unprovable.")
            return
        }
        guard isDirectPlayEligible(auto.videoDecision) else {
            print(">>> SUBBURN VERDICT: SKIP — baseline already transcodes (auto.video=\(auto.videoDecision ?? "nil")); the subtitle nuance cannot be isolated. Point PLEX_LIVE_SUBTITLE_METADATA_KEY at a direct-play-eligible item (codec/bitrate within the visionOS profile).")
            return
        }

        // 3) Burn: request subtitles=burn for the validated stream. Byte-for-byte the app path.
        guard let burn = try await decision("burn id=\(subtitleStreamID)",
                                            makeRequest(cfg, burnSubtitleStreamID: subtitleStreamID).decisionRequest()) else {
            Issue.record("Burn decision did not return a decodable response — PMS rejected the subtitles=burn param set (likely a profile/wire regression).")
            return
        }

        // 4) THE ASSERTION: the FLIP. Baseline is direct-play-eligible (precondition held above), so
        //    if PMS is honoring the burn it MUST now re-encode the video — burning pixels can't be a
        //    codec copy. A burn that stays copy/directplay means the server is silently ignoring the
        //    subtitle and it would never render: exactly the "subtitles not applying" regression.
        let burnVideo = (burn.videoDecision ?? "").lowercased()
        print(">>> SUBBURN compare: auto.video=\(auto.videoDecision ?? "nil(direct-play)") → burn.video=\(burn.videoDecision ?? "nil")")
        #expect(burnVideo == "transcode",
                "Direct-play baseline must FLIP to transcode under subtitles=burn, but PMS returned videoDecision=\(burn.videoDecision ?? "nil"). The server is not applying the burned subtitle — playback would show no subtitle.")

        if burnVideo == "transcode" {
            print(">>> SUBBURN VERDICT: OK — direct-play baseline FLIPPED to transcode under subtitles=burn. PMS is applying the burned subtitle the app requests.")
        } else {
            print(">>> SUBBURN VERDICT: REGRESSION — burn did NOT flip a direct-play item to transcode (videoDecision=\(burn.videoDecision ?? "nil")). Subtitles would not render. Investigate the profile / subtitles=burn handling.")
        }
    }
}
