import Foundation

/// Monotonic identity for one configured/loaded music-player lifetime.
///
/// Callbacks capture a generation before they are registered or queued and validate it again on
/// the main actor before mutating playback state. Generation values are process-local only.
@MainActor
final class MusicPlaybackLifecycle {
    typealias Generation = UInt64

    private(set) var current: Generation = 0

    @discardableResult
    func advance() -> Generation {
        current &+= 1
        return current
    }

    func isCurrent(_ generation: Generation) -> Bool {
        generation == current
    }

    func perform(ifCurrent generation: Generation, _ mutation: () -> Void) {
        guard isCurrent(generation) else { return }
        mutation()
    }
}
