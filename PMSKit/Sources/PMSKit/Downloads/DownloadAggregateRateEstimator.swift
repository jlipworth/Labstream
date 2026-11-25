import Foundation

/// Ephemeral batch throughput from actual delegate observations, never UI refresh ticks.
/// Every transfer is measured over the same overlapping interval. Missing or stale evidence
/// hides the entire total instead of silently omitting a transfer (#379).
///
/// #487 (TLA+ Status-S1): a transfer that has been silent for `callbackGap` while the owner kept
/// observing (no callback since its last observation, or since the batch's last reset if it has
/// not reported since) counts as zero instead of hiding the batch for as long as it stays silent.
/// The silence clock restarts at every reset (wake, new member, gap reset), so a wake never turns
/// pre-sleep evidence into a zero. Its next sample is catch-up evidence and still resets the batch.
/// At least one transfer must contribute a measured rate; an all-silent batch has no answer.
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
    /// When the batch was last reset: the start of the silence clock of a transfer that has not
    /// reported since. Nil until the first reset.
    private var resetAt: Date?
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

    public mutating func setActiveTransfers(_ keys: Set<DownloadAttemptKey>, at now: Date) {
        // New/replacement attempts need a new batch window. Departures can use the remaining
        // transfers' existing common evidence; preparation and finalization never participate.
        if !keys.subtracting(activeTransfers).isEmpty { resetAfterWake(at: now) }
        activeTransfers = keys
        transfers = transfers.filter { keys.contains($0.key) }
    }

    /// Scene foreground and background-session wake both invalidate pre-wake observations.
    /// `now` restarts the silence clock of every transfer (#487).
    public mutating func resetAfterWake(at now: Date) {
        transfers.removeAll()
        resetAt = now
    }

    public mutating func sample(_ key: DownloadAttemptKey, bytes: Int, at now: Date) {
        guard activeTransfers.contains(key) else { return }
        if let last = transfers[key]?.observations.last,
           now.timeIntervalSince(last.time) >= callbackGap || now < last.time || bytes < last.bytes {
            // A late catch-up watermark must never be divided by a short post-sleep interval.
            // Reset the whole batch so a quiet transfer cannot retain a pre-wake baseline.
            resetAfterWake(at: now)
        } else if transfers[key] == nil, let resetAt, now.timeIntervalSince(resetAt) >= callbackGap {
            // #487: a first report after callbackGap of silence ends a transfer's zero count. It is
            // catch-up evidence as much as a late watermark is, so it resets the batch too.
            resetAfterWake(at: now)
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
        var contributing: [DownloadAttemptKey] = []
        for key in activeTransfers {
            if isSilent(key, at: now) { continue }
            guard let transfer = transfers[key], now >= transfer.settlingUntil,
                  transfer.observations.count >= 2,
                  let first = transfer.observations.first, let last = transfer.observations.last,
                  now >= last.time, now.timeIntervalSince(last.time) < callbackGap else { return nil }
            start = max(start, first.time)
            end = min(end, last.time)
            contributing.append(key)
        }
        guard !contributing.isEmpty else { return nil }
        let duration = end.timeIntervalSince(start)
        guard duration >= minimumWindow else { return nil }
        var total = 0.0
        for key in contributing {
            guard let observations = transfers[key]?.observations,
                  let first = interpolatedBytes(at: start, in: observations),
                  let last = interpolatedBytes(at: end, in: observations) else { return nil }
            total += (last - first) / duration
        }
        return total.isFinite && total >= 0 ? total : nil
    }

    /// #487: no callback for `callbackGap` since the transfer's last observation, or since the
    /// batch's last reset if it has not reported since. Such a transfer counts as zero.
    private func isSilent(_ key: DownloadAttemptKey, at now: Date) -> Bool {
        guard let since = transfers[key]?.observations.last?.time ?? resetAt else { return false }
        return now >= since && now.timeIntervalSince(since) >= callbackGap
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
