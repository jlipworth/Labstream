import Foundation

/// Pure best-effort matching from a surviving background URLSession task back to a download row.
///
/// New tasks set `taskDescription` to the row key; URL fallbacks exist only for older tasks that
/// survived relaunch without that description. Plex static part URLs generally cannot be reverse
/// mapped from `/library/parts/...`, so they intentionally require the explicit task description.
public enum BackgroundDownloadTaskIdentity {
    public enum MarkerVersion: Sendable, Equatable {
        case unmarked
        case legacySegmentV1
        case legacySegmentV2
        case currentSegmentV3
        case legacyAttemptV1
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
        guard let url = requestURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let candidates: [String]
        if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            candidates = [(path as NSString).lastPathComponent]
        } else {
            let parts = components.path.split(separator: "/").map(String.init)
            if let items = parts.firstIndex(of: "Items"), parts.indices.contains(items + 1) {
                candidates = [parts[items + 1]]
            } else if let videos = parts.firstIndex(of: "Videos"), parts.indices.contains(videos + 1) {
                candidates = [parts[videos + 1]]
            } else {
                candidates = []
            }
        }

        let expanded = candidates.flatMap { [$0, "jellyfin:\($0)"] }
        return expanded.first { knownKeys.contains($0) }
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
        case .legacyV1: return .legacySegmentV1
        case .legacyV2: return .legacySegmentV2
        case .currentV3: return .currentSegmentV3
        case nil: break
        }
        switch DownloadAttemptMarker.version(fromTaskDescription: taskDescription) {
        case .legacyV1: return .legacyAttemptV1
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
