import Foundation

/// Marker embedded in a background `URLSessionTask.taskDescription` for closed-range segment
/// tasks that the range-segments queueing lane (Task A1/A2) deliberately created.
///
/// Reattach (Task A3) uses this to distinguish OUR pre-queued closed-range segments from
/// pre-#231 legacy closed-range tasks, which must still be dropped on relaunch.
public enum StaticRangeSegmentMarker {
    private static let prefix = "lbs-segment:v1:"

    /// Parse the segment's start offset out of a task's `taskDescription`.
    ///
    /// Returns `nil` when the description is absent, does not carry the marker prefix, or the
    /// remainder is not a non-negative integer — any malformed marker is treated as unmarked.
    public static func parse(_ taskDescription: String?) -> Int? {
        guard let taskDescription, taskDescription.hasPrefix(prefix) else { return nil }
        let offsetString = taskDescription.dropFirst(prefix.count)
        guard let offset = Int(offsetString), offset >= 0 else { return nil }
        return offset
    }

    /// Build the marker string to stash in `taskDescription` for a segment starting at `offset`.
    public static func value(offset: Int) -> String {
        "\(prefix)\(offset)"
    }
}
