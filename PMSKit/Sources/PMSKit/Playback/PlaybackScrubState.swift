import Foundation

/// Small, pure state machine for an app-owned video scrubber.
///
/// While the user drags, the displayed position follows the draft target instead of the live
/// player clock. On commit, the draft target is returned in milliseconds so the presenter can
/// hand it to its playback engine. Unknown/zero-duration media cannot produce a meaningful
/// absolute seek target, so commit returns nil.
public struct PlaybackScrubState: Equatable, Sendable {
    public private(set) var durationMs: Int
    public private(set) var livePositionMs: Int
    public private(set) var draftPositionMs: Int?
    public private(set) var committedTargetMs: Int?
    public private(set) var isDragging: Bool

    public init(durationMs: Int, livePositionMs: Int = 0) {
        self.durationMs = max(0, durationMs)
        self.livePositionMs = Self.clamp(livePositionMs, durationMs: max(0, durationMs))
        self.draftPositionMs = nil
        self.committedTargetMs = nil
        self.isDragging = false
    }

    public var displayedPositionMs: Int {
        draftPositionMs ?? committedTargetMs ?? livePositionMs
    }

    public mutating func updateDuration(_ durationMs: Int) {
        self.durationMs = max(0, durationMs)
        livePositionMs = Self.clamp(livePositionMs, durationMs: self.durationMs)
        if let draftPositionMs {
            self.draftPositionMs = Self.clamp(draftPositionMs, durationMs: self.durationMs)
        }
        if let committedTargetMs {
            self.committedTargetMs = Self.clamp(committedTargetMs, durationMs: self.durationMs)
        }
    }

    public mutating func updateLivePosition(_ positionMs: Int, commitToleranceMs: Int = 2000) {
        livePositionMs = Self.clamp(positionMs, durationMs: durationMs)
        guard let committedTargetMs else { return }

        // A committed custom seek often takes a moment to prime/rebuild the stream. During that
        // window AVPlayer can still report the pre-seek clock, which would make the UI scrubber
        // jump backward and then forward again. Keep displaying the committed target until the
        // live clock catches up near it; a later drag/commit replaces or clears this state.
        if abs(livePositionMs - committedTargetMs) <= max(0, commitToleranceMs) {
            self.committedTargetMs = nil
        }
    }

    public mutating func beginDrag(livePositionMs: Int) {
        committedTargetMs = nil
        updateLivePosition(livePositionMs)
        guard durationMs > 0 else {
            isDragging = true
            draftPositionMs = nil
            return
        }
        isDragging = true
        draftPositionMs = self.livePositionMs
    }

    public mutating func updateDrag(fraction: Double) {
        guard isDragging, durationMs > 0 else { return }
        let clampedFraction = min(max(fraction, 0), 1)
        draftPositionMs = Int((Double(durationMs) * clampedFraction).rounded())
    }

    @discardableResult
    public mutating func commit() -> Int? {
        defer {
            isDragging = false
            draftPositionMs = nil
        }
        guard durationMs > 0 else { return nil }
        let target = Self.clamp(draftPositionMs ?? livePositionMs, durationMs: durationMs)
        committedTargetMs = target
        return target
    }

    public mutating func cancel() {
        isDragging = false
        draftPositionMs = nil
        committedTargetMs = nil
    }

    private static func clamp(_ positionMs: Int, durationMs: Int) -> Int {
        guard durationMs > 0 else { return max(0, positionMs) }
        return min(max(positionMs, 0), durationMs)
    }
}
