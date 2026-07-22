import Foundation

/// Pure best-effort matching from a surviving background URLSession task back to a download row.
///
/// Current tasks carry their exact row and attempt in `taskDescription`. Request URLs are never
/// ownership: they are mutable, backend-specific, and were the source of unsafe legacy adoption.
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
                                 requestURL: URL?,
                                 knownKeys: Set<String>) -> String? {
        let normalizedDescription = taskDescription.map {
            DownloadAttemptMarker.ratingKey(
                fromTaskDescription: StaticRangeSegmentMarker.ratingKey(fromTaskDescription: $0))
        }
        if let normalizedDescription, knownKeys.contains(normalizedDescription) {
            return normalizedDescription
        }
        _ = requestURL
        return nil
    }

    /// The download-attempt token stamped into `taskDescription`, from either lane's format
    /// (v2 segment marker, or the opaque/open-ended attempt stamp). `nil` means a legacy task
    /// created before attempt tokens existed — never adoptable where identity matters.
    public static func attemptID(taskDescription: String?) -> String? {
        attemptIdentity(taskDescription: taskDescription)?.rawValue
    }

    /// Typed ownership token from either current task-description format. `nil` identifies a
    /// one-time legacy task that may be cancelled/rebuilt but must not become new durable authority.
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
    /// current marker format, map to a durable row, and not belong to an approved legacy-reset row.
    public static func shouldPurgeBeforeAdmission(
        taskDescription: String?,
        mapsToKnownRow: Bool,
        mapsToApprovedResetKey: Bool
    ) -> Bool {
        !markerVersion(taskDescription: taskDescription).isCurrent
            || !mapsToKnownRow
            || mapsToApprovedResetKey
    }
}
