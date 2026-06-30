import Foundation

/// IO-free view of a static byte-range URLSession task's authority.
public struct StaticRangeTaskSnapshot: Sendable, Equatable {
    public let taskIdentifier: Int
    public let downloadID: String
    public let baseOffset: Int
    public let chunkBytesWritten: Int

    public init(taskIdentifier: Int, downloadID: String, baseOffset: Int, chunkBytesWritten: Int) {
        self.taskIdentifier = taskIdentifier
        self.downloadID = downloadID
        self.baseOffset = baseOffset
        self.chunkBytesWritten = chunkBytesWritten
    }
}

public struct StaticRangeDuplicateTaskDecision: Sendable, Equatable {
    public let existingTaskIdentifier: Int
    public let existingBaseOffset: Int
    public let shouldReplaceExisting: Bool

    public init(existingTaskIdentifier: Int, existingBaseOffset: Int, shouldReplaceExisting: Bool) {
        self.existingTaskIdentifier = existingTaskIdentifier
        self.existingBaseOffset = existingBaseOffset
        self.shouldReplaceExisting = shouldReplaceExisting
    }
}

/// Pure ownership rules for static byte-range tasks.
///
/// A row can have only one authoritative Range chunk. The task at the furthest durable checkpoint
/// wins; when checkpoints tie, the task with the most in-flight chunk bytes wins. Older tasks must
/// be suppressed so their progress or finished temp file cannot overwrite a newer checkpoint.
public enum StaticRangeTaskSelectionPolicy {
    public static func duplicateDecision(candidate: StaticRangeTaskSnapshot,
                                         existingTasks: [StaticRangeTaskSnapshot])
        -> StaticRangeDuplicateTaskDecision? {
        guard let existing = authoritativeTask(
            forDownloadID: candidate.downloadID,
            in: existingTasks
        ) else { return nil }
        return StaticRangeDuplicateTaskDecision(
            existingTaskIdentifier: existing.taskIdentifier,
            existingBaseOffset: existing.baseOffset,
            shouldReplaceExisting: isNewer(candidate, than: existing))
    }

    public static func newerTaskIdentifier(than current: StaticRangeTaskSnapshot,
                                           in existingTasks: [StaticRangeTaskSnapshot]) -> Int? {
        authoritativeTask(forDownloadID: current.downloadID, in: existingTasks.filter {
            $0.taskIdentifier != current.taskIdentifier && isNewer($0, than: current)
        })?.taskIdentifier
    }

    public static func authoritativeTask(forDownloadID downloadID: String,
                                         in tasks: [StaticRangeTaskSnapshot]) -> StaticRangeTaskSnapshot? {
        tasks
            .filter { $0.downloadID == downloadID }
            .max { lhs, rhs in
                if lhs.baseOffset != rhs.baseOffset {
                    return lhs.baseOffset < rhs.baseOffset
                }
                return lhs.chunkBytesWritten < rhs.chunkBytesWritten
            }
    }

    public static func isNewer(_ lhs: StaticRangeTaskSnapshot,
                               than rhs: StaticRangeTaskSnapshot) -> Bool {
        lhs.baseOffset > rhs.baseOffset
            || (lhs.baseOffset == rhs.baseOffset
                && lhs.chunkBytesWritten > rhs.chunkBytesWritten)
    }
}
