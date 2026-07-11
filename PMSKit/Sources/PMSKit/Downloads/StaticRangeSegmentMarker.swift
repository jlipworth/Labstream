import Foundation

/// Marker embedded in a background `URLSessionTask.taskDescription` for closed-range segment
/// tasks that the range-segments queueing lane (Task A1/A2) deliberately created.
///
/// Reattach (Task A3) uses this to distinguish OUR pre-queued closed-range segments from
/// pre-#231 legacy closed-range tasks, which must still be dropped on relaunch.
///
/// v2 markers additionally carry the row's download-attempt token
/// (`lbs-segment:v2:<offset>:<attemptID>`). Task identity used to be ratingKey-only, which let a
/// finished segment from a PRIOR attempt (cancelled/deleted/failed, or a prior app life at a
/// different quality) be adopted into a re-download of the same item and splice old-rendition
/// bytes. v1 markers have no token and are treated as legacy: parseable for diagnostics, but
/// never adoptable.
public enum StaticRangeSegmentMarker {
    public enum Version: Sendable, Equatable {
        case legacyV1
        case legacyV2
        case currentV3
    }

    /// Legacy v1 prefix (no attempt token). Parse-only: v1-marked tasks are dropped/superseded
    /// on reattach and never adopted.
    public static let prefix = "lbs-segment:v1:"
    public static let prefixV2 = "lbs-segment:v2:"
    public static let prefixV3 = "lbs-segment:v3:"

    /// Separator between the row key and the segment marker inside `taskDescription`.
    /// A byte the ratingKeys never contain (ASCII Unit Separator).
    private static let separator = "\u{1F}"

    /// Parse the segment's start offset out of a task's `taskDescription` (v1 or v2).
    ///
    /// Returns `nil` when the description is absent, does not carry a marker prefix, or the
    /// offset is not a non-negative integer — any malformed marker is treated as unmarked.
    public static func parse(_ taskDescription: String?) -> Int? {
        if let tokened = parseTokened(taskDescription) { return tokened.offset }
        guard let taskDescription, let r = taskDescription.range(of: prefix) else { return nil }
        let offsetString = taskDescription[r.upperBound...]
        guard let offset = Int(offsetString), offset >= 0 else { return nil }
        return offset
    }

    /// Parse a v2 marker's attempt token. `nil` for v1/unmarked/malformed descriptions, so a
    /// missing token reads as "legacy — not adoptable" everywhere identity is checked.
    public static func attemptIdentity(_ taskDescription: String?) -> DownloadAttemptID? {
        parseTokened(taskDescription)?.attemptID
    }

    /// Source-compatibility projection for the app while the atomic migration stack is unmerged.
    public static func attemptID(_ taskDescription: String?) -> String? {
        attemptIdentity(taskDescription)?.rawValue
    }

    public static func version(_ taskDescription: String?) -> Version? {
        guard let taskDescription else { return nil }
        if taskDescription.range(of: prefixV3) != nil {
            return parseTokened(taskDescription) == nil ? nil : .currentV3
        }
        if taskDescription.range(of: prefixV2) != nil {
            return parseTokened(taskDescription) == nil ? nil : .legacyV2
        }
        if taskDescription.range(of: prefix) != nil {
            return parse(taskDescription) == nil ? nil : .legacyV1
        }
        return nil
    }

    private static func parseTokened(
        _ taskDescription: String?
    ) -> (offset: Int, attemptID: DownloadAttemptID)? {
        guard let taskDescription,
              let r = taskDescription.range(of: prefixV3)
                ?? taskDescription.range(of: prefixV2) else { return nil }
        let payload = taskDescription[r.upperBound...]
        guard let colon = payload.firstIndex(of: ":") else { return nil }
        guard let offset = Int(payload[..<colon]), offset >= 0 else { return nil }
        guard let attemptID = DownloadAttemptID(
            rawValue: String(payload[payload.index(after: colon)...])
        ) else { return nil }
        return (offset, attemptID)
    }

    /// Legacy v1 marker builder. Kept only so tests can construct pre-token descriptions;
    /// production task creation always stamps the v2 form below.
    public static func value(offset: Int) -> String {
        "\(prefix)\(offset)"
    }

