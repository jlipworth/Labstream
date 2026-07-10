import Foundation

/// Marker embedded in a background `URLSessionTask.taskDescription` for closed-range segment
/// tasks that the range-segments queueing lane (Task A1/A2) deliberately created.
///
/// Reattach (Task A3) uses this to distinguish OUR pre-queued closed-range segments from
/// pre-#231 legacy closed-range tasks, which must still be dropped on relaunch.
public enum StaticRangeSegmentMarker {
    public static let prefix = "lbs-segment:v1:"

    /// Separator between the row key and the segment marker inside `taskDescription`.
    /// A byte the ratingKeys never contain (ASCII Unit Separator).
    private static let separator = "\u{1F}"

    /// Parse the segment's start offset out of a task's `taskDescription`.
    ///
    /// Returns `nil` when the description is absent, does not carry the marker prefix, or the
    /// remainder is not a non-negative integer — any malformed marker is treated as unmarked.
    public static func parse(_ taskDescription: String?) -> Int? {
        guard let taskDescription, let r = taskDescription.range(of: prefix) else { return nil }
        let offsetString = taskDescription[r.upperBound...]
        guard let offset = Int(offsetString), offset >= 0 else { return nil }
        return offset
    }

    /// Build the marker string to stash in `taskDescription` for a segment starting at `offset`.
    public static func value(offset: Int) -> String {
        "\(prefix)\(offset)"
    }

    /// `taskDescription` for a marked segment: the row key (needed to reverse-map Plex
    /// `/library/parts/...` tasks on relaunch) followed by the segment marker.
    public static func taskDescription(ratingKey: String, offset: Int) -> String {
        "\(ratingKey)\(separator)\(value(offset: offset))"
    }

    /// Recover the row key from a combined segment `taskDescription`. Returns the whole
    /// string unchanged when no marker is present (a plain ratingKey description).
    public static func ratingKey(fromTaskDescription description: String) -> String {
        guard let r = description.range(of: prefix) else { return description }
        var head = String(description[..<r.lowerBound])
        if head.hasSuffix(separator) { head.removeLast(separator.count) }
        return head
    }
}
