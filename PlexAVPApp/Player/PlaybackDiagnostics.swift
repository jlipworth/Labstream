import Foundation
import AVFoundation
import PMSKit

/// Live, observable diagnostics for the "Stats for Nerds" overlay (Emby-style).
///
/// This separates the *static* facts about a playback session (resolution, codecs,
/// container, transcode-vs-directplay, the target bitrate cap, connection host) from
/// the *dynamic* numbers AVFoundation reports over time (observed/indicated bitrate,
/// dropped frames, stall count, buffer health). The static facts come from the Plex
/// `MediaItem`/transcode `DecisionResponse`; the dynamic numbers are scraped from
/// `AVPlayerItem.accessLog()`/`errorLog()` on a ~1s cadence.
///
/// `@Observable` so the SwiftUI glass panel re-renders as the numbers tick. `@MainActor`
/// because the player and its logs are main-actor bound and the panel reads it from the UI.
@Observable
@MainActor
final class PlaybackDiagnostics {
    // MARK: Static session facts

    /// Source resolution string, e.g. "1920×1080" (from the chosen `Media`).
    var sourceResolution: String = "—"
    /// Source video codec (e.g. "hevc"), from the chosen `Media`.
    var videoCodec: String = "—"
    /// Source audio codec (e.g. "eac3"), from the chosen `Media`.
    var audioCodec: String = "—"
    /// Source container (e.g. "mkv"), from the chosen `Media`.
    var container: String = "—"
    /// Whether PMS decided to transcode (vs direct play / direct stream).
    var isTranscoding: Bool = false
    /// Human-readable PMS decision text, when provided.
    var decisionText: String = "—"
    /// The host:port we are streaming from (no token, ever).
    var connectionHost: String = "—"

    // MARK: Dynamic numbers

    /// The requested hard cap (kbps). 0 means "Direct Play / Maximum" (no cap).
    var targetBitrateKbps: Int = 0
    /// Observed throughput of the current variant (kbps), from the access log.
    var observedBitrateKbps: Double = 0
    /// The variant bitrate AVFoundation indicates it is playing (kbps).
    var indicatedBitrateKbps: Double = 0
    /// Cumulative dropped video frames reported by the access log.
    var droppedFrames: Int = 0
    /// Cumulative stall count reported by the access log.
    var stalls: Int = 0
    /// Whether the player currently expects to keep up without stalling.
    var likelyToKeepUp: Bool = false
    /// Seconds of media buffered ahead of the playhead (loaded time range).
    var bufferedAheadSeconds: Double = 0

    /// A friendly label for the active bitrate cap. The two ladder maxima get named
    /// choices; numeric caps render as "<N> Mbps".
    var targetBitrateLabel: String {
        switch targetBitrateKbps {
        case ...0: "Direct Play / Maximum"
        case StreamingQuality.maxTranscodedKbps: "Maximum (transcoded)"
        default: "\(targetBitrateKbps / 1000) Mbps"
        }
    }

    // MARK: Updates

    /// Seed the static facts from the Plex item + transcode decision. Token is never read.
    func applyStatic(item: MediaItem,
                     mediaIndex: Int = 0,
                     decision: DecisionResponse?,
                     server: URL?,
                     targetBitrateKbps: Int) {
        if let mediaItems = item.media,
           let media = mediaItems.indices.contains(mediaIndex) ? mediaItems[mediaIndex] : mediaItems.first {
            if let w = media.width, let h = media.height {
                sourceResolution = "\(w)×\(h)"
            }
            videoCodec = media.videoCodec ?? "—"
            audioCodec = media.audioCodec ?? "—"
            container = media.container ?? "—"
        }
        if let decision {
            switch decision.decision {
            case .transcode: isTranscoding = true
            case .directPlay: isTranscoding = false
            case .unsupported: isTranscoding = true
            }
            decisionText = Self.composeDecisionText(decision)
        }
        // host:port only — deliberately omit any query/token material.
        if let host = server?.host {
            connectionHost = server?.port.map { "\(host):\($0)" } ?? host
        }
        self.targetBitrateKbps = targetBitrateKbps
    }

    /// A concise, human-readable decision string for the Stats panel.
    ///
    /// PMS's `generalDecisionText` ("Direct play not available. Conversion OK.") just
    /// restates the Mode row and reads as two jammed-together clauses — confusing, and
    /// long enough to get middle-truncated. The genuinely useful detail is what PMS does
    /// to each stream — copy (remux) vs transcode (re-encode) — which the decision
    /// response carries per stream. Prefer that; fall back to the part decision, then the
    /// raw English text, then "—".
    private static func composeDecisionText(_ decision: DecisionResponse) -> String {
        func friendly(_ s: String?) -> String? {
            guard let s = s?.lowercased(), !s.isEmpty else { return nil }
            switch s {
            case "copy": return "copy"
            case "transcode": return "transcode"
            case "directplay", "direct play", "direct": return "direct play"
            default: return s
            }
        }
        if let video = friendly(decision.videoDecision) {
            if let audio = friendly(decision.audioDecision) {
                return "video \(video) · audio \(audio)"
            }
            return "video \(video)"
        }
        if let part = friendly(decision.partDecision) {
            return part
        }
        return decision.generalDecisionText ?? "—"
    }

    /// Scrape the dynamic numbers from the current player item (call ~1s).
    func sample(player: AVPlayer) {
        guard let item = player.currentItem else { return }
        likelyToKeepUp = item.isPlaybackLikelyToKeepUp

        if let range = item.loadedTimeRanges.first?.timeRangeValue {
            let bufferedEnd = (range.start + range.duration).seconds
            let now = player.currentTime().seconds
            if bufferedEnd.isFinite && now.isFinite {
                bufferedAheadSeconds = max(0, bufferedEnd - now)
            }
        }

        guard let access = item.accessLog(), let event = access.events.last else { return }
        // AVFoundation reports bits/sec; show kbps. -1 means "not available".
        if event.observedBitrate > 0 {
            observedBitrateKbps = event.observedBitrate / 1000
        }
        if event.indicatedBitrate > 0 { indicatedBitrateKbps = event.indicatedBitrate / 1000 }
        if event.numberOfDroppedVideoFrames >= 0 { droppedFrames = event.numberOfDroppedVideoFrames }
        if event.numberOfStalls >= 0 { stalls = event.numberOfStalls }
    }
}
