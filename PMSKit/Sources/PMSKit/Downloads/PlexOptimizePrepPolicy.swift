import Foundation

/// Queue inspection and create visibility are independent of render completion/indexing.
public enum PlexOptimizePrepPolicy {
    public static let createVisibilityGraceSeconds: TimeInterval = 180

    public enum QueueLookup: Sendable, Equatable {
        case present
        case inspectedAbsent
        case unavailable
    }

    public enum Action: Sendable, Equatable {
        case keepInspecting
        case create
        case failMissingCreate
    }

    public static func queueLookup(inspected: Bool, matchingItemPresent: Bool) -> QueueLookup {
        guard inspected else { return .unavailable }
        return matchingItemPresent ? .present : .inspectedAbsent
    }

    /// A legacy row may recreate only on proven absence. A dispatched create never recreates;
    /// its original clock survives relaunch, unavailable inspection, and repeated absent reads.
    public static func action(queue: QueueLookup, metadataInspected: Bool,
                              dispatchedAt: TimeInterval?, now: TimeInterval) -> Action {
        guard queue == .inspectedAbsent, metadataInspected else { return .keepInspecting }
        guard let dispatchedAt else { return .create }
        return max(0, now - dispatchedAt) >= createVisibilityGraceSeconds
            ? .failMissingCreate : .keepInspecting
    }

    public static func candidate(from media: [Media], baselinePartIDs: Set<Int>,
                                 targetName: String, sourceHeight: Int?) -> Part? {
        let settings = DownloadPresetPolicy.customDownloadProfile(named: targetName)?.settings
            ?? DownloadPresetPolicy.mediaSettings(forTargetName: targetName)
        return OptimizedVersionMatch.candidate(
            from: media, baselinePartIDs: baselinePartIDs,
            targetDimensions: settings.videoResolution.flatMap(DownloadResolutionLabel.dimensions(forVideoResolution:)),
            targetVideoKbps: settings.maxVideoBitrateKbps,
            isOriginalQuality: DownloadPresetPolicy.isPlexOriginalQualityTarget(targetName),
            sourceHeight: sourceHeight)
    }
}
