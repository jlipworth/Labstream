import Foundation

/// Pure server-safety policy for final-target player rebuilds.
///
/// VisionPlex records many seek targets while AVKit/user scrubbing is noisy, but PMS must only
/// see an intentional rebuild for the latest settled target. This type owns that small piece of
/// state and the restart budget so the app cannot accidentally start concurrent rebuild pipelines
/// or silently hammer PMS after repeated failures. The default budget is slightly roomier than the
/// lower-level restart helper because the custom scrubber emits committed release targets rather
/// than every transient playhead tick; a normal double-scrub should not look like a server failure.
public struct FinalTargetRebuildPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case start(generation: Int, offsetMs: Int)
        case alreadyRebuilding(generation: Int)
        case deferred(remaining: TimeInterval)
        case escalate(recentCount: Int)
    }

    private var budget: SeekRestartBudget
    private var pendingOffsetMs: Int?
    private var activeGeneration: Int?
    private var nextGeneration = 1

    public init(budget: SeekRestartBudget = SeekRestartBudget(cooldownSeconds: 2,
                                                              burstLimit: 5,
                                                              burstWindowSeconds: 60)) {
        self.budget = budget
    }

    public mutating func recordFinalTarget(offsetMs: Int) {
        pendingOffsetMs = offsetMs
    }

    public mutating func consumePendingTarget() -> Int? {
        defer { pendingOffsetMs = nil }
        return pendingOffsetMs
    }

    public mutating func beginRebuild(offsetMs: Int, now: TimeInterval) -> Decision {
        if let activeGeneration {
            pendingOffsetMs = offsetMs
            return .alreadyRebuilding(generation: activeGeneration)
        }

        switch budget.requestRestart(now: now) {
        case .allow:
            let generation = nextGeneration
            nextGeneration += 1
            activeGeneration = generation
            return .start(generation: generation, offsetMs: offsetMs)
        case .deferred(let remaining):
            pendingOffsetMs = offsetMs
            return .deferred(remaining: remaining)
        case .escalate(let recentCount):
            pendingOffsetMs = nil
            return .escalate(recentCount: recentCount)
        }
    }

    public mutating func finishRebuild(generation: Int) {
        if activeGeneration == generation {
            activeGeneration = nil
        }
    }

    public mutating func cancelRebuild(generation: Int) {
        if activeGeneration == generation {
            activeGeneration = nil
        }
    }

    public mutating func reset() {
        pendingOffsetMs = nil
        activeGeneration = nil
        budget.reset()
    }
}
