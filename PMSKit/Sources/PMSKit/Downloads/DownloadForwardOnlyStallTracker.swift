import Foundation

public struct DownloadForwardOnlyStallObservation: Equatable {
    public var bytes: Int
    public var lastForwardProgressAt: Date

    public init(bytes: Int, lastForwardProgressAt: Date) {
        self.bytes = bytes
        self.lastForwardProgressAt = lastForwardProgressAt
    }
}

/// What the stall check decided for a wedged forward-only stream.
public enum DownloadForwardOnlyStallVerdict: Equatable, Sendable {
    /// Fail the attempt and restart the stream from byte 0 through admission.
    case restart
    /// #497: the automatic restarts are spent. Fail the row as stalled and leave it for a user Retry.
    case fail
}

public struct DownloadForwardOnlyStallRestart {
    public let record: DownloadRecord
    public let stalledFor: TimeInterval
    /// The restart's attempt number; for `.fail`, the restarts already spent.
    public let attempt: Int
    public let verdict: DownloadForwardOnlyStallVerdict
    /// The row's byte high-water mark across its automatic restarts when the verdict was made.
    /// The manager seeds it back with the attempt count after the restart's teardown.
    public let highWaterBytes: Int

    public init(record: DownloadRecord, stalledFor: TimeInterval, attempt: Int,
                verdict: DownloadForwardOnlyStallVerdict = .restart, highWaterBytes: Int = 0) {
        self.record = record
        self.stalledFor = stalledFor
        self.attempt = attempt
        self.verdict = verdict
        self.highWaterBytes = max(highWaterBytes, record.bytes)
    }
}

/// IO-free state tracker for forward-only MediaBrowser download stall recovery.
///
/// Jellyfin/Emby live-forward download streams cannot resume from a durable byte checkpoint. When
/// they wedge with no byte progress, the app restarts the server stream from byte 0. This tracker
/// owns the ephemeral byte observations and bounded automatic restart attempts so `DownloadManager`
/// only performs the resulting cancel/retry side effects.
///
/// The restart budget refills only when a replacement stream passes the row's byte high-water mark
/// (#497 review): every restart replays the stream from byte 0, so the replayed bytes up to the
/// point where the last attempt wedged are not progress. Counting them as progress let a stream
/// that wedges at the same offset every time restart for ever, each stall counting as attempt 1.
/// An explicit user Retry also refills it (`refillRestartBudget`).
public struct DownloadForwardOnlyStallTracker {
    private var observations: [String: DownloadForwardOnlyStallObservation] = [:]
    private var restartAttempts: [String: Int] = [:]
    /// The most bytes any attempt of the row has reached since the budget last refilled.
    private var highWaterBytes: [String: Int] = [:]

    public init() {}

    public var trackedCount: Int { observations.count }

    public func observation(for ratingKey: String) -> DownloadForwardOnlyStallObservation? {
        observations[ratingKey]
    }

    public func restartAttemptCount(for ratingKey: String) -> Int {
        restartAttempts[ratingKey] ?? 0
    }

    public func highWaterMark(for ratingKey: String) -> Int? {
        highWaterBytes[ratingKey]
    }

    public mutating func remove(_ ratingKey: String) {
        observations.removeValue(forKey: ratingKey)
        restartAttempts.removeValue(forKey: ratingKey)
        highWaterBytes.removeValue(forKey: ratingKey)
    }

    /// An explicit user Retry: the row starts again with the full automatic restart budget.
    public mutating func refillRestartBudget(_ ratingKey: String) {
        restartAttempts.removeValue(forKey: ratingKey)
        highWaterBytes.removeValue(forKey: ratingKey)
    }

    /// Restore the bounded restart budget after an in-flight teardown that wiped tracker state.
    ///
    /// The stall-restart path itself funnels through the shared terminal release (`remove`), which
    /// would erase the attempt count `detectRestarts` just incremented — making the automatic
    /// restart cap a no-op and letting a persistent wedge restart the encoder from byte 0 forever.
    /// The high-water mark is restored with it: the replacement replays from byte 0, and the budget
    /// resets only once it passes the bytes an earlier attempt reached.
    public mutating func seedRestartAttempts(_ ratingKey: String, attempts: Int, highWaterBytes high: Int) {
        restartAttempts[ratingKey] = max(attempts, restartAttempts[ratingKey] ?? 0)
        highWaterBytes[ratingKey] = max(high, highWaterBytes[ratingKey] ?? 0)
    }

    public mutating func detectRestarts(records: [DownloadRecord],
                                        now: Date,
                                        isActive: (String) -> Bool) -> [DownloadForwardOnlyStallRestart] {
        var candidateKeys: Set<String> = []
        var restarts: [DownloadForwardOnlyStallRestart] = []
        for record in records where DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(record) {
            candidateKeys.insert(record.ratingKey)
            var observation = observations[record.ratingKey]
                ?? DownloadForwardOnlyStallObservation(bytes: record.bytes, lastForwardProgressAt: now)
            if record.bytes > observation.bytes {
                observation.bytes = record.bytes
                observation.lastForwardProgressAt = now
            }
            // Movement restarts the stall clock, but only bytes past every earlier attempt's
            // high-water mark give the restart budget back: a replacement replays from byte 0.
            if record.bytes > (highWaterBytes[record.ratingKey] ?? 0) {
                highWaterBytes[record.ratingKey] = record.bytes
                restartAttempts[record.ratingKey] = 0
            }
            let attempts = restartAttempts[record.ratingKey] ?? 0
            if DownloadStallRecoveryPolicy.shouldRestartForwardOnlyStream(
                record: record,
                active: isActive(record.ratingKey),
                lastForwardProgressAt: observation.lastForwardProgressAt,
                now: now,
                restartAttempts: attempts
            ) {
                let nextAttempt = attempts + 1
                restartAttempts[record.ratingKey] = nextAttempt
                restarts.append(DownloadForwardOnlyStallRestart(
                    record: record,
                    stalledFor: now.timeIntervalSince(observation.lastForwardProgressAt),
                    attempt: nextAttempt,
                    highWaterBytes: highWaterBytes[record.ratingKey] ?? 0))
                observation.lastForwardProgressAt = now
                observation.bytes = record.bytes
            } else if DownloadStallRecoveryPolicy.shouldFailForwardOnlyStream(
                record: record,
                active: isActive(record.ratingKey),
                lastForwardProgressAt: observation.lastForwardProgressAt,
                now: now,
                restartAttempts: attempts
            ) {
                // #497: past the cap a stall still gets a verdict. The clock restarts so the
                // refreshes before the failure lands do not report it again.
                restarts.append(DownloadForwardOnlyStallRestart(
                    record: record,
                    stalledFor: now.timeIntervalSince(observation.lastForwardProgressAt),
                    attempt: attempts,
                    verdict: .fail,
                    highWaterBytes: highWaterBytes[record.ratingKey] ?? 0))
                observation.lastForwardProgressAt = now
                observation.bytes = record.bytes
            }
            observations[record.ratingKey] = observation
        }
        observations = observations.filter { candidateKeys.contains($0.key) }
        let liveOrRetryableKeys = Set(records.filter { $0.status != .complete && $0.status != .unverified }.map(\.ratingKey))
        restartAttempts = restartAttempts.filter { liveOrRetryableKeys.contains($0.key) }
        highWaterBytes = highWaterBytes.filter { liveOrRetryableKeys.contains($0.key) }
        return restarts
    }
}
