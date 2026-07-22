import AVFoundation
import PMSKit

/// Shared scrubber-clock tick used by both the windowed custom player and the Cinema scene.
///
/// Resolves the live duration from the player item (falling back to the catalog duration) and
/// pushes the controller's resume position into the scrub state unless the user is mid-drag.
@MainActor
func tickCustomScrubberClock(_ scrubState: inout PlaybackScrubState,
                             from controller: PlaybackController,
                             fallbackDurationMs: Int) {
    let duration = controller.player.currentItem?.duration
    let durationMs: Int
    if let duration, duration.seconds.isFinite, duration.seconds > 0 {
        durationMs = Int((duration.seconds * 1000).rounded())
    } else {
        durationMs = fallbackDurationMs
    }
    scrubState.updateDuration(durationMs)
    // Self-clear the seek hold once the live clock has actually landed at/after the target (the
    // per-item readyToPlay fires once and may precede that, so the 500ms tick backstops it).
    controller.releaseSeekHoldIfLanded()
    // Zombie watch: a starved rebuild can report `.playing` with a parked clock, a state no
    // KVO transition ever surfaces — this tick poll is the ONLY signal that escalates it to
    // the Reconnecting/Retry overlay and the only one that clears the overlay on recovery.
    controller.detectZombiePlaybackIfStuck()
    if !scrubState.isDragging {
        // While a user seek is in flight (in-buffer native seek, or an out-of-buffer
        // rebuild/reopen), pass `holdCommittedTarget: true` so the committed target stays pinned:
        // during a Jellyfin/Emby/Plex stream rebuild `currentResumeMs` can briefly alternate
        // between a near-target reading and a stale fallback, which made the time label bounce
        // (GH #110). The hold is released by the controller's seek lifecycle (seek completion /
        // post-rebuild readyToPlay / failure / stop / max-hold ceiling).
        scrubState.updateLivePosition(controller.currentResumeMs,
                                      holdCommittedTarget: controller.isSeeking)
    }
}
