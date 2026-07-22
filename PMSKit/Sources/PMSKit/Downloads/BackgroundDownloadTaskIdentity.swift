import Foundation

/// Pure best-effort matching from a surviving background URLSession task back to a download row.
///
/// Current tasks carry their exact row and attempt in `taskDescription`. Request URLs are never
/// ownership: they are mutable and backend-specific.
public enum BackgroundDownloadTaskIdentity {
    public enum MarkerVersion: Sendable, Equatable {
        case unmarked
        case currentSegmentV3
        case currentAttemptV2

        public var isCurrent: Bool {
            self == .currentSegmentV3 || self == .currentAttemptV2
        }
    }

    public static func ratingKey(taskDescription: String?,
                                 knownKeys: Set<String>) -> String? {
        let normalizedDescription = taskDescription.map {
            DownloadAttemptMarker.ratingKey(
                fromTaskDescription: StaticRangeSegmentMarker.ratingKey(fromTaskDescription: $0))
        }
        if let normalizedDescription, knownKeys.contains(normalizedDescription) {
            return normalizedDescription
        }
        return nil
    }

    /// Typed ownership token from either current task-description format. `nil` is unowned and
    /// therefore never adoptable.
    public static func attemptIdentity(taskDescription: String?) -> DownloadAttemptID? {
        StaticRangeSegmentMarker.attemptIdentity(taskDescription)
            ?? DownloadAttemptMarker.attemptIdentity(fromTaskDescription: taskDescription)
    }

    public static func markerVersion(taskDescription: String?) -> MarkerVersion {
        switch StaticRangeSegmentMarker.version(taskDescription) {
        case .currentV3: return .currentSegmentV3
        case nil: break
        }
        switch DownloadAttemptMarker.version(fromTaskDescription: taskDescription) {
        case .currentV2: return .currentAttemptV2
        case nil: return .unmarked
        }
    }

    /// Startup admission is deliberately stricter than steady-state reattach. A task must use the
    /// current marker format and map to a durable row with an exact current-attempt owner.
    public static func shouldPurgeBeforeAdmission(
        taskDescription: String?,
        mapsToKnownRow: Bool
    ) -> Bool {
        !markerVersion(taskDescription: taskDescription).isCurrent
            || !mapsToKnownRow
    }
}
