import Foundation

/// Provisional same-session experiment, not a diagnosis of OS scheduling. All state is process-local.
public struct StaticRangeTaskHealthPolicy: Sendable {
    public enum Decision: String, Sendable {
        case reissue, insufficientWindow, counterReset, provenance, alreadyUsed, rateAboveGate
        case nearFinish, discardCap
    }
    public let settleSeconds: TimeInterval
    public let windowSeconds: TimeInterval
    public let maximumRate: Double
    public let minimumRemainingSeconds: TimeInterval
    public let maximumDiscardBytes: Int
    public let resultSeconds: TimeInterval = 30

    public init(settleSeconds: TimeInterval = 10, windowSeconds: TimeInterval = 60,
                maximumRate: Double = 128 * 1_024, minimumRemainingSeconds: TimeInterval = 600,
                maximumDiscardBytes: Int = 256 * 1_024 * 1_024) {
        self.settleSeconds = settleSeconds
        self.windowSeconds = windowSeconds
        self.maximumRate = maximumRate
        self.minimumRemainingSeconds = minimumRemainingSeconds
        self.maximumDiscardBytes = maximumDiscardBytes
    }

    public func canDiscard(_ bytes: Int) -> Bool { bytes >= 0 && bytes <= maximumDiscardBytes }

    public func decide(activeSeconds: TimeInterval, sampleSeconds: TimeInterval,
                       baselineBytes: Int, currentBytes: Int, rangeLength: Int,
                       creationContext: String, recoveryUsed: Bool) -> Decision {
        guard activeSeconds >= settleSeconds + windowSeconds,
              sampleSeconds >= windowSeconds, sampleSeconds > 0 else { return .insufficientWindow }
        guard baselineBytes >= 0, currentBytes >= baselineBytes else { return .counterReset }
        guard !recoveryUsed else { return .alreadyUsed }
        let remaining = max(0, rangeLength - currentBytes)
        guard remaining > 0 else { return .nearFinish }
        let rate = Double(currentBytes - baselineBytes) / sampleSeconds
        guard rate < maximumRate else { return .rateAboveGate }
        guard rate == 0 || Double(remaining) / rate > minimumRemainingSeconds else { return .nearFinish }
        guard canDiscard(currentBytes) else { return .discardCap }
        guard creationContext == "background_wake" else { return .provenance }
        return .reissue
    }
}
