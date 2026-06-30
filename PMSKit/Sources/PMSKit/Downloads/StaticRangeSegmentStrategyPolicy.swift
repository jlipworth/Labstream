/// Pure policy for selecting the next static byte-range segment shape.
///
/// Scene changes and pending background URLSession completion handlers both mean the app may be
/// suspended soon. In those windows new chunks should be background-owned checkpoint segments so
/// `nsurlsessiond` owns each bounded transfer while the durable partial still advances regularly.
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

    public static func sceneStrategy(phase: String) -> SceneStrategy {
        let normalized = phase.lowercased()
        let prefersBackgroundCheckpoint = normalized == "inactive" || normalized == "background"
        return SceneStrategy(
            normalizedPhase: normalized,
            preferenceReason: prefersBackgroundCheckpoint ? "scene_\(normalized)" : nil,
            diagnosticStrategy: prefersBackgroundCheckpoint ? "background_checkpoint" : "bounded_checkpoint",
            shouldCountDurableCandidates: prefersBackgroundCheckpoint
        )
    }

    public static func segmentPreference(sceneReason: String?,
                                         holdBackgroundCompletionForFirstProgress: Bool)
        -> (kind: RangeTransferSegmentKind, reason: String?) {
        if let sceneReason {
            return (.backgroundCheckpoint, sceneReason)
        }
        if holdBackgroundCompletionForFirstProgress {
            return (.backgroundCheckpoint, "background_events")
        }
        return (.boundedCheckpoint, nil)
    }
}
