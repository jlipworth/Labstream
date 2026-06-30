import Foundation

public struct DownloadForwardOnlyStallObservation: Equatable {
    public var bytes: Int
    public var lastForwardProgressAt: Date

    public init(bytes: Int, lastForwardProgressAt: Date) {
        self.bytes = bytes
        self.lastForwardProgressAt = lastForwardProgressAt
    }
}

public struct DownloadForwardOnlyStallRestart {
    public let record: DownloadRecord
    public let stalledFor: TimeInterval
    public let attempt: Int

    public init(record: DownloadRecord, stalledFor: TimeInterval, attempt: Int) {
        self.record = record
        self.stalledFor = stalledFor
        self.attempt = attempt
    }
}

/// IO-free state tracker for forward-only MediaBrowser download stall recovery.
///
/// Jellyfin/Emby live-forward download streams cannot resume from a durable byte checkpoint. When
/// they wedge with no byte progress, the app restarts the server stream from byte 0. This tracker
/// owns the ephemeral byte observations and bounded automatic restart attempts so `DownloadManager`
/// only performs the resulting cancel/retry side effects.
public struct DownloadForwardOnlyStallTracker {
    private var observations: [String: DownloadForwardOnlyStallObservation] = [:]
    private var restartAttempts: [String: Int] = [:]

    public init() {}

    public var trackedCount: Int { observations.count }

    public func observation(for ratingKey: String) -> DownloadForwardOnlyStallObservation? {
        observations[ratingKey]
    }

    public func restartAttemptCount(for ratingKey: String) -> Int {
        restartAttempts[ratingKey] ?? 0
    }

    public mutating func remove(_ ratingKey: String) {
        observations.removeValue(forKey: ratingKey)
        restartAttempts.removeValue(forKey: ratingKey)
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
                    attempt: nextAttempt))
                observation.lastForwardProgressAt = now
                observation.bytes = record.bytes
            }
            observations[record.ratingKey] = observation
        }
        observations = observations.filter { candidateKeys.contains($0.key) }
        let liveOrRetryableKeys = Set(records.filter { $0.status != .complete && $0.status != .unverified }.map(\.ratingKey))
        restartAttempts = restartAttempts.filter { liveOrRetryableKeys.contains($0.key) }
        return restarts
    }
}