    /// Build the v2 marker string for a segment starting at `offset`, owned by `attemptID`.
    public static func value(offset: Int, attemptID: String) -> String {
        "\(prefixV2)\(offset):\(attemptID)"
    }

    public static func value(offset: Int, attemptID: DownloadAttemptID) -> String {
        "\(prefixV3)\(offset):\(attemptID.rawValue)"
    }

    /// Legacy v1 combined description builder (test-only; see `value(offset:)`).
    public static func taskDescription(ratingKey: String, offset: Int) -> String {
        "\(ratingKey)\(separator)\(value(offset: offset))"
    }

    /// `taskDescription` for a marked segment: the row key (needed to reverse-map Plex
    /// `/library/parts/...` tasks on relaunch) followed by the v2 segment marker.
    public static func taskDescription(ratingKey: String, offset: Int, attemptID: String) -> String {
        "\(ratingKey)\(separator)\(value(offset: offset, attemptID: attemptID))"
    }

    public static func taskDescription(
        ratingKey: String,
        offset: Int,
        attemptID: DownloadAttemptID
    ) -> String {
        "\(ratingKey)\(separator)\(value(offset: offset, attemptID: attemptID))"
    }

    /// Recover the row key from a combined segment `taskDescription` (v1 or v2). Returns the
    /// whole string unchanged when no marker is present (a plain ratingKey description).
    public static func ratingKey(fromTaskDescription description: String) -> String {
        let markerRange = description.range(of: prefixV3)
            ?? description.range(of: prefixV2)
            ?? description.range(of: prefix)
        guard let r = markerRange else { return description }
        var head = String(description[..<r.lowerBound])
        if head.hasSuffix(separator) { head.removeLast(separator.count) }
        return head
    }
}

/// Attempt-token stamp for NON-segment background tasks (the opaque forward-only lane and
/// open-ended range remainders), whose `taskDescription` used to be the bare ratingKey.
///
/// Format: `<ratingKey>\u{1F}lbs-attempt:v1:<attemptID>`. A bare-ratingKey description (no
/// stamp) still resolves to its row for progress/routing, but adoption paths that could splice
/// or replace file bytes require a token match — a prior-attempt/prior-life task must never be
/// adopted into the current attempt.
public enum DownloadAttemptMarker {
    public enum Version: Sendable, Equatable {
        case legacyV1
        case currentV2
    }

    public static let prefix = "lbs-attempt:v1:"
    public static let prefixV2 = "lbs-attempt:v2:"
    private static let separator = "\u{1F}"

    public static func taskDescription(ratingKey: String, attemptID: String) -> String {
        "\(ratingKey)\(separator)\(prefix)\(attemptID)"
    }

    public static func taskDescription(ratingKey: String, attemptID: DownloadAttemptID) -> String {
        "\(ratingKey)\(separator)\(prefixV2)\(attemptID.rawValue)"
    }

    /// Parse the attempt token. `nil` for unstamped (legacy bare-ratingKey) descriptions.
    public static func attemptID(fromTaskDescription description: String?) -> String? {
        attemptIdentity(fromTaskDescription: description)?.rawValue
    }

    public static func attemptIdentity(
        fromTaskDescription description: String?
    ) -> DownloadAttemptID? {
        guard let description,
              let r = description.range(of: prefixV2) ?? description.range(of: prefix) else { return nil }
        return DownloadAttemptID(rawValue: String(description[r.upperBound...]))
    }

    public static func version(fromTaskDescription description: String?) -> Version? {
        guard let description else { return nil }
        guard attemptIdentity(fromTaskDescription: description) != nil else { return nil }
        if description.range(of: prefixV2) != nil { return .currentV2 }
        if description.range(of: prefix) != nil { return .legacyV1 }
        return nil
    }

    /// Recover the row key from a stamped description. Returns the whole string unchanged when
    /// no attempt stamp is present.
    public static func ratingKey(fromTaskDescription description: String) -> String {
        guard let r = description.range(of: prefixV2) ?? description.range(of: prefix)
        else { return description }
        var head = String(description[..<r.lowerBound])
        if head.hasSuffix(separator) { head.removeLast(separator.count) }
        return head
    }
}
