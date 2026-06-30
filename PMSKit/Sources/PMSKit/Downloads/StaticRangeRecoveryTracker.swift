import Foundation

/// Mutable, IO-free bookkeeping for the static byte-range recovery coordinator.
///
/// The app layer still owns URLSession and `DownloadStore` side effects; this tracker keeps the
/// cross-turn recovery sets together so relaunch resume, queue pause, finalization guards, and
/// retry-counter preservation do not remain as unrelated `DownloadManager` properties.
public struct StaticRangeRecoveryTracker: Equatable, Sendable {
    public private(set) var pendingResumeKeys: Set<String>
    public private(set) var preserveRestartCounterKeys: Set<String>
    public private(set) var finalizingKeys: Set<String>
    public private(set) var checkpointPauseKeys: Set<String>
    public private(set) var manualQueueResumeKeys: Set<String>

    public init(pendingResumeKeys: Set<String> = [],
                preserveRestartCounterKeys: Set<String> = [],
                finalizingKeys: Set<String> = [],
                checkpointPauseKeys: Set<String> = [],
                manualQueueResumeKeys: Set<String> = []) {
        self.pendingResumeKeys = pendingResumeKeys
        self.preserveRestartCounterKeys = preserveRestartCounterKeys
        self.finalizingKeys = finalizingKeys
        self.checkpointPauseKeys = checkpointPauseKeys
        self.manualQueueResumeKeys = manualQueueResumeKeys
    }

    public var pendingResumeCount: Int { pendingResumeKeys.count }
    public var finalizingCount: Int { finalizingKeys.count }

    public mutating func addPendingResume(_ key: String) {
        pendingResumeKeys.insert(key)
    }

    public mutating func removePendingResume(_ key: String) {
        pendingResumeKeys.remove(key)
    }

    public func hasPendingResume(_ key: String) -> Bool {
        pendingResumeKeys.contains(key)
    }

    public func resumablePendingKeys(isQueuePaused: Bool) -> Set<String> {
        isQueuePaused ? pendingResumeKeys.intersection(manualQueueResumeKeys) : pendingResumeKeys
    }

    public mutating func markFinalizing(_ key: String) {
        finalizingKeys.insert(key)
    }

    public mutating func unmarkFinalizing(_ key: String) {
        finalizingKeys.remove(key)
    }

    public func isFinalizing(_ key: String) -> Bool {
        finalizingKeys.contains(key)
    }

    public mutating func subtractFinalizing(_ keys: Set<String>) {
        finalizingKeys.subtract(keys)
    }

    public mutating func markManualQueueResume(_ key: String) {
        manualQueueResumeKeys.insert(key)
    }

    public mutating func removeManualQueueResume(_ key: String) {
        manualQueueResumeKeys.remove(key)
    }

    public mutating func removeAllManualQueueResumes() {
        manualQueueResumeKeys.removeAll()
    }

    public func wasManuallyResumedWhileQueuePaused(_ key: String) -> Bool {
        manualQueueResumeKeys.contains(key)
    }

    public mutating func subtractManualQueueResumes(_ keys: Set<String>) {
        manualQueueResumeKeys.subtract(keys)
    }

    public mutating func markCheckpointPause(_ key: String) {
        checkpointPauseKeys.insert(key)
    }

    public func isCheckpointPausing(_ key: String) -> Bool {
        checkpointPauseKeys.contains(key)
    }

    public mutating func keepCheckpointPauses(where shouldKeep: (String) -> Bool) {
        checkpointPauseKeys = checkpointPauseKeys.filter(shouldKeep)
    }

    public mutating func preserveRestartCountersForNextStart(_ key: String) {
        preserveRestartCounterKeys.insert(key)
    }

    @discardableResult
    public mutating func consumeRestartCounterPreservation(_ key: String) -> Bool {
        preserveRestartCounterKeys.remove(key) != nil
    }
}
