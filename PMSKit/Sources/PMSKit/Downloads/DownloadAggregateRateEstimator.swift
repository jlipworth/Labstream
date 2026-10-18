import Foundation

/// Ephemeral batch throughput from actual delegate observations, never UI refresh ticks.
/// Every transfer is measured over the same overlapping interval. Missing or stale evidence
/// hides the entire total instead of silently omitting a transfer (#379).
public struct DownloadAggregateRateEstimator: Sendable {
    private struct Observation: Sendable {
        let bytes: Int
        let time: Date
    }

    private struct Transfer: Sendable {
        let settlingUntil: Date
        var observations: [Observation]
    }

    private var activeTransfers: Set<DownloadAttemptKey> = []
    private var transfers: [DownloadAttemptKey: Transfer] = [:]
    public let windowDuration: TimeInterval
    public let minimumWindow: TimeInterval
    public let callbackGap: TimeInterval
    public let settlingDuration: TimeInterval

    /// All timestamps come from the owner, allowing an injected clock without real sleeps.
    public init(windowDuration: TimeInterval = 4, minimumWindow: TimeInterval = 0.5,
                callbackGap: TimeInterval = 6, settlingDuration: TimeInterval = 4) {
        self.windowDuration = windowDuration
        self.minimumWindow = minimumWindow
        self.callbackGap = callbackGap
        self.settlingDuration = settlingDuration
    }

    public mutating func setActiveTransfers(_ keys: Set<DownloadAttemptKey>) {
        // New/replacement attempts need a new batch window. Departures can use the remaining
        // transfers' existing common evidence; preparation and finalization never participate.
        if !keys.subtracting(activeTransfers).isEmpty { resetAfterWake() }
        activeTransfers = keys
        transfers = transfers.filter { keys.contains($0.key) }
    }

    /// Scene foreground and background-session wake both invalidate pre-wake observations.
    public mutating func resetAfterWake() {
        transfers.removeAll()
    }

    public mutating func sample(_ key: DownloadAttemptKey, bytes: Int, at now: Date) {
        guard activeTransfers.contains(key) else { return }
        if let last = transfers[key]?.observations.last,
           now.timeIntervalSince(last.time) >= callbackGap || now < last.time || bytes < last.bytes {
            // A late catch-up watermark must never be divided by a short post-sleep interval.
            // Reset the whole batch so a quiet transfer cannot retain a pre-wake baseline.
            resetAfterWake()
        }
        let observation = Observation(bytes: bytes, time: now)
        guard var transfer = transfers[key] else {
            transfers[key] = Transfer(settlingUntil: now.addingTimeInterval(settlingDuration),
                                      observations: [observation])
            return
        }
        if now < transfer.settlingUntil {
            // Preserve #224's catch-up protection: continually replace the baseline during
            // settling, starting at the first real callback, however late it arrives.
            transfer.observations = [observation]
        } else if transfer.observations.last?.time == now {
            transfer.observations[transfer.observations.count - 1] = observation
        } else {
            transfer.observations.append(observation)
            let cutoff = now.addingTimeInterval(-windowDuration)
            while transfer.observations.count > 2, transfer.observations[1].time <= cutoff {
                transfer.observations.removeFirst()
            }
        }
        transfers[key] = transfer
    }

    public func rate(at now: Date) -> Double? {
        guard !activeTransfers.isEmpty else { return nil }
        var start = now.addingTimeInterval(-windowDuration)
        var end = now
        for key in activeTransfers {
            guard let transfer = transfers[key], now >= transfer.settlingUntil,
                  transfer.observations.count >= 2,
                  let first = transfer.observations.first, let last = transfer.observations.last,
                  now >= last.time, now.timeIntervalSince(last.time) < callbackGap else { return nil }
            start = max(start, first.time)
            end = min(end, last.time)
        }
        let duration = end.timeIntervalSince(start)
        guard duration >= minimumWindow else { return nil }
        var total = 0.0
        for key in activeTransfers {
            guard let observations = transfers[key]?.observations,
                  let first = interpolatedBytes(at: start, in: observations),
                  let last = interpolatedBytes(at: end, in: observations) else { return nil }
            total += (last - first) / duration
        }
        return total.isFinite && total >= 0 ? total : nil
    }

    /// Interpolate only inside observed intervals, never extrapolate a missing callback.
    private func interpolatedBytes(at time: Date, in observations: [Observation]) -> Double? {
        for (first, last) in zip(observations, observations.dropFirst())
            where first.time <= time && time <= last.time {
            let fraction = time.timeIntervalSince(first.time) / last.time.timeIntervalSince(first.time)
            return Double(first.bytes) + Double(last.bytes - first.bytes) * fraction
        }
        return nil
    }
}
