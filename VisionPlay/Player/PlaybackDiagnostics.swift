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
    /// Source media bitrate (kbps), when PMS exposes it on the chosen Media row.
    var sourceBitrateKbps: Int = 0
    /// Whether PMS decided to transcode (vs direct play / direct stream).
    var isTranscoding: Bool = false
    /// Human-readable playback mode for the Stats panel. This is deliberately separate from
    /// `decisionText`: MDE direct-play probe responses often omit `generalDecisionCode`, so the
    /// old enum-only mode row could say "Transcoding" while the structured part decision said
    /// "direct play".
    var modeText: String = "Direct"
    /// Human-readable PMS decision text, when provided.
    var decisionText: String = "—"
    /// The host:port we are streaming from (no token, ever).
    var connectionHost: String = "—"
    /// True when AVFoundation is reading through the app's loopback HLS proxy. In that mode
    /// AVPlayer's observed bitrate measures localhost/proxy burst rate, not server/network
    /// throughput, so the Stats panel should not present it as real bandwidth.
    var usesLocalMediaProxy: Bool = false

    // MARK: Dynamic numbers

    /// The requested hard cap (kbps). 0 means "Direct Play / Maximum" (no cap).
    var targetBitrateKbps: Int = 0
    /// Last active observed throughput sample (kbps), from the access log. This is empirical
    /// transfer throughput while AVFoundation is downloading, not encoded stream bitrate.
    var observedBitrateKbps: Double = 0
    /// Whether the Observed row is current, stale because downloads are idle, unavailable, or hidden
    /// because the app's local HLS proxy would make it a localhost/proxy number.
    var observedBitrateState: ObservedBitrateState = .unavailable
    /// The variant peak bitrate AVFoundation indicates it is playing (kbps).
    var indicatedBitrateKbps: Double = 0
    /// The variant average bitrate AVFoundation indicates, when the playlist advertises one (kbps).
    var indicatedAverageBitrateKbps: Double = 0
    /// The media average video bitrate AVFoundation reports for the current event (kbps).
    var averageVideoBitrateKbps: Double = 0
    /// Cumulative bytes transferred in the current access-log event.
    var transferredBytes: Int64 = 0
    /// Cumulative active network transfer time in the current access-log event.
    var transferDurationSeconds: Double = 0
    /// Cumulative dropped video frames reported by the access log.
    var droppedFrames: Int = 0
    /// Cumulative stall count reported by the access log.
    var stalls: Int = 0
    /// Whether the player currently expects to keep up without stalling.
    var likelyToKeepUp: Bool = false
    /// Seconds of media buffered ahead of the playhead (loaded time range).
    var bufferedAheadSeconds: Double = 0

    /// Keep Observed active briefly between bursty HLS segment downloads. Without this, a player
    /// that fetches one segment every other sampling tick flips between a real bitrate and `idle`,
    /// even though the current access-log event is healthy and actively loading.
    private static let observedIdleGraceSeconds: TimeInterval = 3.0

    /// A friendly label for the active bitrate cap. The two ladder maxima get named
    /// choices; numeric caps render as "<N> Mbps".
    var targetBitrateLabel: String {
        switch targetBitrateKbps {
        case ...0: "Direct Play / Maximum"
        case StreamingQuality.maxTranscodedKbps: "Maximum (HLS)"
        default: "\(targetBitrateKbps / 1000) Mbps"
        }
    }

    /// Best estimate of the bitrate the network must sustain for the active stream.
    /// For Original/Direct Play, the source bitrate is the useful comparison. For capped
    /// transcodes, the requested cap is what PMS should be trying not to exceed. Fall back to
    /// AVFoundation's indicated variant bitrate when Plex metadata has no bitrate.
    var requiredBitrateKbps: Double {
        if targetBitrateKbps > 0 { return Double(targetBitrateKbps) }
        if sourceBitrateKbps > 0 { return Double(sourceBitrateKbps) }
        return indicatedBitrateKbps
    }

    /// Observed throughput value that is safe for adaptation logic. Stale/idle samples are
    /// intentionally treated as missing: a full buffer is healthy, not evidence that bandwidth is
    /// too low to upshift.
    var currentObservedBitrateForAdaptationKbps: Double {
        observedBitrateState == .active ? observedBitrateKbps : 0
    }

    /// Human-readable Observed row for Stats for Nerds.
    var observedBitrateLabel: String {
        switch observedBitrateState {
        case .unavailable:
            return "—"
        case .localProxy:
            return "— (proxy)"
        case .active:
            return Self.bitrateLabel(observedBitrateKbps)
        case .idle:
            guard observedBitrateKbps > 0 else { return "idle" }
            return "idle (last \(Self.bitrateLabel(observedBitrateKbps)))"
        }
    }

    /// Message for the #32 presentation-only bandwidth toast.
    ///
    /// Disabled intentionally: AVFoundation's `observedBitrate` is useful as a diagnostic value
    /// in Stats for Nerds, but during Plex transcoded HLS startup/stalls it can report the
    /// paced segment delivery rate (or a partial early sample), not the actual network capacity.
    /// That produced false "0.1 Mbps cannot sustain 3 Mbps" warnings while playback was in fact
    /// advancing. ABR/failure handling should continue to use concrete playback symptoms
    /// (stalls, buffer progress, and server segment success), not this presentation-only toast.
    var bandwidthMismatchMessage: String? {
        nil
    }

    // MARK: Updates

    /// Seed the static facts from the Plex item + transcode decision. Token is never read.
    func applyStatic(item: MediaItem,
                     mediaIndex: Int = 0,
                     decision: DecisionResponse?,
                     server: URL?,
                     targetBitrateKbps: Int) {
        resetDynamicAccessLogFacts()
        applySourceSummary(PlaybackSourceSummary.plex(item: item, mediaIndex: mediaIndex))
        if let decision {
            if decision.playsWholeFileDirectly {
                isTranscoding = false
                modeText = "Direct Play"
            } else if decision.savesVideoEncode {
                isTranscoding = false
                modeText = "Direct Stream"
            } else {
                switch decision.decision {
                case .transcode:
                    isTranscoding = true
                    modeText = "Transcoding"
                case .directPlay:
                    isTranscoding = false
                    modeText = "Direct Play"
                case .unsupported:
                    isTranscoding = true
                    modeText = "Transcoding"
                }
            }
            decisionText = Self.composeDecisionText(decision)
        } else {
            modeText = isTranscoding ? "Transcoding" : "Direct"
        }
        // host:port only — deliberately omit any query/token material.
        if let host = server?.host {
            connectionHost = server?.port.map { "\(host):\($0)" } ?? host
        }
        usesLocalMediaProxy = false
        self.targetBitrateKbps = targetBitrateKbps
    }

    /// Overlay backend-resolved source facts, used by MediaBrowser PlaybackInfo results when
    /// the browse/detail item did not carry enough `MediaSources` data for `applyStatic`.
    func applyMediaBrowserSource(_ source: MediaBrowserPlaybackSourceMetadata,
                                 playMethod: MediaBrowserPlayMethod) {
        if let summary = PlaybackSourceSummary.mediaBrowser(source) {
            applySourceSummary(summary, overwriteOnlyKnownValues: true)
        }
        switch playMethod {
        case .directPlay:
            isTranscoding = false
            modeText = "Direct Play"
            decisionText = "direct play"
        case .directStream:
            isTranscoding = false
            modeText = "Direct Stream"
            decisionText = "direct stream"
        case .transcode:
            isTranscoding = true
            modeText = "Transcoding"
            decisionText = "transcode"
        }
    }

    private func applySourceSummary(_ summary: PlaybackSourceSummary,
                                    overwriteOnlyKnownValues: Bool = false) {
        if let resolution = summary.statsResolution {
            sourceResolution = resolution
        } else if !overwriteOnlyKnownValues {
            sourceResolution = "—"
        }
        if let videoCodec = summary.videoCodec, !videoCodec.isEmpty {
            self.videoCodec = videoCodec
        } else if !overwriteOnlyKnownValues {
            self.videoCodec = "—"
        }
        if let audioCodec = summary.audioCodec, !audioCodec.isEmpty {
            self.audioCodec = audioCodec
        } else if !overwriteOnlyKnownValues {
            self.audioCodec = "—"
        }
        if let container = summary.container, !container.isEmpty {
            self.container = container
        } else if !overwriteOnlyKnownValues {
            self.container = "—"
        }
        if summary.bitrateKbps > 0 || !overwriteOnlyKnownValues {
            sourceBitrateKbps = summary.bitrateKbps
        }
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

    private var lastAccessLogProgress: AccessLogProgressSignature?
    private var lastObservedProgressUptime: TimeInterval?

    private func resetDynamicAccessLogFacts() {
        observedBitrateKbps = 0
        observedBitrateState = .unavailable
        indicatedBitrateKbps = 0
        indicatedAverageBitrateKbps = 0
        averageVideoBitrateKbps = 0
        transferredBytes = 0
        transferDurationSeconds = 0
        droppedFrames = 0
        stalls = 0
        likelyToKeepUp = false
        bufferedAheadSeconds = 0
        lastAccessLogProgress = nil
        lastObservedProgressUptime = nil
    }

    /// Scrape the dynamic numbers from the current player item (call ~1s).
    func sample(player: AVPlayer) {
        guard let item = player.currentItem else { return }
        let sampleUptime = ProcessInfo.processInfo.systemUptime
        likelyToKeepUp = item.isPlaybackLikelyToKeepUp

        if let range = item.loadedTimeRanges.first?.timeRangeValue {
            let bufferedEnd = (range.start + range.duration).seconds
            let now = player.currentTime().seconds
            if bufferedEnd.isFinite && now.isFinite {
                bufferedAheadSeconds = max(0, bufferedEnd - now)
            }
        }

        guard let access = item.accessLog(), let event = access.events.last else { return }
        if event.indicatedBitrate > 0 { indicatedBitrateKbps = event.indicatedBitrate / 1000 }
        if event.indicatedAverageBitrate > 0 { indicatedAverageBitrateKbps = event.indicatedAverageBitrate / 1000 }
        if event.averageVideoBitrate > 0 { averageVideoBitrateKbps = event.averageVideoBitrate / 1000 }
        if event.numberOfBytesTransferred >= 0 { transferredBytes = event.numberOfBytesTransferred }
        if event.transferDuration >= 0 { transferDurationSeconds = event.transferDuration }

        let progress = AccessLogProgressSignature(event: event)
        let progressAdvanced = progress.isAhead(of: lastAccessLogProgress)
        let firstProgressSample = lastAccessLogProgress == nil && progress.hasProgress
        lastAccessLogProgress = progress

        // AVFoundation reports bits/sec; show kbps. -1 means "not available". When the app's
        // loopback proxy fronts a remote HLS seek, this value is localhost/proxy burst rate,
        // not the server/network bitrate; leave Observed blank and rely on Indicated/Target.
        if usesLocalMediaProxy {
            observedBitrateState = .localProxy
            observedBitrateKbps = 0
            lastObservedProgressUptime = nil
        } else if event.observedBitrate > 0 {
            if progressAdvanced || firstProgressSample {
                observedBitrateKbps = event.observedBitrate / 1000
                observedBitrateState = .active
                lastObservedProgressUptime = sampleUptime
            } else if let lastObservedProgressUptime,
                      sampleUptime - lastObservedProgressUptime < Self.observedIdleGraceSeconds {
                // HLS segment loading is bursty: during startup/loading AVFoundation can report the
                // same positive observedBitrate across a quiet 1s tick while the next segment has
                // not advanced the access-log counters yet. Keep the last active value briefly so
                // Stats does not alternate between `idle` and a real bitrate every sample.
                observedBitrateState = .active
            } else {
                observedBitrateState = .idle
            }
        } else {
            observedBitrateState = .unavailable
            lastObservedProgressUptime = nil
        }
        if event.numberOfDroppedVideoFrames >= 0 { droppedFrames = event.numberOfDroppedVideoFrames }
        if event.numberOfStalls >= 0 { stalls = event.numberOfStalls }
    }

    private static func bitrateLabel(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        if value >= 1000 {
            return String(format: "%.1f Mbps", value / 1000)
        }
        return String(format: "%.0f kbps", value)
    }
}

enum ObservedBitrateState: Equatable {
    case unavailable
    case localProxy
    case active
    case idle
}

private struct AccessLogProgressSignature: Equatable {
    let transferredBytes: Int64
    let transferDurationMs: Int
    let downloadedDurationMs: Int

    init(event: AVPlayerItemAccessLogEvent) {
        transferredBytes = max(0, event.numberOfBytesTransferred)
        transferDurationMs = Int(max(0, event.transferDuration) * 1000)
        downloadedDurationMs = Int(max(0, event.segmentsDownloadedDuration) * 1000)
    }

    var hasProgress: Bool {
        transferredBytes > 0 || transferDurationMs > 0 || downloadedDurationMs > 0
    }

    func isAhead(of previous: AccessLogProgressSignature?) -> Bool {
        guard let previous else { return false }
        return transferredBytes > previous.transferredBytes
            || transferDurationMs > previous.transferDurationMs
            || downloadedDurationMs > previous.downloadedDurationMs
    }
}
