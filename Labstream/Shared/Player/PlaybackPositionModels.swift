import Foundation
import PMSKit

enum PlaybackTransitionCause: String, Equatable, Sendable {
    case plexSubtitleReload = "plex_subtitle_reload"
    case subtitleReload = "subtitle_reload"
    case audioReload = "audio_reload"
    case qualityReload = "quality_reload"
    case retry
    case relativeSeek = "relative_seek"
    case directPlayRuntimeFallback = "direct_play_runtime_fallback"
    case startupDeadlineRetry = "startup_deadline_retry"
    case adaptiveBitrate = "adaptive_bitrate"
}

enum PlaybackPositionCause: Equatable, Sendable {
    case currentResumeLive
    case resumeClockDesyncLive
    case userSeekTarget
    case load
    case currentItemChangedLive
    case periodicLive
    case timeControlPlaying
    case directPlayRuntimeFallback
    case startupDeadlineRetry
    case timeJump
    case seekRebuildTarget
    case seekRebuildSettledTarget
    case restartTarget
    case remoteReopenTarget
    case plexRebuildTarget
    case restartSeekHold(PlaybackTransitionCause)
    case restartRawLive(PlaybackTransitionCause)
    case itemViewOffset
    case zeroDefault

    var diagnosticLabel: String {
        switch self {
        case .currentResumeLive: "current_resume_live"
        case .resumeClockDesyncLive: "resume_clock_desync_live"
        case .userSeekTarget: "user_seek_target"
        case .load: "load"
        case .currentItemChangedLive: "current_item_changed_live"
        case .periodicLive: "periodic_live"
        case .timeControlPlaying: "time_control_playing"
        case .directPlayRuntimeFallback: "direct_play_runtime_fallback"
        case .startupDeadlineRetry: "startup_deadline_retry"
        case .timeJump: "time_jump"
        case .seekRebuildTarget: "seek_rebuild_target"
        case .seekRebuildSettledTarget: "seek_rebuild_settled_target"
        case .restartTarget: "restart_target"
        case .remoteReopenTarget: "remote_reopen_target"
        case .plexRebuildTarget: "plex_rebuild_target"
        case .restartSeekHold(let transition): "\(transition.rawValue)_seek_hold"
        case .restartRawLive(let transition): "\(transition.rawValue)_raw_live"
        case .itemViewOffset: "item_view_offset"
        case .zeroDefault: "zero_default"
        }
    }
}

struct PlaybackPositionSample: Equatable, Sendable {
    let positionMs: Int
    let capturedAt: TimeInterval
    let cause: PlaybackPositionCause
    let permitsNearZero: Bool

    init(positionMs: Int,
         capturedAt: TimeInterval,
         cause: PlaybackPositionCause,
         permitsNearZero: Bool = false) {
        self.positionMs = max(0, positionMs)
        self.capturedAt = capturedAt
        self.cause = cause
        self.permitsNearZero = permitsNearZero
    }
}

/// Generation-fenced target hold. Clearing a stale generation cannot release a newer seek, and
/// every re-arm restarts the 12-second deadline from the latest target.
struct PlaybackSeekHold: Equatable, Sendable {
    private(set) var generation = 0
    private(set) var target: PlaybackPositionSample?

    var isActive: Bool { target != nil }

    mutating func begin(targetMs: Int?, now: TimeInterval) {
        generation += 1
        let resolvedTarget = targetMs ?? target?.positionMs ?? 0
        target = PlaybackPositionSample(positionMs: resolvedTarget,
                                        capturedAt: now,
                                        cause: .userSeekTarget,
                                        permitsNearZero: true)
    }

    mutating func clear() {
        target = nil
    }

    mutating func clear(ifGeneration expectedGeneration: Int) -> Bool {
        guard isActive, generation == expectedGeneration else { return false }
        clear()
        return true
    }

    func exceeded(maxSeconds: TimeInterval, now: TimeInterval) -> Bool {
        guard let target else { return false }
        return now - target.capturedAt >= maxSeconds
    }
}

struct PlaybackPositionSnapshot: Equatable, Sendable {
    let selected: PlaybackPositionSample
    let rawLive: PlaybackPositionSample?
    let pending: PlaybackPositionSample?
    let lastTrustworthy: PlaybackPositionSample?
    let suppressedTransientZero: Bool
    let hasCurrentItem: Bool
    let itemPreparationInProgress: Bool
    let timeControlStatusLabel: String

    var positionMs: Int { selected.positionMs }
}

enum PlaybackPositionResolver {
    static let transientZeroThresholdMs = 1_500

    static func isTransientNearZero(_ positionMs: Int,
                                    seekHold: PlaybackSeekHold,
                                    pending: PlaybackPositionSample?,
                                    lastTrustworthy: PlaybackPositionSample?,
                                    savedOffsetMs: Int?) -> Bool {
        guard positionMs <= transientZeroThresholdMs else { return false }
        if let target = seekHold.target,
           target.permitsNearZero,
           target.positionMs <= transientZeroThresholdMs { return false }
        if let pending,
           pending.permitsNearZero,
           pending.positionMs <= transientZeroThresholdMs { return false }
        if let lastTrustworthy,
           lastTrustworthy.permitsNearZero,
           lastTrustworthy.positionMs <= transientZeroThresholdMs { return false }
        return [pending?.positionMs, lastTrustworthy?.positionMs, savedOffsetMs]
            .compactMap { $0 }
            .max() ?? 0 > transientZeroThresholdMs
    }

    static func bestKnownFallback(pending: PlaybackPositionSample?,
                                  lastTrustworthy: PlaybackPositionSample?) -> PlaybackPositionSample? {
        switch (pending, lastTrustworthy) {
        case (.some(let pending), .some(let trusted)):
            if pending.positionMs <= transientZeroThresholdMs,
               !pending.permitsNearZero,
               trusted.positionMs > transientZeroThresholdMs { return trusted }
            if trusted.positionMs <= transientZeroThresholdMs,
               !trusted.permitsNearZero,
               pending.positionMs > transientZeroThresholdMs { return pending }
            return pending.capturedAt >= trusted.capturedAt ? pending : trusted
        case (.some(let pending), .none): return pending
        case (.none, .some(let trusted)): return trusted
        case (.none, .none): return nil
        }
    }

    static func terminalPosition(live: PlaybackPositionSample?,
                                 liveIsTrustworthy: Bool,
                                 seekHold: PlaybackSeekHold,
                                 lastTrustworthy: PlaybackPositionSample?,
                                 savedOffsetMs: Int?) -> Int {
        PlaybackTerminalPositionPolicy.position(
            liveClockMs: live?.positionMs,
            liveClockIsTrustworthy: liveIsTrustworthy,
            heldTargetMs: seekHold.target?.positionMs,
            lastTrustworthyMs: lastTrustworthy?.positionMs,
            savedOffsetMs: savedOffsetMs)
    }
}
