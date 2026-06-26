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
        return LaunchOptions(
            query: query,
            bitrateKbps: intValue(after: "--vp-probe-bitrate-kbps", in: arguments) ?? defaultBitrateKbps,
            seekMs: intValue(after: "--vp-probe-seek-ms", in: arguments) ?? 16 * 60 * 1000,
            postSeekHoldSeconds: intValue(after: "--vp-probe-post-seek-hold-seconds", in: arguments) ?? 20
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
                                  timeoutSeconds: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
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
                                         log: Logger) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var initialPositionMs: Int?
        var lastPositionMs = rawPlayerPositionMs(controller)
        var bestPositionMs = lastPositionMs
        var consecutiveWaitingSamples = 0
        var movingSamples = 0
        while ContinuousClock.now < deadline {
            if controller.playbackError.isFailed {
                throw ProbeError.playbackFailed("hold", controller.playbackError.message)
            }
            let currentPositionMs = rawPlayerPositionMs(controller)
            if initialPositionMs == nil, currentPositionMs > 1_000 {
                initialPositionMs = currentPositionMs
                lastPositionMs = currentPositionMs
                bestPositionMs = currentPositionMs
            }
            bestPositionMs = max(bestPositionMs, currentPositionMs)
            if currentPositionMs >= lastPositionMs + 500 {
                movingSamples += 1
                log.notice("probe.progress position_ms=\(currentPositionMs, privacy: .public) status=\(String(describing: controller.player.timeControlStatus), privacy: .public) rate=\(controller.player.rate, privacy: .public)")
                lastPositionMs = currentPositionMs
            }
            if controller.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                consecutiveWaitingSamples += 1
            } else {
                consecutiveWaitingSamples = 0
            }
            if consecutiveWaitingSamples >= 20 {
                throw ProbeError.playbackStalled(bestPositionMs - (initialPositionMs ?? lastPositionMs),
                                                 "player remained waiting during hold")
            }
            try await Task.sleep(for: .seconds(1))
        }
        let baselineMs = initialPositionMs ?? lastPositionMs
        let advancedMs = bestPositionMs - baselineMs
        guard advancedMs >= min(3_000, max(1_000, seconds * 500)), movingSamples >= 3 else {
            throw ProbeError.playbackStalled(advancedMs, "playhead did not advance enough")
        }
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
