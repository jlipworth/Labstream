import Foundation

/// Conservative gate for Direct Stream (#31): only commit to a single-rendition direct
/// stream when the link has measured headroom over the source bitrate. Always evaluated
/// whenever Direct Stream is on — the no-ABR copy path has no rendition to fall back to,
/// so without measured headroom we use the (ABR-capable) transcode path instead.
public struct DirectStreamHeadroomGate: Sendable, Equatable {
    public static let defaultHeadroomMultiplier = 1.25

    public let observedThroughputKbps: Double?
    public let headroomMultiplier: Double

    public init(observedThroughputKbps: Double?,
                headroomMultiplier: Double = Self.defaultHeadroomMultiplier) {
        self.observedThroughputKbps = observedThroughputKbps
        self.headroomMultiplier = headroomMultiplier
    }

    public func verdict(sourceBitrateKbps: Int?) -> DirectStreamHeadroomVerdict {
        guard let sourceBitrateKbps, sourceBitrateKbps > 0 else {
            return .blocked(.missingSourceBitrate)
        }
        guard let observedThroughputKbps, observedThroughputKbps > 0 else {
            return .blocked(.missingThroughputEstimate)
        }

        let required = Int(ceil(Double(sourceBitrateKbps) * headroomMultiplier))
        let observed = Int(observedThroughputKbps.rounded(.down))
        guard observed >= required else {
            return .blocked(.insufficientThroughput(sourceKbps: sourceBitrateKbps,
                                                   requiredKbps: required,
                                                   observedKbps: observed))
        }
        return .allowed(sourceKbps: sourceBitrateKbps,
                        requiredKbps: required,
                        observedKbps: observed)
    }

    /// Source bitrate for the selected Plex `Media` version, in kbps.
    public static func sourceBitrateKbps(for item: MediaItem, mediaIndex: Int = 0) -> Int? {
        guard let media = item.media,
              let selected = media.indices.contains(mediaIndex) ? media[mediaIndex] : media.first,
              let bitrate = selected.bitrate,
              bitrate > 0 else { return nil }
        return bitrate
    }
}

public enum DirectStreamHeadroomVerdict: Sendable, Equatable {
    case allowed(sourceKbps: Int, requiredKbps: Int, observedKbps: Int)
    case blocked(DirectStreamHeadroomBlockReason)

    public var allowsDirectStream: Bool {
        switch self {
        case .allowed: true
        case .blocked: false
        }
    }
}

public enum DirectStreamHeadroomBlockReason: Sendable, Equatable {
    case missingSourceBitrate
    case missingThroughputEstimate
    case insufficientThroughput(sourceKbps: Int, requiredKbps: Int, observedKbps: Int)
}
