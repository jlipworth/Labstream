import Foundation

/// Deterministic client-driven bitrate adaptation for issue #29.
///
/// This is the fallback path for servers that do not hand AVPlayer a true multi-rendition HLS
/// ladder. It deliberately changes one rung at a time and only in response to coarse, safe
/// signals the app can observe headlessly:
///
/// - sustained stall -> downshift one bounded rung, subject to cooldown/frequency limits
/// - sustained healthy playback with enough buffer -> optional upshift one bounded rung
///
/// The policy never raises above the user's selected cap. `Direct Play / Maximum` (0) is not a
/// downshiftable transcode rung: callers must surface a visible failure or make an explicit user-
/// initiated quality change rather than silently abandoning video-copy intent. `Maximum (HLS)`
/// (200 Mbps in the app) is treated as permission to climb only to the highest bounded rung.
public struct AdaptiveBitratePolicy: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// Minimum seconds between any two automatic changes. Protects PMS/Jellyfin from restart
        /// storms and prevents immediate ping-pong around one threshold.
        public var minimumSecondsBetweenChanges: TimeInterval
        /// Extra grace before an upshift is allowed after a downshift. A link that just proved it
        /// could not carry a rung must stay healthy for longer than the generic change cooldown.
        public var minimumSecondsAfterDownshiftBeforeUpshift: TimeInterval
        /// Continuous healthy playback required before considering an upshift.
        public var healthyPlaybackWindowSeconds: TimeInterval
        /// Buffered media ahead of the playhead required throughout the healthy window.
        public var minimumBufferedAheadForUpshift: Double
        /// If AVFoundation reports observed throughput, require this much headroom over the next
        /// rung before upshifting. Missing observed bitrate does not block a buffer-proven upshift.
        public var requiredObservedHeadroom: Double
        /// Sliding-window limit for automatic changes.
        public var maxChangesPerWindow: Int
        public var changeWindowSeconds: TimeInterval

        public init(minimumSecondsBetweenChanges: TimeInterval = 60,
                    minimumSecondsAfterDownshiftBeforeUpshift: TimeInterval = 180,
                    healthyPlaybackWindowSeconds: TimeInterval = 120,
                    minimumBufferedAheadForUpshift: Double = 45,
                    requiredObservedHeadroom: Double = 1.25,
                    maxChangesPerWindow: Int = 4,
                    changeWindowSeconds: TimeInterval = 600) {
            self.minimumSecondsBetweenChanges = minimumSecondsBetweenChanges
            self.minimumSecondsAfterDownshiftBeforeUpshift = minimumSecondsAfterDownshiftBeforeUpshift
            self.healthyPlaybackWindowSeconds = healthyPlaybackWindowSeconds
            self.minimumBufferedAheadForUpshift = minimumBufferedAheadForUpshift
            self.requiredObservedHeadroom = requiredObservedHeadroom
            self.maxChangesPerWindow = maxChangesPerWindow
            self.changeWindowSeconds = changeWindowSeconds
        }
    }

    public enum Direction: String, Sendable, Equatable {
        case down
        case up
    }

    public struct Decision: Sendable, Equatable {
        public let direction: Direction
        public let targetKbps: Int
        public let reason: String
    }

    /// Positive transcoded caps, low -> high. Excludes sentinel values such as "Direct Play /
    /// Maximum" (`0`) and "Maximum (HLS)" (`200_000`) because automatic adaptation should
    /// operate only on bounded rungs. Direct Play / Maximum is explicitly not downshifted.
    public let transcodedRungsKbps: [Int]
    public var configuration: Configuration

    public private(set) var lastChangeAt: TimeInterval?
    public private(set) var lastDownshiftAt: TimeInterval?
    public private(set) var healthyPlaybackSince: TimeInterval?
    public private(set) var recentChangeTimes: [TimeInterval] = []

    public init(transcodedRungsKbps: [Int] = [2_000, 3_000, 4_000, 8_000, 10_000, 12_000, 20_000, 40_000],
                configuration: Configuration = Configuration()) {
        self.transcodedRungsKbps = Array(Set(transcodedRungsKbps.filter { $0 > 0 })).sorted()
        self.configuration = configuration
    }

    public mutating func reset() {
        lastChangeAt = nil
        lastDownshiftAt = nil
        healthyPlaybackSince = nil
        recentChangeTimes.removeAll()
    }

    /// A sustained stall is the only downshift trigger. Returns nil if already at the lower bound
    /// or if cooldown/frequency protection says to keep the current stream rather than restart.
    public mutating func recordStall(now: TimeInterval,
                                     currentKbps: Int,
                                     userSelectedMaximumKbps: Int) -> Decision? {
        healthyPlaybackSince = nil
        guard canChange(now: now) else { return nil }
        guard let target = fallbackBitrateKbps(afterStallAt: currentKbps,
                                               userSelectedMaximumKbps: userSelectedMaximumKbps),
              target != currentKbps else { return nil }
        markChange(now: now, direction: .down)
        return Decision(direction: .down, targetKbps: target, reason: "sustained_stall")
    }

    /// Healthy samples must be continuous for the configured window before an upshift is allowed.
    /// Any non-healthy sample resets the window. Upshifts are one rung at a time and never above
    /// the user's selected cap.
    public mutating func recordHealthyPlayback(now: TimeInterval,
                                               currentKbps: Int,
                                               userSelectedMaximumKbps: Int,
                                               bufferedAheadSeconds: Double,
                                               likelyToKeepUp: Bool,
                                               observedBitrateKbps: Double = 0) -> Decision? {
        guard likelyToKeepUp,
              bufferedAheadSeconds >= configuration.minimumBufferedAheadForUpshift else {
            healthyPlaybackSince = nil
            return nil
        }

        let stableSince = healthyPlaybackSince ?? now
        healthyPlaybackSince = stableSince

        guard now - stableSince >= configuration.healthyPlaybackWindowSeconds else { return nil }
        guard canChange(now: now) else { return nil }
        if let lastDownshiftAt,
           now - lastDownshiftAt < configuration.minimumSecondsAfterDownshiftBeforeUpshift {
            return nil
        }
        guard let target = upshiftBitrateKbps(afterHealthyPlaybackAt: currentKbps,
                                              userSelectedMaximumKbps: userSelectedMaximumKbps),
              target != currentKbps else { return nil }
        if observedBitrateKbps > 0,
           observedBitrateKbps < Double(target) * configuration.requiredObservedHeadroom {
            return nil
        }

        markChange(now: now, direction: .up)
        healthyPlaybackSince = nil
        return Decision(direction: .up, targetKbps: target, reason: "sustained_healthy_playback")
    }

    /// Next lower bounded rung for a sustained stall.
    public func fallbackBitrateKbps(afterStallAt currentKbps: Int,
                                    userSelectedMaximumKbps: Int = Int.max) -> Int? {
        guard currentKbps > 0 else { return nil }
        return boundedRungs(userSelectedMaximumKbps: userSelectedMaximumKbps).last { $0 < currentKbps }
    }

    /// Next higher bounded rung after sustained healthy playback.
    public func upshiftBitrateKbps(afterHealthyPlaybackAt currentKbps: Int,
                                   userSelectedMaximumKbps: Int) -> Int? {
        guard currentKbps > 0 else { return nil }
        return boundedRungs(userSelectedMaximumKbps: userSelectedMaximumKbps).first { $0 > currentKbps }
    }

    public func boundedRungs(userSelectedMaximumKbps: Int) -> [Int] {
        guard let highest = transcodedRungsKbps.last else { return [] }
        let upperBound: Int
        if userSelectedMaximumKbps <= 0 || userSelectedMaximumKbps >= highest {
            upperBound = highest
        } else {
            upperBound = userSelectedMaximumKbps
        }
        return transcodedRungsKbps.filter { $0 <= upperBound }
    }

    private mutating func canChange(now: TimeInterval) -> Bool {
        pruneRecentChanges(now: now)
        if let lastChangeAt,
           now - lastChangeAt < configuration.minimumSecondsBetweenChanges {
            return false
        }
        return recentChangeTimes.count < configuration.maxChangesPerWindow
    }

    private mutating func markChange(now: TimeInterval, direction: Direction) {
        pruneRecentChanges(now: now)
        recentChangeTimes.append(now)
        lastChangeAt = now
        if direction == .down {
            lastDownshiftAt = now
        }
    }

    private mutating func pruneRecentChanges(now: TimeInterval) {
        recentChangeTimes.removeAll { now - $0 > configuration.changeWindowSeconds }
    }
}
