import Foundation

/// Acceptance rule shared by every callback that can outlive a video item.
///
/// `PlaybackController` advances its generation for start, item replacement, and stop. Callback
/// closures capture the generation that installed them and re-check only after entering the main
/// actor, so removing an observer cannot leave an already-queued callback with authority.
enum VideoPlaybackLifecyclePolicy {
    static func accepts(capturedGeneration: Int,
                        currentGeneration: Int,
                        isCancelled: Bool = false) -> Bool {
        !isCancelled && capturedGeneration == currentGeneration
    }
}
