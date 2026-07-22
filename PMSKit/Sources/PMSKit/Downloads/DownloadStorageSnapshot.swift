import Foundation

/// One presentation/cap view of Offline storage with explicit provenance. Unknown live OS temp
/// bytes stay unknown rather than being silently folded into durable or resumable totals.
public struct DownloadStorageSnapshot: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public enum Provenance: String, Equatable, Sendable {
            case durableMedia
            case durableSideAsset
            case heldOrResumeArtifact
            case liveOSTemporary
            case expectedReservation
        }

        public enum Measurement: Equatable, Sendable {
            case known(Int)
            case unknown
            case notApplicable

            var knownBytes: Int? {
                if case .known(let bytes) = self { return max(0, bytes) }
                return nil
            }
        }

        public let provenance: Provenance
        public let measurement: Measurement

        public init(_ provenance: Provenance, measurement: Measurement) {
            self.provenance = provenance
            if case .known(let bytes) = measurement {
                self.measurement = .known(max(0, bytes))
            } else {
                self.measurement = measurement
            }
        }
    }

    public let components: [Component]
    /// Bytes actually visible in app-owned storage. Expected reservations are not disk usage.
    public let displayBytes: Int?
    /// Current cap policy: durable indexed media + side assets only. Unknown/native temp bytes are
    /// intentionally not represented as zero; callers can inspect `hasUnknownBytes`.
    public let capEnforcementBytes: Int
    public let hasUnknownPhysicalBytes: Bool

    public init(durableMediaBytes: Int, durableSideAssetBytes: Int,
                heldOrResumeArtifactBytes: Component.Measurement,
                liveOSTemporaryBytes: Component.Measurement,
                expectedReservationBytes: Component.Measurement) {
        components = [
            Component(.durableMedia, measurement: .known(durableMediaBytes)),
            Component(.durableSideAsset, measurement: .known(durableSideAssetBytes)),
            Component(.heldOrResumeArtifact, measurement: heldOrResumeArtifactBytes),
            Component(.liveOSTemporary, measurement: liveOSTemporaryBytes),
            Component(.expectedReservation, measurement: expectedReservationBytes),
        ]
        let physical = Array(components.prefix(4))
        hasUnknownPhysicalBytes = physical.contains { $0.measurement == .unknown }
        displayBytes = hasUnknownPhysicalBytes ? nil : physical.reduce(0) {
            $0 + ($1.measurement.knownBytes ?? 0)
        }
        capEnforcementBytes = max(0, durableMediaBytes) + max(0, durableSideAssetBytes)
    }
}
