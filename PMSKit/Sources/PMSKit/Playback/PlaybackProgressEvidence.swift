import Foundation

/// Pure bounded oracle for an uninterrupted, approximately 1x playback hold.
/// A pass proves sampled playhead movement, never rendering or server cleanup.
public struct PlaybackProgressEvidence: Encodable, Sendable {
    public enum Phase: String, Codable, Sendable { case playing, waiting, paused, failed, cancelled }
    public enum Status: String, Codable, Sendable { case passed, failed, blocked }
    public enum Reason: String, Codable, Sendable {
        case sustainedSampledProgress, insufficientObservation, invalidEvidence, staleGeneration
        case observationGap, timelineDiscontinuity, cancelled, playerFailed
        case sustainedNonprogress, deadlineExceeded, insufficientProgress
    }
    public struct Sample: Codable, Sendable {
        public let elapsedSeconds: Double
        public let positionSeconds: Double
        public let phase: Phase
        public let generation: Int
        public init(elapsedSeconds: Double, positionSeconds: Double, phase: Phase, generation: Int) {
            self.elapsedSeconds = elapsedSeconds
            self.positionSeconds = positionSeconds
            self.phase = phase
            self.generation = generation
        }
    }
    public struct Result: Codable, Sendable {
        public let status: Status
        public let reason: Reason
        public let movingSeconds: Double
    }
    public let schemaVersion = 1
    public let evidenceKind: String
    public let backend: String
    public let generation: Int
    public let holdSeconds: Double
    public let stallToleranceSeconds: Double
    public var samples: [Sample]

    public init(evidenceKind: String, backend: String, generation: Int,
                holdSeconds: Double, stallToleranceSeconds: Double, samples: [Sample] = []) {
        self.evidenceKind = evidenceKind; self.backend = backend; self.generation = generation
        self.holdSeconds = holdSeconds; self.stallToleranceSeconds = stallToleranceSeconds
        self.samples = samples
    }

    public func evaluate() -> Result {
        func result(_ status: Status, _ reason: Reason, _ moving: Double = 0) -> Result {
            Result(status: status, reason: reason, movingSeconds: moving)
        }
        guard holdSeconds.isFinite, (5...300).contains(holdSeconds),
              stallToleranceSeconds.isFinite, (1...60).contains(stallToleranceSeconds),
              (1...1_000_000).contains(generation), (2...601).contains(samples.count),
              ["synthetic", "liveController", "rawPlayer"].contains(evidenceKind),
              ["fixture", "plex", "jellyfin", "emby", "unknown"].contains(backend),
              (evidenceKind == "synthetic") == (backend == "fixture"),
              samples.first?.elapsedSeconds == 0 else { return result(.blocked, .invalidEvidence) }
        var last = -1.0
        for sample in samples {
            guard sample.elapsedSeconds.isFinite, (0...360).contains(sample.elapsedSeconds),
                  sample.elapsedSeconds > last, sample.positionSeconds.isFinite,
                  (0...604_800).contains(sample.positionSeconds) else { return result(.blocked, .invalidEvidence) }
            guard sample.generation == generation else { return result(.blocked, .staleGeneration) }
            last = sample.elapsedSeconds
        }
        var moving = 0.0
        var idle = 0.0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let dt = current.elapsedSeconds - previous.elapsedSeconds
            let dp = current.positionSeconds - previous.positionSeconds
            if current.phase == .cancelled || previous.phase == .cancelled { return result(.blocked, .cancelled, moving) }
            if current.phase == .failed || previous.phase == .failed { return result(.failed, .playerFailed, moving) }
            if dt > 2 { return result(.blocked, .observationGap, moving) }
            if dp < -0.25 || dp > dt * 1.5 + 0.25 { return result(.blocked, .timelineDiscontinuity, moving) }
            if current.phase == .playing && previous.phase == .playing && dp >= dt * 0.5 {
                moving += dt; idle = 0
            } else { idle += dt }
            if idle >= stallToleranceSeconds { return result(.failed, .sustainedNonprogress, moving) }
        }
        // Sampling may land slightly after a deadline, but may never turn that late
        // sample into a pass. Callers evaluate once per sample and stop on a terminal result.
        if last > holdSeconds + stallToleranceSeconds { return result(.failed, .deadlineExceeded, moving) }
        if last >= holdSeconds && moving >= holdSeconds * 0.8 && idle == 0 {
            return result(.passed, .sustainedSampledProgress, moving)
        }
        if last >= holdSeconds + stallToleranceSeconds { return result(.failed, .insufficientProgress, moving) }
        return result(.blocked, .insufficientObservation, moving)
    }
}
