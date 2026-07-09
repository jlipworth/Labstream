/// Pure policy for selecting the static byte-range segment shape.
///
/// The Apple-standard path for large downloadable files is one background `URLSessionDownloadTask`
/// and URLSession resume data. Labstream still sends an explicit open-ended `Range` header from the
/// app-owned durable partial offset so a missing/invalid resume blob can fall back to the partial
/// file size, but it no longer chains foreground-sized checkpoint tasks. This avoids the lifecycle
/// edge cases created by repeatedly cancelling, demoting, and re-enqueuing bounded chunks.
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
        let reason = (normalized == "inactive" || normalized == "background")
            ? "scene_\(normalized)"
            : "single_remainder"
        return SceneStrategy(
            normalizedPhase: normalized,
            preferenceReason: reason,
            diagnosticStrategy: "continuous_remainder",
            shouldCountDurableCandidates: false
        )
    }

    public static func segmentPreference(sceneReason: String?)
        -> (kind: RangeTransferSegmentKind, reason: String?) {
        if let sceneReason {
            return (.continuousRemainder, sceneReason)
        }
        return (.continuousRemainder, "single_remainder")
    }
}
