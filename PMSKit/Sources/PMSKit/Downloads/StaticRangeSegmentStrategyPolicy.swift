/// Pure policy for selecting the next static byte-range segment shape.
///
/// Scene changes and pending background URLSession completion handlers both mean the app may be
/// suspended soon. In those windows the next segment is ONE open-ended continuous remainder so
/// `nsurlsessiond` finishes the whole file without waking the app once per chunk: every
/// background relaunch for a session event doubles the OS resume rate limiter's launch delay, so
/// a chunk-per-wakeup design stops making progress after ~10 wakeups (the observed off-head
/// multi-GB stall). Durability off-head rides on the OS temp plus URLSession resume data; the
/// app-owned durable partial advances when the remainder completes or on foreground demotion.
public enum StaticRangeSegmentStrategyPolicy {
    public struct SceneStrategy: Sendable, Equatable {
        public let normalizedPhase: String
        public let preferenceReason: String?
        public let diagnosticStrategy: String
        public let shouldCountDurableCandidates: Bool

        public init(normalizedPhase: String,
                    preferenceReason: String?,
                    diagnosticStrategy: String,
                    shouldCountDurableCandidates: Bool) {
            self.normalizedPhase = normalizedPhase
            self.preferenceReason = preferenceReason
            self.diagnosticStrategy = diagnosticStrategy
            self.shouldCountDurableCandidates = shouldCountDurableCandidates
        }
    }

    /// What to do with an in-flight continuous-remainder task when the app returns to the
    /// foreground and bounded checkpoint chunks become preferable again.
    public enum ForegroundDemotionDecision: Sendable, Equatable {
        /// Cancel the remainder and restart bounded chunks from the durable checkpoint. Only
        /// chosen when the discarded OS-temp bytes are bounded by one foreground chunk.
        case demoteToBounded
        /// Let the remainder finish: it has accumulated more temp progress than a demotion may
        /// discard, or it was relaunch-adopted and has no rebuildable request.
        case keepRunning
    }

    public static func sceneStrategy(phase: String) -> SceneStrategy {
        let normalized = phase.lowercased()
        let prefersRemainder = normalized == "inactive" || normalized == "background"
        return SceneStrategy(
            normalizedPhase: normalized,
            preferenceReason: prefersRemainder ? "scene_\(normalized)" : nil,
            diagnosticStrategy: prefersRemainder ? "continuous_remainder" : "bounded_checkpoint",
            shouldCountDurableCandidates: prefersRemainder
        )
    }

    public static func segmentPreference(sceneReason: String?,
                                         holdBackgroundCompletionForFirstProgress: Bool)
        -> (kind: RangeTransferSegmentKind, reason: String?) {
        if let sceneReason {
            return (.continuousRemainder, sceneReason)
        }
        if holdBackgroundCompletionForFirstProgress {
            return (.continuousRemainder, "background_events")
        }
        return (.boundedCheckpoint, nil)
    }

    public static func foregroundDemotionDecision(segmentKind: RangeTransferSegmentKind,
                                                  chunkBytesWritten: Int,
                                                  hasRequest: Bool,
                                                  maxDiscardBytes: Int) -> ForegroundDemotionDecision {
        guard segmentKind == .continuousRemainder, hasRequest else { return .keepRunning }
        return chunkBytesWritten <= maxDiscardBytes ? .demoteToBounded : .keepRunning
    }
}
