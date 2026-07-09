/// Pure policy for selecting the static byte-range segment shape.
///
/// The Apple-standard path for large downloadable files is one background `URLSessionDownloadTask`
/// and URLSession resume data. Labstream still sends an explicit open-ended `Range` header from the
/// app-owned durable partial offset so a missing/invalid resume blob can fall back to the partial
/// file size, but it no longer chains foreground-sized checkpoint tasks. This avoids the lifecycle
/// edge cases created by repeatedly cancelling, demoting, and re-enqueuing bounded transfers.
public enum StaticRangeSegmentStrategyPolicy {
    public struct SceneStrategy: Sendable, Equatable {
        public let normalizedPhase: String
        /// Constant since #227 (continuous remainder is the only strategy); kept as a field so
        /// scene-phase diagnostics keep a stable "strategy" label.
        public let diagnosticStrategy: String

        public init(normalizedPhase: String,
                    diagnosticStrategy: String) {
            self.normalizedPhase = normalizedPhase
            self.diagnosticStrategy = diagnosticStrategy
        }
    }

    public static func sceneStrategy(phase: String) -> SceneStrategy {
        SceneStrategy(
            normalizedPhase: phase.lowercased(),
            diagnosticStrategy: "continuous_remainder"
        )
    }

    /// The single post-#227 segment shape: one open-ended continuous remainder.
    public static let segmentReason = "single_remainder"
}
