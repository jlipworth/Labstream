#if DEBUG
import AVFoundation
import Foundation
import os
import PMSKit

/// Shared app-side scaffolding for DEBUG playback probes.
///
/// Jellyfin and Emby playback probes intentionally keep their backend-specific item
/// resolution and remote stream opening in their own files. The launch-arg parsing,
/// diagnostics guard, redacted query fields, playback readiness wait, progress hold, and
/// probe error shape are backend-agnostic and live here to keep probe behavior from
/// drifting.
@MainActor
enum DebugPlaybackProbeSupport {
    struct LaunchOptions {
        let query: String
        let bitrateKbps: Int
        let seekMs: Int
        let postSeekHoldSeconds: Int
        /// How long the player may sit in `.waitingToPlayAtSpecifiedRate` (buffering) before
        /// the probe calls it a stall. A starved high-bitrate stream is expected to buffer for
        /// long stretches yet still make progress, so probes that only care about eventual
        /// correctness should raise this via `--vp-probe-stall-tolerance-seconds`.
        let stallToleranceSeconds: Int
        let playableTimeoutSeconds: Int
    }

    static func withTemporaryDiagnosticsEnabled(_ operation: () async -> Void) async {
        let priorDiagnosticsEnabled = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(priorDiagnosticsEnabled) }
        await operation()
    }

    static func launchOptions(from arguments: [String], defaultBitrateKbps: Int) -> LaunchOptions? {
        let rawQuery = value(after: "--vp-probe-query", in: arguments)
        let trimmedQuery = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = trimmedQuery, !query.isEmpty else { return nil }
        let bounds: [(String, ClosedRange<Int>)] = [
            ("--vp-probe-post-seek-hold-seconds", 5...300),
            ("--vp-probe-stall-tolerance-seconds", 1...60),
            ("--vp-probe-playable-timeout-seconds", 1...180),
            ("--vp-probe-seek-ms", 0...604_800_000),
            ("--vp-probe-bitrate-kbps", 0...1_000_000)
        ]
        for (flag, range) in bounds where arguments.contains(flag) {
            guard let value = intValue(after: flag, in: arguments), range.contains(value) else { return nil }
        }
        return LaunchOptions(
            query: query,
            bitrateKbps: intValue(after: "--vp-probe-bitrate-kbps", in: arguments) ?? defaultBitrateKbps,
            seekMs: intValue(after: "--vp-probe-seek-ms", in: arguments) ?? 16 * 60 * 1000,
            postSeekHoldSeconds: intValue(after: "--vp-probe-post-seek-hold-seconds", in: arguments) ?? 20,
            stallToleranceSeconds: intValue(after: "--vp-probe-stall-tolerance-seconds", in: arguments) ?? 20,
            playableTimeoutSeconds: intValue(after: "--vp-probe-playable-timeout-seconds", in: arguments) ?? 45
        )
    }

    static func querySummary(_ query: String) -> String {
        DiagnosticRedactor.probeQuerySummary(query)
    }

    static func startFields(backend: String, query: String, bitrateKbps: Int, seekMs: Int) -> [String: DiagnosticFieldValue] {
        var fields: [String: DiagnosticFieldValue] = [
            "backend": .label(backend),
            "quality_kbps": .int(bitrateKbps),
            "target": .millisecondsBucket(seekMs),
        ]
        fields.merge(DiagnosticRedactor.probeQueryFields(query)) { _, new in new }
        return fields
    }

    static func recordMissingQuery(eventName: String) {
        AppDiagnostics.record(.playback, eventName, fields: [
            "reason": .label("missing_probe_query"),
            "query_present": .bool(false),
        ])
    }

    static func waitUntilPlayable(_ controller: PlaybackController,
                                  phase: String,
                                  timeoutSeconds: Int,
                                  sessionIsCurrent: () -> Bool = { true }) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard sessionIsCurrent() else { throw DebugPlaybackScenario.Blocked(reason: .backendChanged) }
            if controller.playbackError.isFailed {
                throw ProbeError.playbackFailed(phase, controller.playbackError.message)
            }
            if controller.player.currentItem?.status == .readyToPlay,
               controller.player.rate > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProbeError.timeout(phase)
    }

    static func holdWithPlaybackProgress(_ controller: PlaybackController,
                                         seconds: Int,
                                         stallToleranceSeconds: Int = 20,
                                         log: Logger,
                                         sessionIsCurrent: () -> Bool = { true }) async throws {
        try await holdWithPlaybackProgress(player: controller.player, seconds: seconds,
                                           stallToleranceSeconds: stallToleranceSeconds,
                                           evidenceKind: "liveController", log: log,
                                           failed: { controller.playbackError.isFailed },
                                           sessionIsCurrent: sessionIsCurrent)
    }

    /// Uses actual monotonic elapsed time and catches paused starvation as well as waiting.
    /// An item replacement/seek during an uninterrupted hold invalidates that evidence window.
    static func holdWithPlaybackProgress(player: AVPlayer, seconds: Int,
                                         stallToleranceSeconds: Int = 20,
                                         evidenceKind: String = "rawPlayer",
                                         log: Logger,
                                         failed: () -> Bool = { false },
                                         sessionIsCurrent: () -> Bool = { true }) async throws {
        guard (5...300).contains(seconds), (1...60).contains(stallToleranceSeconds),
              let item = player.currentItem else { throw ProbeError.timeout("invalid_hold_options") }
        let start = ContinuousClock.now
        var evidence = PlaybackProgressEvidence(evidenceKind: evidenceKind, backend: "unknown",
            generation: 1, holdSeconds: Double(seconds), stallToleranceSeconds: Double(stallToleranceSeconds))
        defer { DebugPlaybackEvidence.exportProgressIfRequested(evidence) }
        while evidence.samples.count < 601 {
            try Task.checkCancellation()
            guard sessionIsCurrent() else { throw DebugPlaybackScenario.Blocked(reason: .backendChanged) }
            guard player.currentItem === item else { throw ProbeError.timeout("hold_item_replaced") }
            let duration = start.duration(to: .now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let position = player.currentTime().seconds
            let phase: PlaybackProgressEvidence.Phase = failed() || item.status == .failed ? .failed
                : player.timeControlStatus == .playing ? .playing
                : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .waiting : .paused
            evidence.samples.append(.init(elapsedSeconds: evidence.samples.isEmpty ? 0 : elapsed,
                positionSeconds: position, phase: phase, generation: 1))
            if evidence.samples.count >= 2 {
                let result = evidence.evaluate()
                if result.status == .passed { return }
                if result.reason != .insufficientObservation {
                    throw ProbeError.playbackStalled(Int(result.movingSeconds * 1000), result.reason.rawValue)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ProbeError.timeout("hold_sample_limit")
    }

    /// Logs the video format descriptions AVPlayer actually engaged (codec fourCC + transfer
    /// function). This is the runtime truth for whether DV signalling was accepted: a `dvh1`
    /// or `dvhe` subtype means the Dolby Vision decode path is active, `hvc1`/`hev1` means
    /// the player fell back to the plain HEVC/HDR10 representation.
    static func logActiveVideoFormat(_ controller: PlaybackController, phase: String, log: Logger) async {
        guard let item = controller.player.currentItem else {
            log.notice("probe.video_format phase=\(phase, privacy: .public) status=no_item")
            return
        }
        var logged = 0
        for track in item.tracks {
            guard let assetTrack = track.assetTrack,
                  let descriptions = try? await assetTrack.load(.formatDescriptions) else { continue }
            for description in descriptions where CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video {
                let codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
                let transfer = (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String) ?? "unknown"
                log.notice("probe.video_format phase=\(phase, privacy: .public) codec=\(codec, privacy: .public) transfer=\(transfer, privacy: .public) enabled=\(track.isEnabled, privacy: .public)")
                logged += 1
            }
        }
        if logged == 0 {
            log.notice("probe.video_format phase=\(phase, privacy: .public) status=no_video_format_descriptions")
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.allSatisfy { $0.isASCII && !$0.isNewline } && !text.isEmpty ? text : String(code)
    }

    /// The argument immediately following `flag`, or nil if `flag` is absent or last.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `value(after:in:)` parsed as an `Int`, or nil.
    static func intValue(after flag: String, in arguments: [String]) -> Int? {
        value(after: flag, in: arguments).flatMap(Int.init)
    }

    private static func rawPlayerPositionMs(_ controller: PlaybackController) -> Int {
        let seconds = controller.player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return Int(seconds * 1000)
    }

    enum ProbeError: Error, CustomStringConvertible {
        case itemNotFound(String)
        case timeout(String)
        case playbackFailed(String, String?)
        case playbackStalled(Int, String)

        var description: String {
            switch self {
            case .itemNotFound(let query): return "item not found for query \(query)"
            case .timeout(let phase): return "timed out waiting for \(phase) playback"
            case .playbackFailed(let phase, let message): return "playback failed during \(phase): \(message ?? "no message")"
            case .playbackStalled(let advancedMs, let reason): return "playback stalled during hold: \(reason), advanced \(advancedMs)ms"
            }
        }
    }
}
#endif
