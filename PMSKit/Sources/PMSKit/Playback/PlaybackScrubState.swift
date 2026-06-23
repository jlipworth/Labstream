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

    /// Feed the live player clock into the scrubber.
    ///
    /// `holdCommittedTarget` is the GH #110 lifecycle guard: while a seek/reopen is in flight the
    /// presenter passes `true` so the committed target is never cleared by a transient live reading
    /// (the live clock can briefly alternate between a near-target value and a stale pre-seek
    /// offset during a Jellyfin/Emby/Plex stream rebuild). The presenter releases the hold via its
    /// own seek lifecycle (seek-completion / post-rebuild readyToPlay / failure), at which point it
    /// resumes calling this with `holdCommittedTarget == false` and the tolerance-clear below
    /// retires the committed target once the clock has genuinely caught up.
    public mutating func updateLivePosition(_ positionMs: Int,
                                            commitToleranceMs: Int = 2000,
                                            holdCommittedTarget: Bool = false) {
        livePositionMs = Self.clamp(positionMs, durationMs: durationMs)
        guard !holdCommittedTarget, let committedTargetMs else { return }

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

    /// Commit a programmatic seek target (for button-based ±10/±30 jumps) through the same
    /// display path as a released scrubber drag. This keeps the scrubber pinned to the user's
    /// requested target while an out-of-buffer stream rebuild/buffer catch-up is in flight.
    @discardableResult
    public mutating func commit(toMs targetMs: Int) -> Int? {
        isDragging = false
        draftPositionMs = nil
        guard durationMs > 0 else { return nil }
        let target = Self.clamp(targetMs, durationMs: durationMs)
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
